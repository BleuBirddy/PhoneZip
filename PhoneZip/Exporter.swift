import Foundation
import UIKit
import ZIPFoundation

/// Runs the whole job, one step after another:
/// 1. build the zip on the phone,
/// 2. unzip it onto an external drive and check every file,
/// 3. after the user confirms, delete the checked originals from the phone.
///
/// Copying to a drive goes in parts: a zip of up to 500 items (fewer if the
/// phone runs low on space) is built, unzipped onto the drive, checked and
/// removed, then the next part starts. A library bigger than the phone's free
/// space goes out that way, and all parts land in one folder on the drive.
///
/// The zip is built one file at a time: copy a photo to a temp file, add it,
/// delete the temp file. Peak extra space is the zip itself plus one item,
/// never a second full copy of the library.
@MainActor
final class Exporter: ObservableObject {
    struct Result {
        let zip: URL
        let bytes: Int64
        let skipped: Int
        let manifest: ExportManifest
    }

    /// What the copy to the drive left there, over every part of the export.
    struct DriveSummary {
        let folder: URL
        var parts = 0
        var manifest = ExportManifest()
        var verified = Set<String>()
        var failed: [String] = []
        var skipped = 0
        /// Zips left on the phone because something in them didn't copy correctly.
        var zipsKept = 0
        /// Why it ended before everything was copied, if it did.
        var stopped: String?
    }

    enum State {
        case idle
        case preparing
        /// `part` is 0 for a single zip that stays on the phone.
        case running(part: Int, done: Int, total: Int, current: String)
        case finished(Result)
        case moving(part: Int, done: Int, total: Int, current: String)
        case moved(DriveSummary)
        case deleting
        case cleaned(DeleteReport)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// A problem to show without leaving the current step (e.g. the drive
    /// filled up, so the user can try another drive).
    @Published var notice: String?
    private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch state {
        case .preparing, .running, .moving, .deleting: true
        default: false
        }
    }

    /// Builds one zip of everything and leaves it on the phone.
    func start(photos: Bool, videos: Bool, folders: [PickedFolder]) {
        begin()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: State
            do {
                let items = Self.items(photos: photos, videos: videos, folders: folders)
                let staging = try Self.makeStaging()
                defer { try? FileManager.default.removeItem(at: staging) }
                let zip = Self.newZipURL(Self.exportName())
                let part = try await Self.buildZip(items, from: 0, carrying: nil, to: zip, staging: staging,
                                                   batchSize: nil) { done, current in
                    Task { @MainActor in self?.state = .running(part: 0, done: done, total: items.count, current: current) }
                }
                outcome = .finished(Result(zip: zip, bytes: Self.fileSize(zip),
                                           skipped: part.skipped.count, manifest: part.manifest))
            } catch is CancellationError {
                outcome = .idle
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            await self?.end(outcome)
        }
    }

