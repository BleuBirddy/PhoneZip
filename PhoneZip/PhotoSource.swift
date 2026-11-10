import Foundation
import Photos
import UniformTypeIdentifiers

/// Reads the photo library. Apps can see the whole library once the user taps
/// "Allow Full Access"; with "Limited Access" PhotoKit only returns the photos
/// they picked, so the UI warns when that happens.
enum PhotoSource {
    /// One file to export. A Live Photo becomes two items: the still and its
    /// short video, sharing a name so they stay together in the zip.
    struct Item {
        let resource: PHAssetResource
        let pathInZip: String
        /// Which photo this file belongs to, so the photo is only deleted from
        /// the phone once every one of its files is safely on the drive.
        let assetID: String
        /// Set in Save Space mode: re-encode this file before zipping it.
        var shrink: Shrinker.Kind? = nil
        /// Where the untouched file goes if re-encoding fails. A shrunk photo
        /// is renamed to .HEIC, so its original name is reserved too.
        var fallbackPath: String? = nil
        /// Only once the user agreed to download photos kept in iCloud may
        /// PhotoKit fetch this file over the network. Until then a file that
        /// isn't on the phone is held back (see `isICloudOnly`).
        var allowICloud = false
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
        (PHAsset.fetchAssets(with: .image, options: libraryOnly()).count,
         PHAsset.fetchAssets(with: .video, options: libraryOnly()).count)
    }

    /// The user's own library, without Shared Albums: those live in iCloud
    /// and belong partly to other people.
    private static func libraryOnly() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        return options
    }

    /// Where an asset is filed inside "Photo Library": what it is, so videos
    /// and screenshots aren't mixed in with photos.
    static func kindFolder(for asset: PHAsset) -> String {
        if asset.mediaType == .video {
            return asset.mediaSubtypes.contains(.videoScreenRecording) ? "Screen Recordings" : "Videos"
        }
        return asset.mediaSubtypes.contains(.photoScreenshot) ? "Screenshots" : "Photos"
    }

    /// Lists every file to export, oldest first, filed by kind and month, as
    /// Photo Library/Videos/2024/2024-05/. A Live Photo's video stays with
    /// its photo.
    static func items(photos: Bool, videos: Bool, saver: SpaceSaver?, paths: inout ZipPathAllocator) -> [Item] {
        let options = libraryOnly()
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
            let kind = "Photo Library/" + kindFolder(for: asset)
            let folder = kind + "/" + (asset.creationDate.map { folderFormat.string(from: $0) } ?? "Undated")
            for (resource, name) in exportResources(for: asset) {
                let original = "\(folder)/\(name)"
                let item: Item
                switch saver.flatMap({ shrinkKind(resource, $0) }) {
                case .photo:
                    let heic = (original as NSString).deletingPathExtension + ".HEIC"
                    item = Item(resource: resource, pathInZip: paths.unique(heic), assetID: asset.localIdentifier,
                                shrink: .photo, fallbackPath: paths.unique(original))
                case .video:
                    item = Item(resource: resource, pathInZip: paths.unique(original),
                                assetID: asset.localIdentifier, shrink: .video)
                case nil:
                    item = Item(resource: resource, pathInZip: paths.unique(original), assetID: asset.localIdentifier)
                }
                result.append(item)
            }
        }
        return result
    }

    /// Which files Save Space re-encodes: every photo (RAW included), and
    /// every video (Live Photo videos too) unless videos are kept as they are.
    private static func shrinkKind(_ resource: PHAssetResource, _ saver: SpaceSaver) -> Shrinker.Kind? {
        guard let type = UTType(resource.uniformTypeIdentifier) else { return nil }
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
            return saver.keepOriginalVideos ? nil : .video
        }
        return nil
    }

    /// Picks which stored files of an asset to export. Each asset can hold
    /// several (original, edited version, Live Photo video, RAW+JPEG pair...).
    /// We export what the user sees in Photos (the edited version when there
    /// is one) plus the Live Photo video. Because the phone's copy may be
    /// deleted afterwards, edited items also keep their untouched original
    /// ("IMG_0001 (original).HEIC") and RAW+JPEG pairs keep the RAW. Edited
    /// files are stored as "FullSizeRender.jpg", so they borrow the original's name.
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

        func named(_ resource: PHAssetResource, suffix: String = "") -> (PHAssetResource, String) {
            let ext = (resource.originalFilename as NSString).pathExtension
            return (resource, ext.isEmpty ? stem + suffix : "\(stem)\(suffix).\(ext)")
        }

        var picked: [(PHAssetResource, String)] = []
        switch asset.mediaType {
        case .image:
            if let edited = first(.fullSizePhoto) {
                picked.append(named(edited))
                if let original = first(.photo) { picked.append(named(original, suffix: " (original)")) }
            } else if let main = first(.photo) {
                picked.append(named(main))
            }
            if let edited = first(.fullSizePairedVideo) {
                picked.append(named(edited))
                if let original = first(.pairedVideo) { picked.append(named(original, suffix: " (original)")) }
            } else if let live = first(.pairedVideo) {
                picked.append(named(live))
            }
            if let raw = first(.alternatePhoto) { picked.append(named(raw)) }
        case .video:
            if let edited = first(.fullSizeVideo) {
                picked.append(named(edited))
                if let original = first(.video) { picked.append(named(original, suffix: " (original)")) }
            } else if let main = first(.video) {
                picked.append(named(main))
            }
        default:
            break
        }
        if picked.isEmpty, let any = all.first { picked.append(named(any)) }
        return picked
    }

    /// Copies one resource to a local file. A file kept only in iCloud
    /// ("Optimize iPhone Storage") is downloaded only when the user allowed
    /// it; otherwise PhotoKit refuses (see `isICloudOnly`).
    static func write(_ item: Item, to url: URL) async throws {
        #if DEBUG
        // For testing without iCloud: -PZFakeICloud YES on launch makes about
        // a third of the photos act as if they were only in iCloud.
        if !item.allowICloud, UserDefaults.standard.bool(forKey: "PZFakeICloud"),
           item.assetID.unicodeScalars.reduce(0, { $0 + Int($1.value) }) % 3 == 0 {
            throw PHPhotosError(.networkAccessRequired)
        }
        #endif
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = item.allowICloud
        try await PHAssetResourceManager.default().writeData(for: item.resource, toFile: url, options: options)
    }

    /// True when a read failed only because the file is in iCloud and not on
    /// this iPhone, and downloading it wasn't allowed.
    static func isICloudOnly(_ error: Error) -> Bool {
        if let photos = error as? PHPhotosError, photos.code == .networkAccessRequired { return true }
        let ns = error as NSError
        return (ns.domain == PHPhotosErrorDomain && ns.code == PHPhotosError.Code.networkAccessRequired.rawValue)
            || ns.domain == "CloudPhotoLibraryErrorDomain"
    }
}
