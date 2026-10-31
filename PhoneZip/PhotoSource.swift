import Foundation
import Photos

/// Reads the photo library. Apps can see the whole library once the user taps
/// "Allow Full Access"; with "Limited Access" PhotoKit only returns the photos
/// they picked, so the UI warns when that happens.
enum PhotoSource {
    /// One file to export. A Live Photo becomes two items: the still and its
    /// short video, sharing a name so they stay together in the zip.
    struct Item {
        let resource: PHAssetResource
        let pathInZip: String
    }

    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static var status: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Counts without touching any file data, so the screen can show
    /// "1,204 photos · 87 videos" instantly.
    static func counts() -> (photos: Int, videos: Int) {
        (PHAsset.fetchAssets(with: .image, options: nil).count,
         PHAsset.fetchAssets(with: .video, options: nil).count)
    }

    /// Lists every file to export, oldest first, filed as Photos/2024/2024-05/.
    static func items(photos: Bool, videos: Bool, paths: inout ZipPathAllocator) -> [Item] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = true
        var types: [Int] = []
        if photos { types.append(PHAssetMediaType.image.rawValue) }
        if videos { types.append(PHAssetMediaType.video.rawValue) }
        guard !types.isEmpty else { return [] }
        options.predicate = NSPredicate(format: "mediaType IN %@", types)

        let folderFormat = DateFormatter()
        folderFormat.dateFormat = "yyyy/yyyy-MM"
        folderFormat.locale = Locale(identifier: "en_US_POSIX")

        // Fetch results load lazily in batches, so walking by index is cheap
        // even for a 50,000-photo library.
        let assets = PHAsset.fetchAssets(with: options)
        var result: [Item] = []
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            let folder = asset.creationDate.map { "Photos/" + folderFormat.string(from: $0) } ?? "Photos/Undated"
            for (resource, name) in exportResources(for: asset) {
                result.append(Item(resource: resource, pathInZip: paths.unique("\(folder)/\(name)")))
            }
        }
        return result
    }

    /// Picks which stored files of an asset to export. Each asset can hold
    /// several (original, edited version, Live Photo video, RAW+JPEG pair...).
    /// We export what the user sees in Photos: the edited version when there
    /// is one, else the original, plus the Live Photo video. Edited files are
    /// stored as "FullSizeRender.jpg", so they borrow the original's name.
    private static func exportResources(for asset: PHAsset) -> [(PHAssetResource, String)] {
        let all = PHAssetResource.assetResources(for: asset)
        func first(_ types: PHAssetResourceType...) -> PHAssetResource? {
            for type in types {
                if let match = all.first(where: { $0.type == type }) { return match }
            }
            return nil
        }
        let original = first(.photo, .video, .alternatePhoto) ?? all.first
        let stem = ((original?.originalFilename ?? "Untitled") as NSString).deletingPathExtension

        func named(_ resource: PHAssetResource) -> (PHAssetResource, String) {
            let ext = (resource.originalFilename as NSString).pathExtension
            return (resource, ext.isEmpty ? stem : "\(stem).\(ext)")
        }

        var picked: [(PHAssetResource, String)] = []
        switch asset.mediaType {
        case .image:
            if let main = first(.fullSizePhoto, .photo) { picked.append(named(main)) }
            if let live = first(.fullSizePairedVideo, .pairedVideo) { picked.append(named(live)) }
        case .video:
            if let main = first(.fullSizeVideo, .video) { picked.append(named(main)) }
        default:
            break
        }
        if picked.isEmpty, let any = all.first { picked.append(named(any)) }
        return picked
    }

    /// Copies one resource to a local file. Photos stored only in iCloud
    /// ("Optimize iPhone Storage") get downloaded here, which is the slow part
    /// of most exports.
    static func write(_ item: Item, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: item.resource, toFile: url, options: options)
    }
}
