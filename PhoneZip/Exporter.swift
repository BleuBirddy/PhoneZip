import Foundation
import UIKit
import ZIPFoundation

/// Builds the zip one file at a time: copy a photo to a temp file, add it,
/// delete the temp file. Peak extra space is the zip itself plus one item,
/// never a second full copy of the library.
@MainActor
final class Exporter: ObservableObject {
    enum State {
        case idle
        case preparing
        case running(done: Int, total: Int, current: String)
        case finished(zip: URL, bytes: Int64, skipped: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch state {
        case .preparing, .running: true
        default: false
        }
    }

    func start(photos: Bool, videos: Bool, folders: [PickedFolder]) {
        state = .preparing
        // iOS suspends apps soon after they leave the screen, and auto-lock
        // counts. Keeping the screen awake is the simplest way to let a big
        // export finish; the UI tells the user to keep the app open.
        UIApplication.shared.isIdleTimerDisabled = true

        task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: State
            do {
                let (zip, bytes, skipped) = try await Self.run(photos: photos, videos: videos, folders: folders) { done, total, current in
                    Task { @MainActor in self?.state = .running(done: done, total: total, current: current) }
                }
                outcome = .finished(zip: zip, bytes: bytes, skipped: skipped)
            } catch is CancellationError {
                outcome = .idle
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            await MainActor.run {
                UIApplication.shared.isIdleTimerDisabled = false
                self?.state = outcome
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func reset() {
        state = .idle
    }

    /// Exports already in Documents (visible in the Files app).
    static func existingExports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension == "zip" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    // MARK: - Work (off the main thread)

    struct OutOfSpace: LocalizedError {
        var errorDescription: String? {
            "The iPhone ran out of space. The zip needs about as much free space as the photos and files it holds. Free up space or export less (e.g. photos and videos separately)."
        }
    }

    /// Stop before iOS itself runs dry; a full disk makes the whole phone misbehave.
    private static let minimumFreeBytes: Int64 = 500_000_000

    private nonisolated static func run(
        photos: Bool, videos: Bool, folders: [PickedFolder],
        progress: @escaping (Int, Int, String) -> Void
    ) async throws -> (URL, Int64, Int) {
        var paths = ZipPathAllocator()
        var items = PhotoSource.items(photos: photos, videos: videos, paths: &paths).map(ExportItem.photoResource)
        items += FolderSource.items(in: folders, paths: &paths)

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        // Never reuse a name: two exports in the same minute must not replace
        // an earlier zip that may not have been copied off yet.
        let base = "iPhone Export \(stamp.string(from: Date()))"
        var zipURL = documents.appendingPathComponent("\(base).zip")
        var n = 2
        while FileManager.default.fileExists(atPath: zipURL.path) {
            zipURL = documents.appendingPathComponent("\(base) (\(n)).zip")
            n += 1
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("staging", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        // Anything left half-written is junk, so every failure path removes it.
        var succeeded = false
        defer {
            try? FileManager.default.removeItem(at: staging)
            if !succeeded { try? FileManager.default.removeItem(at: zipURL) }
        }

        let archive = try Archive(url: zipURL, accessMode: .create)
        var skipped: [String] = []

        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            if freeBytes() < minimumFreeBytes { throw OutOfSpace() }

            switch item {
            case .photoResource(let photo):
                progress(index, items.count, (photo.pathInZip as NSString).lastPathComponent)
                let temp = staging.appendingPathComponent(UUID().uuidString)
                do {
                    try await PhotoSource.write(photo, to: temp)
                    // Photos and videos are already compressed; deflating them
                    // again costs minutes and saves almost nothing.
                    try archive.addEntry(with: photo.pathInZip, fileURL: temp, compressionMethod: .none)
                } catch {
                    if Self.isOutOfSpace(error) { throw OutOfSpace() }
                    skipped.append("\(photo.pathInZip): \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: temp)

            case .file(let url, let pathInZip):
                progress(index, items.count, url.lastPathComponent)
                do {
                    try FolderSource.withReadableFile(url) { readable in
                        try archive.addEntry(with: pathInZip, fileURL: readable, compressionMethod: .deflate)
                    }
                } catch {
                    if Self.isOutOfSpace(error) { throw OutOfSpace() }
                    skipped.append("\(pathInZip): \(error.localizedDescription)")
                }
            }
        }

        // A list of what didn't make it, inside the zip, so a missing photo
        // isn't discovered months later.
        if !skipped.isEmpty {
            let report = Data(("Not included in this export:\n\n" + skipped.joined(separator: "\n")).utf8)
            try archive.addEntry(with: "Skipped files.txt", type: .file, uncompressedSize: Int64(report.count)) { position, size in
                report.subdata(in: Int(position)..<Int(position) + size)
            }
        }

        progress(items.count, items.count, "")
        succeeded = true
        let bytes = (try? zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        return (zipURL, bytes, skipped.count)
    }

    private nonisolated static func freeBytes() -> Int64 {
        let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    private nonisolated static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        return (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
    }
}
