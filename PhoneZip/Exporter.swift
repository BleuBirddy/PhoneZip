import Foundation
import UIKit
import ZIPFoundation

/// Runs the whole job, one step after another:
/// 1. build the zip on the phone,
/// 2. unzip it onto an external drive and check every file,
/// 3. after the user confirms, delete the checked originals from the phone.
///
/// Copying to a drive goes in parts: a zip of up to 500 items or 4 GB (fewer if the
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
        /// Photo files left out because they're only in iCloud.
        let inICloud: Int
        let manifest: ExportManifest
        /// Paths whose file was read back out of the finished zip and matched.
        let checkedInZip: Set<String>
    }

    /// What the copy to the drive left there, over every part of the export.
    struct DriveSummary {
        let folder: URL
        var parts = 0
        var manifest = ExportManifest()
        var verified = Set<String>()
        var failed: [String] = []
        var skipped = 0
        var inICloud = 0
        /// Zips left on the phone because something in them didn't copy correctly.
        var zipsKept = 0
        /// Why it ended before everything was copied, if it did.
        var stopped: String?
        /// The picked drive, kept so its access stays open until the user
        /// has decided about deleting (the copies are checked again then).
        var driveAccess: PickedFolder?
        /// Files whose drive copy failed but that sit, checked, in a zip that
        /// stayed on this iPhone: path → that zip. They count as copied.
        var keptInZips: [String: URL] = [:]

        /// Everything with a checked copy, on the drive or in a kept zip.
        var safe: Set<String> { verified.union(keptInZips.keys) }
    }

    enum State {
        case idle
        case preparing
        /// `part` is 0 for a single zip that stays on the phone.
        case running(part: Int, done: Int, total: Int, current: String)
        /// Reading the finished zip back to check every file in it.
        case checking(part: Int, done: Int, total: Int, current: String)
        case finished(Result)
        case moving(part: Int, done: Int, total: Int, current: String)
        case moved(DriveSummary)
        case deleting
        case cleaned(DeleteReport)
        case failed(String)
        /// Everything on the phone is done; some photos are only in iCloud.
        /// Waits for the user to say whether to download them.
        case askingICloud(photos: Int)
    }

    @Published private(set) var state: State = .idle
    /// A problem to show without leaving the current step (e.g. the drive
    /// filled up, so the user can try another drive).
    @Published var notice: String?
    /// True while photos the user agreed to download come in from iCloud.
    @Published private(set) var fromICloud = false
    private var task: Task<Void, Never>?
    private var iCloudAnswer: CheckedContinuation<Bool, Never>?

    var isBusy: Bool {
        switch state {
        case .preparing, .running, .checking, .moving, .deleting, .askingICloud: true
        default: false
        }
    }

    /// Builds one zip of everything and leaves it on the phone.
    func start(photos: Bool, videos: Bool, folders: [PickedFolder], saver: SpaceSaver?) {
        begin()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: State
            var zip: URL?
            do {
                let items = Self.items(photos: photos, videos: videos, saver: saver, folders: folders)
                let staging = try Self.makeStaging()
                defer { try? FileManager.default.removeItem(at: staging) }
                zip = Self.newZipURL(Self.exportName(for: items))
                var part = try await Self.buildZip(items, from: 0, carrying: nil, to: zip!, appending: false,
                                                   staging: staging, batchSize: nil) { done, current in
                    Task { @MainActor in self?.show(.running(part: 0, done: done, total: items.count, current: current)) }
                }
                var manifest = part.manifest
                manifest.fileRoots = folders.map(\.url)
                var skipped = part.skipped
                var leftInICloud: [ExportItem] = []

                // Photos only in iCloud were held back. Download them into
                // the same zip only if the user says so.
                if !part.held.isEmpty {
                    let held = Self.allowingICloud(part.held)
                    if await self?.askAboutICloud(held) == true {
                        part = try await Self.buildZip(held, from: 0, carrying: nil, to: zip!, appending: true,
                                                       staging: staging, batchSize: nil) { done, current in
                            Task { @MainActor in self?.show(.running(part: 0, done: done, total: held.count, current: current)) }
                        }
                        manifest.merge(part.manifest)
                        skipped += part.skipped
                        // Asked once already; a file that still won't download is just skipped.
                        for item in part.held { Self.leaveOut(item, in: &manifest) }
                        skipped += part.held.map { "\($0.pathInZip): couldn't be downloaded from iCloud" }
                    } else {
                        try Task.checkCancellation()
                        leftInICloud = held
                        for item in held { Self.leaveOut(item, in: &manifest) }
                    }
                }

                // The list of what didn't make it goes inside the zip.
                let inICloud = leftInICloud.map(\.pathInZip)
                if !skipped.isEmpty || !inICloud.isEmpty {
                    try Self.appendReport(Self.skippedReport(skipped, inICloud: inICloud), to: zip!)
                }
                let checked = try DriveTransfer.verifyZip(zip!) { done, total, current in
                    Task { @MainActor in self?.show(.checking(part: 0, done: done, total: total, current: current)) }
                }
                outcome = .finished(Result(zip: zip!, bytes: Self.fileSize(zip!),
                                           skipped: skipped.count, inICloud: inICloud.count,
                                           manifest: manifest, checkedInZip: checked))
            } catch is CancellationError {
                if let zip { try? FileManager.default.removeItem(at: zip) }
                outcome = .idle
            } catch {
                if let zip { try? FileManager.default.removeItem(at: zip) }
                outcome = .failed(error.localizedDescription)
            }
            await self?.end(outcome)
        }
    }

    /// Exports straight to the drive in parts, so the phone never needs room
    /// for more than one part at a time.
    func exportToDrive(photos: Bool, videos: Bool, folders: [PickedFolder], saver: SpaceSaver?, drive: PickedFolder) {
        begin()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var summary: DriveSummary?
            var skipped: [String] = []
            var inICloud: [String] = []
            // Held-back photo files not yet settled. If the export stops
            // early, their photos must never be offered for deletion.
            var pending: [ExportItem] = []
            var problem: String?
            var cancelled = false
            do {
                let items = Self.items(photos: photos, videos: videos, saver: saver, folders: folders)
                let name = Self.exportName(for: items)
                let folder = try DriveTransfer.makeFolder(named: name, on: drive)
                summary = DriveSummary(folder: folder, driveAccess: drive)
                summary!.manifest.fileRoots = folders.map(\.url)
                let staging = try Self.makeStaging()
                defer { try? FileManager.default.removeItem(at: staging) }

                /// Zips `list` in parts, copying each part to the drive.
                /// Returns the photo files held back because they're only in iCloud.
                func copyInParts(_ list: [ExportItem]) async throws -> [ExportItem] {
                    var held: [ExportItem] = []
                    var next = 0
                    var carried: Prepared?
                    while next < list.count {
                        let number = summary!.parts + 1
                        let part = try await Self.buildZip(
                            list, from: next, carrying: carried, to: Self.newZipURL("\(name) part \(number)"),
                            appending: false, staging: staging, batchSize: Self.batchSize
                        ) { done, current in
                            Task { @MainActor in self?.show(.running(part: number, done: done, total: list.count, current: current)) }
                        }
                        skipped += part.skipped
                        summary!.skipped += part.skipped.count
                        held += part.held
                        summary!.manifest.merge(part.manifest)

                        // Check the zip itself first: if the drive won't take
                        // the files, a checked zip left on the phone still counts.
                        let inZip = try DriveTransfer.verifyZip(part.zip) { done, total, current in
                            Task { @MainActor in self?.show(.checking(part: number, done: done, total: total, current: current)) }
                        }
                        func keepZip(except copied: Set<String>) {
                            for path in inZip where !copied.contains(path) { summary!.keptInZips[path] = part.zip }
                        }
                        let copy: DriveCopy
                        do {
                            copy = try DriveTransfer.copy(zip: part.zip, into: folder) { done, total, current in
                                Task { @MainActor in self?.show(.moving(part: number, done: done, total: total, current: current)) }
                            }
                        } catch {
                            // The part's zip stays on the phone; its checked files count.
                            if FileManager.default.fileExists(atPath: part.zip.path) { keepZip(except: []) }
                            summary!.parts = number
                            throw error
                        }
                        if !copy.zipRemoved { keepZip(except: copy.verified) }
                        summary!.parts = number
                        summary!.verified.formUnion(copy.verified)
                        summary!.failed += copy.failed
                        if !copy.zipRemoved { summary!.zipsKept += 1 }
                        next = part.next
                        carried = part.carried
                    }
                    return held
                }

                let held = Self.allowingICloud(try await copyInParts(items))
                pending = held
                if !held.isEmpty {
                    if await self?.askAboutICloud(held) == true {
                        let stillHeld = try await copyInParts(held)
                        pending = stillHeld
                        for item in stillHeld { Self.leaveOut(item, in: &summary!.manifest) }
                        skipped += stillHeld.map { "\($0.pathInZip): couldn't be downloaded from iCloud" }
                        summary!.skipped += stillHeld.count
                    } else {
                        try Task.checkCancellation()
                        for item in held { Self.leaveOut(item, in: &summary!.manifest) }
                        inICloud = held.map(\.pathInZip)
                        summary!.inICloud = held.count
                    }
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
                for item in pending { Self.leaveOut(item, in: &summary.manifest) }
                // The list of what didn't make it goes next to the photos, so a
                // missing file isn't discovered months later.
                let missing = skipped + summary.failed
                if !missing.isEmpty || !inICloud.isEmpty {
                    let report = Data(Self.skippedReport(missing, inICloud: inICloud).utf8)
                    // A copy stays on the phone (in Files, next to the zips),
                    // so the list survives a drive that stopped taking writes.
                    try? report.write(to: Self.documents.appendingPathComponent(
                        "\(summary.folder.lastPathComponent) - Skipped files.txt"))
                    try? report.write(to: summary.folder.appendingPathComponent("Skipped files.txt"))
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
                var summary = DriveSummary(folder: folder!, parts: 1, manifest: result.manifest,
                                           verified: copy.verified, failed: copy.failed,
                                           skipped: result.skipped, inICloud: result.inICloud, zipsKept: copy.zipRemoved ? 0 : 1,
                                           driveAccess: drive)
                if !copy.zipRemoved {
                    for path in result.checkedInZip where !copy.verified.contains(path) { summary.keptInZips[path] = result.zip }
                }
                outcome = .moved(summary)
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
            let report = await DriveTransfer.deleteOriginals(summary.manifest, verified: summary.safe,
                                                             on: summary.folder, inZips: summary.keptInZips)
            self?.state = .cleaned(report)
        }
    }

    /// Deletes what the finished zip on this iPhone was checked to hold.
    func deleteOriginals(_ result: Result) {
        state = .deleting
        task = Task { [weak self] in
            let inZip = Dictionary(uniqueKeysWithValues: result.checkedInZip.map { ($0, result.zip) })
            let report = await DriveTransfer.deleteOriginals(result.manifest, verified: result.checkedInZip,
                                                             on: nil, inZips: inZip)
            self?.state = .cleaned(report)
        }
    }

    func cancel() {
        task?.cancel()
        answerICloud(false)
    }

    /// The user's answer to "Download N photos from iCloud?".
    func answerICloud(_ download: Bool) {
        guard let answer = iCloudAnswer else { return }
        iCloudAnswer = nil
        if download { fromICloud = true }
        state = .preparing
        answer.resume(returning: download)
    }

    /// Pauses the export until the user answers. Nothing is downloaded
    /// from iCloud without a yes.
    private func askAboutICloud(_ held: [ExportItem]) async -> Bool {
        if Task.isCancelled { return false }
        let photos = Set(held.map(\.unit)).count
        return await withCheckedContinuation { continuation in
            iCloudAnswer = continuation
            state = .askingICloud(photos: photos)
        }
    }

    /// Progress updates arrive a moment late; one must never cover the question.
    private func show(_ progress: State) {
        if case .askingICloud = state { return }
        state = progress
    }

    func reset() {
        state = .idle
    }

    private func begin() {
        state = .preparing
        fromICloud = false
        // iOS suspends apps soon after they leave the screen, and auto-lock
        // counts. Keeping the screen awake is the simplest way to let a big
        // export finish; the UI tells the user to keep the app open.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func end(_ outcome: State, notice: String? = nil) {
        UIApplication.shared.isIdleTimerDisabled = false
        fromICloud = false
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

    /// Bytes per part when copying to a drive. A count alone let 132 big
    /// videos make one 118 GB part: nothing reached the drive for over an
    /// hour, and one problem cost the whole lot. A part closes once it holds
    /// this much (a single bigger file still goes in a part of its own).
    private nonisolated static var partBytes: Int64 {
        #if DEBUG
        // For testing parts with small videos: -PZPartBytes <n> on launch.
        let debug = Int64(UserDefaults.standard.integer(forKey: "PZPartBytes"))
        return debug > 0 ? debug : 4_000_000_000
        #else
        4_000_000_000
        #endif
    }

    /// One zip of an export. With a drive, the export is a run of these.
    struct Part {
        let zip: URL
        /// Index of the first item that isn't in this zip.
        let next: Int
        /// That item, already fetched, when the zip had no room left for it.
        let carried: Prepared?
        let manifest: ExportManifest
        let skipped: [String]
        /// Photo files only in iCloud, held back for the user to decide on.
        let held: [ExportItem]
    }

    /// An item fetched (and in Save Space mode re-encoded) to a local file,
    /// ready to go into the zip.
    struct Prepared {
        let url: URL
        let pathInZip: String
        /// True when this is a re-encoded, lower-quality copy.
        let shrunk: Bool
    }

    private nonisolated static func items(photos: Bool, videos: Bool, saver: SpaceSaver?,
                                          folders: [PickedFolder]) -> [ExportItem] {
        var paths = ZipPathAllocator()
        var items = PhotoSource.items(photos: photos, videos: videos, saver: saver, paths: &paths)
            .map(ExportItem.photoResource)
        items += FolderSource.items(in: folders, paths: &paths)
        return items
    }

    /// The same items, now allowed to download from iCloud.
    private nonisolated static func allowingICloud(_ items: [ExportItem]) -> [ExportItem] {
        items.map { item in
            guard case .photoResource(var photo) = item else { return item }
            photo.allowICloud = true
            return .photoResource(photo)
        }
    }

    /// A photo missing one of its files is never offered for deletion.
    private nonisolated static func leaveOut(_ item: ExportItem, in manifest: inout ExportManifest) {
        if case .photoResource(let photo) = item { manifest.incompleteAssets.insert(photo.assetID) }
    }

    /// "iPhone Export 2024-05-01 18.30 - Photos, Videos & Documents": the
    /// name says what is inside, taken from what was actually found.
    private nonisolated static func exportName(for items: [ExportItem]) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        var kinds = Set<String>()
        for item in items {
            switch item {
            case .photoResource(let photo):
                // Photo Library/<kind>/...; screenshots count as photos and
                // screen recordings as videos, to keep the name short.
                let kind = photo.pathInZip.split(separator: "/").dropFirst().first.map(String.init) ?? "Photos"
                kinds.insert(kind == "Screen Recordings" || kind == "Videos" ? "Videos" : "Photos")
            case .file:
                kinds.insert("Documents")
            }
        }
        let ordered = ["Photos", "Videos", "Documents"].filter(kinds.contains)
        let contents: String
        switch ordered.count {
        case 0: contents = ""
        case 1: contents = " - " + ordered[0]
        default: contents = " - " + ordered.dropLast().joined(separator: ", ") + " & " + ordered.last!
        }
        return "iPhone Export \(stamp.string(from: Date()))\(contents)"
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
        _ items: [ExportItem], from start: Int, carrying carried: Prepared?, to zipURL: URL, appending: Bool,
        staging: URL, batchSize: Int?, progress: @escaping (Int, String) -> Void
    ) async throws -> Part {
        let inParts = batchSize != nil
        // Anything left half-written is junk, so every failure path removes it.
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: zipURL) } }

        let archive = try Archive(url: zipURL, accessMode: appending ? .update : .create)
        var skipped: [String] = []
        var held: [ExportItem] = []
        var manifest = ExportManifest()
        var units = Set<String>()
        var hasEntries = false
        var bytesInPart: Int64 = 0
        var carried = carried
        var carriedOut: Prepared?
        var index = start

        func skip(_ item: ExportItem, _ reason: String) {
            skipped.append("\(item.pathInZip): \(reason)")
            if case .photoResource(let photo) = item { manifest.incompleteAssets.insert(photo.assetID) }
        }

        while index < items.count {
            try Task.checkCancellation()
            let item = items[index]
            if let batchSize, !units.contains(item.unit),
               units.count >= batchSize || bytesInPart >= partBytes { break }
            units.insert(item.unit)
            progress(index, item.displayName)

            // 1. A local copy (from iCloud only once the user said yes), and
            // re-encoded in Save Space mode.
            let prepared: Prepared
            if let ready = carried {
                prepared = ready
                carried = nil
            } else {
                if freeBytes() < minimumFreeBytes {
                    if !inParts { throw OutOfSpace() }
                    if hasEntries { break }
                    throw PhoneFull()
                }
                let fetched = staging.appendingPathComponent(UUID().uuidString)
                do {
                    try await fetch(item, to: fetched)
                } catch {
                    try? FileManager.default.removeItem(at: fetched)
                    if isOutOfSpace(error) {
                        if !inParts { throw OutOfSpace() }
                        // Try it again in the next part, once this zip is off the phone.
                        if hasEntries { break }
                        skip(item, "too big for the free space on this iPhone")
                    } else if PhotoSource.isICloudOnly(error) {
                        // Never downloaded without asking: held back until
                        // the rest is done, then the user decides.
                        held.append(item)
                    } else {
                        skip(item, error.localizedDescription)
                    }
                    index += 1
                    continue
                }
                prepared = try await shrinkIfAsked(item, fetched, staging: staging)
            }
            let temp = prepared.url

            // 2. Room for it in the zip? Its exact size is known now.
            if freeBytes() < fileSize(temp) + minimumFreeBytes {
                if !inParts {
                    try? FileManager.default.removeItem(at: temp)
                    throw OutOfSpace()
                }
                if hasEntries {
                    carriedOut = prepared
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
                    try archive.addEntry(with: prepared.pathInZip, fileURL: temp, compressionMethod: .none)
                    manifest.assetPaths[photo.assetID, default: []].append(prepared.pathInZip)
                    if prepared.shrunk { manifest.shrunkAssets.insert(photo.assetID) }
                case .file(let url, let pathInZip):
                    try archive.addEntry(with: pathInZip, fileURL: temp, compressionMethod: .deflate)
                    manifest.files[pathInZip] = url
                }
            } catch {
                try? FileManager.default.removeItem(at: temp)
                if isOutOfSpace(error) { throw inParts ? PhoneFull() : OutOfSpace() }
                throw ZipDamaged(file: item.displayName, reason: error.localizedDescription)
            }
            bytesInPart += fileSize(temp)
            try? FileManager.default.removeItem(at: temp)
            hasEntries = true
            index += 1
        }

        progress(index, "")
        succeeded = true
        return Part(zip: zipURL, next: index, carried: carriedOut, manifest: manifest, skipped: skipped, held: held)
    }

    /// Adds "Skipped files.txt" to a finished zip that stays on the phone.
    private nonisolated static func appendReport(_ text: String, to zipURL: URL) throws {
        let archive = try Archive(url: zipURL, accessMode: .update)
        let report = Data(text.utf8)
        try archive.addEntry(with: "Skipped files.txt", type: .file, uncompressedSize: Int64(report.count)) { position, size in
            report.subdata(in: Int(position)..<Int(position) + size)
        }
    }

    private nonisolated static func skippedReport(_ skipped: [String], inICloud: [String]) -> String {
        var report = ""
        if !skipped.isEmpty {
            report += "Not included in this export:\n\n" + skipped.joined(separator: "\n") + "\n"
        }
        if !inICloud.isEmpty {
            if !report.isEmpty { report += "\n" }
            report += "Stored only in iCloud and left there (you chose not to download them):\n\n"
                + inICloud.joined(separator: "\n") + "\n"
        }
        return report
    }

    /// In Save Space mode, swaps the fetched file for a re-encoded one. If
    /// re-encoding fails or doesn't make it smaller, the untouched original
    /// goes in instead (under its own name), so nothing is ever lost.
    private nonisolated static func shrinkIfAsked(_ item: ExportItem, _ temp: URL, staging: URL) async throws -> Prepared {
        guard case .photoResource(let photo) = item, let kind = photo.shrink else {
            return Prepared(url: temp, pathInZip: item.pathInZip, shrunk: false)
        }
        let ext = (photo.pathInZip as NSString).pathExtension
        let shrunk = staging.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        do {
            switch kind {
            case .photo: try Shrinker.shrinkPhoto(temp, to: shrunk)
            case .video: try await Shrinker.shrinkVideo(temp, to: shrunk, fileType: Shrinker.videoFileType(forExtension: ext))
            }
            if fileSize(shrunk) > 0 && fileSize(shrunk) < fileSize(temp) {
                try? FileManager.default.removeItem(at: temp)
                return Prepared(url: shrunk, pathInZip: photo.pathInZip, shrunk: true)
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: shrunk)
            try? FileManager.default.removeItem(at: temp)
            throw CancellationError()
        } catch {
            // Fall through to the original.
        }
        try? FileManager.default.removeItem(at: shrunk)
        return Prepared(url: temp, pathInZip: photo.fallbackPath ?? photo.pathInZip, shrunk: false)
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
