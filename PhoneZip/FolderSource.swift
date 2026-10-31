import Foundation
import UIKit

/// Reads folders the user picked in the Files picker. iOS never lets an app
/// browse the whole phone; the picker is the only door, and the URL it returns
/// only works between start/stopAccessingSecurityScopedResource calls.
final class PickedFolder: Identifiable {
    let id = UUID()
    let url: URL
    private let hasAccess: Bool

    init(url: URL) {
        self.url = url
        hasAccess = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if hasAccess { url.stopAccessingSecurityScopedResource() }
    }

    /// The name Files shows. Top-level locations have internal folder names
    /// ("On My iPhone" is really "File Provider Storage" on disk).
    /// iOS gives no localized name for the On My iPhone root, so it is
    /// recognized by its on-disk name.
    var name: String {
        let localized = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
        return localized == "File Provider Storage" ? "On My \(UIDevice.current.model)" : localized
    }
}

enum FolderSource {
    /// Every regular file under each folder, filed as Files/<folder>/<subpath>.
    /// Hidden files are skipped (.DS_Store and app caches nobody wants back).
    static func items(in folders: [PickedFolder], paths: inout ZipPathAllocator) -> [ExportItem] {
        // PhoneZip's own folder is pickable too. Without this, an export would
        // swallow old exports and the zip it is writing (which keeps growing).
        let ownFolder = Exporter.documents.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var result: [ExportItem] = []
        for folder in folders {
            let base = folder.url.standardizedFileURL.resolvingSymlinksInPath()
            guard let walker = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else { continue }

            for case let found as URL in walker {
                let name = found.lastPathComponent
                var file = found
                if name.hasPrefix(".") {
                    // iCloud Drive can keep a file that isn't downloaded as a
                    // hidden ".Report.pdf.icloud" stand-in. That is a real file
                    // to export (reading it downloads it); any other hidden
                    // item is skipped.
                    guard name.hasSuffix(".icloud"), name.count >= ".x.icloud".count else {
                        walker.skipDescendants()
                        continue
                    }
                    file = found.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
                } else {
                    guard (try? found.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                }
                let full = file.standardizedFileURL.resolvingSymlinksInPath().path
                if full.hasPrefix(ownFolder) { continue }
                let relative = full.hasPrefix(base.path + "/") ? String(full.dropFirst(base.path.count + 1)) : file.lastPathComponent
                result.append(.file(url: file, pathInZip: paths.unique("Files/\(folder.name)/\(relative)")))
            }
        }
        return result
    }

    /// Copies the file to `temp`, downloading it first if it is only in
    /// iCloud. The zip is filled from that local copy, so a download or read
    /// error can't happen halfway through writing an entry (which would leave
    /// the zip damaged). On the same storage the copy is a clone and takes no space.
    static func copy(_ url: URL, to temp: URL) throws {
        try withReadableFile(url) { readable in
            try FileManager.default.copyItem(at: readable, to: temp)
        }
    }

    /// Runs `body` with a readable local copy of the file. The coordinator is
    /// what makes iCloud Drive download a file that is only a placeholder.
    static func withReadableFile(_ url: URL, _ body: (URL) throws -> Void) throws {
        var coordinatorError: NSError?
        var bodyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readable in
            do { try body(readable) } catch { bodyError = error }
        }
        if let error = coordinatorError ?? bodyError { throw error }
    }
}
