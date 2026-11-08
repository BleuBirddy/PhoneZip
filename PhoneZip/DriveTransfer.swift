import Foundation
import Photos
import ZIPFoundation

/// What ended up on the drive.
struct DriveCopy {
    let folder: URL
    /// Paths in the zip whose copy on the drive was read back and matched.
    let verified: Set<String>
    /// Paths that didn't make it, with the reason. Their originals are kept.
    let failed: [String]
    /// The phone's zip is removed only when every file arrived intact.
    let zipRemoved: Bool
}

struct DeleteReport {
    var photosDeleted = 0
    var photosDeclined = 0
    var filesDeleted = 0
    var problems: [String] = []
}

/// Remembers the drive the user picked, so next time it is found as soon as
/// it is plugged in. iOS gives apps no list of attached drives; a drive can
/// only be reached through a folder the user picked in Files, and a bookmark
/// keeps that permission for later.
enum DriveStore {
    private static let key = "driveBookmark"

    static func remember(_ url: URL) {
        if let data = try? url.bookmarkData() {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// The remembered drive, if it is plugged in right now.
    static func recall() -> PickedFolder? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        let folder = PickedFolder(url: url)
        guard (try? url.checkResourceIsReachable()) == true else { return nil }
        if stale { remember(url) }
        return folder
    }

    /// True when the folder is on the phone's own storage. Copying there and
    /// then deleting the originals would leave no copy off the phone at all.
    static func isOnThisPhone(_ url: URL) -> Bool {
        #if targetEnvironment(simulator)
        // The simulator has no USB drives; a folder in Files stands in for one.
        return false
        #else
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let picked = try? url.resourceValues(forKeys: key).volumeIdentifier as? NSObject,
              let phone = try? Exporter.documents.resourceValues(forKeys: key).volumeIdentifier as? NSObject
        else { return false }
        return picked.isEqual(phone)
        #endif
    }
}

enum DriveTransfer {
    struct DriveFull: LocalizedError {
        let needed: Int64
        let free: Int64
        var errorDescription: String? {
            let f = ByteCountFormatter()
            return "The drive doesn't have enough space: this export needs \(f.string(fromByteCount: needed)), the drive has \(f.string(fromByteCount: free)) free. Nothing was deleted; try a bigger drive."
        }
    }

    struct Mismatch: LocalizedError {
        var errorDescription: String? { "the copy on the drive didn't match the original" }
    }

    // MARK: Copy and check

