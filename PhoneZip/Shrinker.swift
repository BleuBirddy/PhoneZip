@preconcurrency import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// "Save Space" mode: re-encodes photos and (optionally) videos so the export
/// is a fraction of the size. This is lossy: the shrunk copies are NOT the
/// originals, so anything shrunk is never offered for deletion.
struct SpaceSaver: Sendable {
    /// Leave videos exactly as they are (videos are usually most of the size,
    /// so keeping them means a much smaller saving).
    var keepOriginalVideos: Bool
}

enum Shrinker {
    enum Kind: Sendable {
        case photo
        case video
    }

    /// HEIC quality for photos. 0.6 looks the same as the original at normal
    /// viewing sizes and is roughly half the size of an iPhone HEIC, a third
    /// of a JPEG.
    private static let photoQuality = 0.6

    /// Re-encodes a photo (JPEG, HEIC, PNG, RAW...) as HEIC at full resolution,
    /// keeping its date, location, orientation and camera details.
    static func shrinkPhoto(_ source: URL, to destination: URL) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(input) > 0 else { throw Failed("not a readable image") }
        guard let output = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw Failed("HEIC encoding isn't available")
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = photoQuality
        CGImageDestinationAddImageFromSource(output, input, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw Failed("HEIC encoding failed") }
    }

    /// Re-encodes a video as HEVC at up to 1080p. A 4K iPhone video usually
    /// ends up 75–85% smaller, a 1080p H.264 one about half.
    static func shrinkVideo(_ source: URL, to destination: URL, fileType: AVFileType) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVC1920x1080) else {
            throw Failed("HEVC encoding isn't available")
        }
        session.outputURL = destination
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = false
        // Keeps the date and location the video was taken.
        session.metadata = try await asset.load(.metadata)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.exportAsynchronously {
                    switch session.status {
                    case .completed: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    default: continuation.resume(throwing: session.error ?? Failed("video encoding failed"))
                    }
                }
            }
        } onCancel: {
            session.cancelExport()
        }
    }

    static func videoFileType(forExtension ext: String) -> AVFileType {
        ["mp4", "m4v"].contains(ext.lowercased()) ? .mp4 : .mov
    }

    struct Failed: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}