    /// Exports straight to the drive in parts, so the phone never needs room
    /// for more than one part at a time.
    func exportToDrive(photos: Bool, videos: Bool, folders: [PickedFolder], drive: PickedFolder) {
        begin()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var summary: DriveSummary?
            var skipped: [String] = []
            var problem: String?
            var cancelled = false
            do {
                let items = Self.items(photos: photos, videos: videos, folders: folders)
                let name = Self.exportName()
                let folder = try DriveTransfer.makeFolder(named: name, on: drive)
                summary = DriveSummary(folder: folder)
                let staging = try Self.makeStaging()
                defer { try? FileManager.default.removeItem(at: staging) }

                var next = 0
                var carried: URL?
                while next < items.count {
                    let number = summary!.parts + 1
                    let part = try await Self.buildZip(
                        items, from: next, carrying: carried, to: Self.newZipURL("\(name) part \(number)"),
                        staging: staging, batchSize: Self.batchSize
                    ) { done, current in
                        Task { @MainActor in self?.state = .running(part: number, done: done, total: items.count, current: current) }
                    }
                    skipped += part.skipped
                    summary!.skipped += part.skipped.count
                    summary!.manifest.merge(part.manifest)

                    let copy = try DriveTransfer.copy(zip: part.zip, into: folder) { done, total, current in
                        Task { @MainActor in self?.state = .moving(part: number, done: done, total: total, current: current) }
                    }
                    summary!.parts = number
                    summary!.verified.formUnion(copy.verified)
                    summary!.failed += copy.failed
                    if !copy.zipRemoved { summary!.zipsKept += 1 }
                    next = part.next
                    carried = part.carried
                }
            } catch is CancellationError {
                cancelled = true
                problem = "Stopped before everything was copied."
            } catch {
                problem = error.localizedDescription
            }

            let outcome: State
            if var summary, summary.parts > 0 {
                summary.stopped = problem
                // The list of what didn't make it goes next to the photos, so a
                // missing file isn't discovered months later.
                let missing = skipped + summary.failed
                if !missing.isEmpty {
                    let report = "Not included in this export:\n\n" + missing.joined(separator: "\n") + "\n"
                    try? Data(report.utf8).write(to: summary.folder.appendingPathComponent("Skipped files.txt"))
                }
                outcome = .moved(summary)
            } else {
                if let folder = summary?.folder { DriveTransfer.removeIfEmpty(folder) }
                outcome = cancelled ? .idle : .failed(problem ?? "Nothing was exported.")
            }
            await self?.end(outcome)
        }
    }

    /// Unzips a finished single zip onto the drive and checks every file.
    /// `drive` is held until the copy ends so its access stays open.
    func move(_ result: Result, to drive: PickedFolder) {
        state = .moving(part: 0, done: 0, total: 0, current: "")
        UIApplication.shared.isIdleTimerDisabled = true

        task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: State
            var problem: String?
            var folder: URL?
            do {
                folder = try DriveTransfer.makeFolder(named: result.zip.deletingPathExtension().lastPathComponent, on: drive)
                let copy = try DriveTransfer.copy(zip: result.zip, into: folder!) { done, total, current in
                    Task { @MainActor in self?.state = .moving(part: 0, done: done, total: total, current: current) }
                }
                outcome = .moved(DriveSummary(folder: folder!, parts: 1, manifest: result.manifest,
                                              verified: copy.verified, failed: copy.failed,
                                              skipped: result.skipped, zipsKept: copy.zipRemoved ? 0 : 1))
            } catch {
                // Back to the finished step: the zip is still on the phone,
                // so another drive can be tried.
                if let folder { DriveTransfer.removeIfEmpty(folder) }
                outcome = .finished(result)
                if !(error is CancellationError) { problem = error.localizedDescription }
            }
            await self?.end(outcome, notice: problem)
        }
    }

    /// Deletes from the phone only what the drive copy proved it has.
    func deleteOriginals(_ summary: DriveSummary) {
        state = .deleting
        task = Task { [weak self] in
            let report = await DriveTransfer.deleteOriginals(summary.manifest, verified: summary.verified)
            self?.state = .cleaned(report)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func reset() {
        state = .idle
    }

    private func begin() {
        state = .preparing
        // iOS suspends apps soon after they leave the screen, and auto-lock
        // counts. Keeping the screen awake is the simplest way to let a big
        // export finish; the UI tells the user to keep the app open.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func end(_ outcome: State, notice: String? = nil) {
        UIApplication.shared.isIdleTimerDisabled = false
        state = outcome
        self.notice = notice
    }

    /// Exports already in Documents (visible in the Files app).
    static func existingExports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension == "zip" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    nonisolated static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    // MARK: - Building a zip (off the main thread)

    struct OutOfSpace: LocalizedError {
        var errorDescription: String? {
            "The iPhone ran out of space. A zip kept on the phone needs about as much free space as the photos and files it holds. Use Copy to Drive instead: it goes in parts and only needs room for one part at a time."
        }
    }

    struct PhoneFull: LocalizedError {
        var errorDescription: String? {
            "The iPhone is almost full, even without a zip on it. Free up some space and try again."
        }
    }

    struct ZipDamaged: LocalizedError {
        let file: String
        let reason: String
        var errorDescription: String? {
            "Adding \(file) to the zip failed (\(reason)), so that zip can't be trusted and was removed."
        }
    }

    /// Stop before iOS itself runs dry; a full disk makes the whole phone misbehave.
    private nonisolated static let minimumFreeBytes: Int64 = 500_000_000

    /// Items per part when copying to a drive. A photo counts once, however
    /// many files it has.
    private nonisolated static var batchSize: Int {
        #if DEBUG
        // For testing parts with a small library: -PZBatchSize <n> on launch.
        let debug = UserDefaults.standard.integer(forKey: "PZBatchSize")
        return debug > 0 ? debug : 500
        #else
        500
        #endif
    }

    /// One zip of an export. With a drive, the export is a run of these.
    struct Part {
        let zip: URL
        /// Index of the first item that isn't in this zip.
        let next: Int
        /// That item, already fetched, when the zip had no room left for it.
        let carried: URL?
        let manifest: ExportManifest
        let skipped: [String]
    }

    private nonisolated static func items(photos: Bool, videos: Bool, folders: [PickedFolder]) -> [ExportItem] {
        var paths = ZipPathAllocator()
        var items = PhotoSource.items(photos: photos, videos: videos, paths: &paths).map(ExportItem.photoResource)
        items += FolderSource.items(in: folders, paths: &paths)
        return items
    }

    private nonisolated static func exportName() -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        return "iPhone Export \(stamp.string(from: Date()))"
    }

    /// Never reuses a name: two exports in the same minute must not replace
    /// an earlier zip that may not have been copied off yet.
    private nonisolated static func newZipURL(_ base: String) -> URL {
        var zipURL = documents.appendingPathComponent("\(base).zip")
        var n = 2
        while FileManager.default.fileExists(atPath: zipURL.path) {
            zipURL = documents.appendingPathComponent("\(base) (\(n)).zip")
            n += 1
        }
        return zipURL
    }

    private nonisolated static func makeStaging() throws -> URL {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("staging", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Fills one zip, starting at `items[start]`. Without a `batchSize` the zip
    /// stays on the phone, so it takes everything or fails with OutOfSpace.
    /// With one, it stops after that many items, or earlier when the phone
    /// runs low on space, and the caller moves it off before the next part.
    ///
    /// Every item is fetched to a local temp file first and checked for room
    /// before it goes in. ZIPFoundation leaves a zip damaged when an entry
    /// fails halfway, so an entry is only started once it can't fail.
    private nonisolated static func buildZip(
        _ items: [ExportItem], from start: Int, carrying carried: URL?, to zipURL: URL, staging: URL,
        batchSize: Int?, progress: @escaping (Int, String) -> Void
    ) async throws -> Part {
        let inParts = batchSize != nil
        // Anything left half-written is junk, so every failure path removes it.
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: zipURL) } }

        let archive = try Archive(url: zipURL, accessMode: .create)
        var skipped: [String] = []
        var manifest = ExportManifest()
        var units = Set<String>()
        var hasEntries = false
        var carried = carried
        var carriedOut: URL?
        var index = start

        func skip(_ item: ExportItem, _ reason: String) {
            skipped.append("\(item.pathInZip): \(reason)")
            if case .photoResource(let photo) = item { manifest.incompleteAssets.insert(photo.assetID) }
        }

        while index < items.count {
            try Task.checkCancellation()
            let item = items[index]
            if let batchSize, !units.contains(item.unit), units.count >= batchSize { break }
            units.insert(item.unit)
            progress(index, item.displayName)

            // 1. A local copy, downloaded from iCloud if need be.
            let temp: URL
            if let ready = carried {
                temp = ready
                carried = nil
            } else {
                if freeBytes() < minimumFreeBytes {
                    if !inParts { throw OutOfSpace() }
                    if hasEntries { break }
                    throw PhoneFull()
                }
                temp = staging.appendingPathComponent(UUID().uuidString)
                do {
                    try await fetch(item, to: temp)
                } catch {
                    try? FileManager.default.removeItem(at: temp)
                    if isOutOfSpace(error) {
                        if !inParts { throw OutOfSpace() }
                        // Try it again in the next part, once this zip is off the phone.
                        if hasEntries { break }
                        skip(item, "too big for the free space on this iPhone")
                    } else {
                        skip(item, error.localizedDescription)
                    }
                    index += 1
                    continue
                }
            }

            // 2. Room for it in the zip? Its exact size is known now.
            if freeBytes() < fileSize(temp) + minimumFreeBytes {
                if !inParts {
                    try? FileManager.default.removeItem(at: temp)
                    throw OutOfSpace()
                }
                if hasEntries {
                    carriedOut = temp
                    break
                }
                try? FileManager.default.removeItem(at: temp)
                skip(item, "too big for the free space on this iPhone")
                index += 1
                continue
            }

            // 3. Into the zip. Photos and videos are already compressed;
            // deflating them again costs minutes and saves almost nothing.
            do {
                switch item {
                case .photoResource(let photo):
                    try archive.addEntry(with: photo.pathInZip, fileURL: temp, compressionMethod: .none)
                    manifest.assetPaths[photo.assetID, default: []].append(photo.pathInZip)
                case .file(let url, let pathInZip):
                    try archive.addEntry(with: pathInZip, fileURL: temp, compressionMethod: .deflate)
                    manifest.files[pathInZip] = url
                }
            } catch {
                try? FileManager.default.removeItem(at: temp)
                if isOutOfSpace(error) { throw inParts ? PhoneFull() : OutOfSpace() }
                throw ZipDamaged(file: item.displayName, reason: error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: temp)
            hasEntries = true
            index += 1
        }

        // On the phone, the list of what didn't make it goes inside the zip.
        // In parts, the caller writes one list for all of them onto the drive.
        if !inParts && !skipped.isEmpty {
            let report = Data(("Not included in this export:\n\n" + skipped.joined(separator: "\n")).utf8)
            try archive.addEntry(with: "Skipped files.txt", type: .file, uncompressedSize: Int64(report.count)) { position, size in
                report.subdata(in: Int(position)..<Int(position) + size)
            }
        }

        progress(index, "")
        succeeded = true
        return Part(zip: zipURL, next: index, carried: carriedOut, manifest: manifest, skipped: skipped)
    }

    private nonisolated static func fetch(_ item: ExportItem, to temp: URL) async throws {
        switch item {
        case .photoResource(let photo): try await PhotoSource.write(photo, to: temp)
        case .file(let url, _): try FolderSource.copy(url, to: temp)
        }
    }

    private nonisolated static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private nonisolated static func freeBytes() -> Int64 {
        #if DEBUG
        // For testing the space limit: -PZFreeLimit <n> on launch makes the
        // phone look like it has n bytes to spare, minus what PhoneZip holds
        // (zips and staged files). Real free space can't be used for this in
        // the simulator, where the "drive" is on the same disk.
        if let limit = UserDefaults.standard.string(forKey: "PZFreeLimit").flatMap({ Int64($0) }) {
            let held = [documents, FileManager.default.temporaryDirectory.appendingPathComponent("staging")]
                .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
                .reduce(Int64(0)) { $0 + fileSize($1) }
            return minimumFreeBytes + limit - held
        }
        #endif
        let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    nonisolated static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        return (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
    }
}