    /// A new folder on the drive named after the export, never reusing an
    /// existing one. Every part of an export is unzipped into it.
    nonisolated static func makeFolder(named name: String, on drive: PickedFolder) throws -> URL {
        var folder = drive.url.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = drive.url.appendingPathComponent("\(name) (\(n))", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Removes a folder made for an export that never got a file into it.
    nonisolated static func removeIfEmpty(_ folder: URL) {
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Unzips straight from the phone onto the drive (no copy of the zip on
    /// the drive, which would need double the space), then reads every file
    /// back from the drive and compares it with the checksum stored in the zip.
    nonisolated static func copy(
        zip: URL, into folder: URL,
        progress: @escaping (Int, Int, String) -> Void
    ) throws -> DriveCopy {
        let archive = try Archive(url: zip, accessMode: .read)
        let entries = archive.filter { $0.type == .file }

        let needed = entries.reduce(Int64(0)) { $0 + Int64($1.uncompressedSize) }
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           Int64(free) < needed + 50_000_000 {
            throw DriveFull(needed: needed, free: Int64(free))
        }

        // A half-finished copy is removed so it can't be mistaken for a
        // backup. Only what this zip added goes; earlier parts stay.
        var created: [URL] = []
        var completed = false
        defer {
            if !completed {
                for url in created.reversed() { try? FileManager.default.removeItem(at: url) }
            }
        }

        var verified = Set<String>()
        var failed: [String] = []
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            progress(index, entries.count, (entry.path as NSString).lastPathComponent)
            guard let dest = safeDestination(entry.path, in: folder) else {
                failed.append("\(entry.path): unsafe path in zip")
                continue
            }
            do {
                try makeParents(of: dest, in: folder, recording: &created)
                created.append(dest)
                let written = try archive.extract(entry, to: dest)
                guard written == entry.checksum else { throw Mismatch() }
                flushToDisk(dest)
                let (onDisk, size) = try readBack(dest)
                guard onDisk == entry.checksum, size == entry.uncompressedSize else { throw Mismatch() }
                verified.insert(entry.path)
            } catch {
                if Exporter.isOutOfSpace(error) { throw DriveFull(needed: needed, free: 0) }
                failed.append("\(entry.path): \(error.localizedDescription)")
            }
        }
        progress(entries.count, entries.count, "")
        completed = true

        let zipRemoved = failed.isEmpty && (try? FileManager.default.removeItem(at: zip)) != nil
        return DriveCopy(folder: folder, verified: verified, failed: failed, zipRemoved: zipRemoved)
    }

    /// Creates the folders above `dest`, noting each new one so a cancelled
    /// part can take them away again.
    private static func makeParents(of dest: URL, in folder: URL, recording created: inout [URL]) throws {
        var missing: [URL] = []
        var parent = dest.deletingLastPathComponent()
        while parent.path.count > folder.standardizedFileURL.path.count, !FileManager.default.fileExists(atPath: parent.path) {
            missing.append(parent)
            parent = parent.deletingLastPathComponent()
        }
        for dir in missing.reversed() {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            created.append(dir)
        }
    }

    /// Where an entry goes, or nil if its path would escape the folder
    /// ("../" tricks). Our own zips never contain those, but the check is cheap.
    private static func safeDestination(_ path: String, in folder: URL) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let dest = folder.appendingPathComponent(path).standardizedFileURL
        return dest.path.hasPrefix(folder.standardizedFileURL.path + "/") ? dest : nil
    }

    /// Asks the drive to actually store the file, not just hold it in a write
    /// cache that is lost if the drive is unplugged.
    private static func flushToDisk(_ url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0 { fsync(handle.fileDescriptor) }
        try? handle.close()
    }

    /// Reads the file back from the drive, bypassing the cache (otherwise iOS
    /// may hand back the bytes it just wrote from memory, proving nothing).
    private static func readBack(_ url: URL) throws -> (CRC32, UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        var crc: CRC32 = 0
        var size: UInt64 = 0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            crc = chunk.crc32(checksum: crc)
            size += UInt64(chunk.count)
        }
        return (crc, size)
    }

    // MARK: Deleting originals

    /// Photos whose every exported file is verified on the drive, at full
    /// quality. Anything Save Space re-encoded is never deleted.
    static func deletableAssets(_ manifest: ExportManifest, verified: Set<String>) -> [String] {
        manifest.assetPaths.compactMap { id, paths in
            !manifest.incompleteAssets.contains(id) && !manifest.shrunkAssets.contains(id)
                && paths.allSatisfy(verified.contains) ? id : nil
        }
    }

    static func deletableFiles(_ manifest: ExportManifest, verified: Set<String>) -> [URL] {
        manifest.files.compactMap { path, url in verified.contains(path) ? url : nil }
    }

    static func deleteOriginals(_ manifest: ExportManifest, verified: Set<String>) async -> DeleteReport {
        var report = DeleteReport()

        let ids = deletableAssets(manifest, verified: verified)
        if !ids.isEmpty {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            do {
                // iOS shows its own "Allow PhoneZip to delete N photos?" prompt
                // here; apps can't skip it. Deleted photos go to Recently Deleted.
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
                }
                report.photosDeleted = assets.count
            } catch {
                if (error as? PHPhotosError)?.code == .userCancelled {
                    report.photosDeclined = assets.count
                } else {
                    report.problems.append("Photos: \(error.localizedDescription)")
                }
            }
        }

        for url in deletableFiles(manifest, verified: verified) {
            do {
                try delete(url)
                report.filesDeleted += 1
            } catch {
                report.problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// Moves the file to Files' Recently Deleted where the location supports
    /// it, else removes it.
    private static func delete(_ url: URL) throws {
        // Locations like On My iPhone and iCloud Drive coordinate the move to
        // Recently Deleted themselves. Wrapping it in our own coordinator
        // deadlocks: each side waits for the other's claim on the same file.
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { return }

        // No trash there: delete for good, coordinated so iCloud Drive and
        // other apps with the file open stay in step.
        var coordinatorError: NSError?
        var deleteError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinatorError) { target in
            do { try FileManager.default.removeItem(at: target) } catch { deleteError = error }
        }
        if let error = coordinatorError ?? deleteError { throw error }
    }
}
