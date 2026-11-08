import Foundation

/// One thing to put in the zip. Photos and files are fetched differently, but
/// the zip writer only needs "give me a local file, then I'll add it".
enum ExportItem {
    case photoResource(PhotoSource.Item)
    case file(url: URL, pathInZip: String)
}

/// What an export put in the zip and where each file came from. Deleting
/// originals later is driven only by this list, so nothing that wasn't
/// exported (or failed to export) can be deleted.
struct ExportManifest {
    /// Photo library item → every path in the zip that belongs to it.
    var assetPaths: [String: [String]] = [:]
    /// Photos with at least one file that failed to export. Never deleted.
    var incompleteAssets = Set<String>()
    /// Photos with at least one file re-encoded by Save Space. The drive only
    /// has a lower-quality copy, so these are never deleted from the phone.
    var shrunkAssets = Set<String>()
    /// Path in the zip → the document it was copied from.
    var files: [String: URL] = [:]

    /// Combines the parts of an export that went out as several zips. A photo
    /// split across two parts keeps all its paths, so it is still deleted
    /// only when every one of them is on the drive.
    mutating func merge(_ other: ExportManifest) {
        for (id, paths) in other.assetPaths { assetPaths[id, default: []] += paths }
        incompleteAssets.formUnion(other.incompleteAssets)
        shrunkAssets.formUnion(other.shrunkAssets)
        files.merge(other.files) { _, new in new }
    }
}

extension ExportItem {
    /// Photos count once however many files they have (Live Photo video, RAW,
    /// original), so a batch of 500 means 500 things in Photos.
    var unit: String {
        switch self {
        case .photoResource(let photo): "asset:" + photo.assetID
        case .file(let url, _): "file:" + url.path
        }
    }

    var displayName: String {
        switch self {
        case .photoResource(let photo): (photo.pathInZip as NSString).lastPathComponent
        case .file(let url, _): url.lastPathComponent
        }
    }

    var pathInZip: String {
        switch self {
        case .photoResource(let photo): photo.pathInZip
        case .file(_, let path): path
        }
    }
}

/// Hands out unique paths inside the zip. Two photos named IMG_0001.HEIC in the
/// same month (common after a phone reset) would otherwise overwrite each other.
struct ZipPathAllocator {
    private var used = Set<String>()

    mutating func unique(_ path: String) -> String {
        // Apple file systems hand back "é" as e + a separate accent mark.
        // Windows and many zip tools expect the single-character form, and
        // otherwise show "Cafe??" or treat two spellings as different files.
        let path = path.precomposedStringWithCanonicalMapping
        guard used.contains(path.lowercased()) else {
            used.insert(path.lowercased())
            return path
        }
        let ns = path as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if !used.contains(candidate.lowercased()) {
                used.insert(candidate.lowercased())
                return candidate
            }
            n += 1
        }
    }
}
