import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// Turns a recorded MP4 into a looping GIF: sampled at a lower frame rate and
/// downscaled, written with ImageIO. Runs off the main thread.
enum GIFExporter {

    static func export(videoURL: URL, to dest: URL,
                       fps: Double = 15, maxWidth: CGFloat = 820,
                       completion: @escaping (Bool) -> Void) {
        Task.detached(priority: .userInitiated) {
            let ok = await render(videoURL: videoURL, to: dest, fps: fps, maxWidth: maxWidth)
            await MainActor.run { completion(ok) }
        }
    }

    private static func render(videoURL: URL, to dest: URL, fps: Double, maxWidth: CGFloat) async -> Bool {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let durationT = try? await asset.load(.duration) else { return false }
        let duration = durationT.seconds
        guard duration > 0 else { return false }

        let natural = (try? await track.load(.naturalSize)) ?? CGSize(width: 800, height: 600)
        let frameCount = max(1, Int(duration * fps))

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let downscale = min(1, maxWidth / max(1, natural.width))
        gen.maximumSize = CGSize(width: natural.width * downscale, height: natural.height * downscale)

        try? FileManager.default.removeItem(at: dest)
        guard let out = CGImageDestinationCreateWithURL(
            dest as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else { return false }

        CGImageDestinationSetProperties(out, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let frameProps = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 1.0 / fps]
        ] as CFDictionary

        var wrote = 0
        for i in 0..<frameCount {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let cg = try? gen.copyCGImage(at: t, actualTime: nil) {
                CGImageDestinationAddImage(out, cg, frameProps)
                wrote += 1
            }
        }
        guard wrote > 0 else { return false }
        return CGImageDestinationFinalize(out)
    }
}
