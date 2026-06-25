import AVFoundation
import ScreenCaptureKit
import CoreMedia
import AppKit

/// What to record. Rectangles are in screen points; the recorder converts them
/// to each display's local coordinate space.
enum RecordTarget {
    case display(SCDisplay)
    case window(SCWindow)
    case area(SCDisplay, CGRect)   // rect in global screen points (top-left origin)
}

/// Captures a display, a window, or a dragged region with ScreenCaptureKit and
/// writes it straight to an MP4 via AVAssetWriter. Frames are H.264-compressed in
/// real time; the cursor is included. Needs Screen Recording permission (the same
/// grant "Screenshot site" uses).
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "com.macsnap.recorder.samples")

    private(set) var outputURL: URL?
    /// Called on the main queue when writing has finished (or failed → nil).
    var onFinish: ((URL?) -> Void)?

    var isRecording: Bool { stream != nil }

    // MARK: - Shareable content

    /// Current displays and on-screen windows, for the picker. Throws if Screen
    /// Recording isn't granted yet.
    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    // MARK: - Start / stop

    func start(target: RecordTarget, to url: URL, fps: Int = 30) async throws {
        let (filter, config) = try makeFilterAndConfig(target: target, fps: fps)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, config.width * config.height * 6),
                AVVideoMaxKeyFrameIntervalKey: fps,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.cannotConfigureWriter }
        writer.add(input)

        self.writer = writer
        self.input = input
        self.outputURL = url

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() {
        guard let stream else { finish(nil); return }
        self.stream = nil
        Task {
            try? await stream.stopCapture()
            queue.async { [weak self] in self?.finalizeWriting() }
        }
    }

    private func finalizeWriting() {
        guard let writer, let input, writer.status == .writing else {
            finish(writer?.status == .completed ? outputURL : nil)
            return
        }
        input.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            let ok = writer.status == .completed
            self.finish(ok ? self.outputURL : nil)
        }
    }

    private func finish(_ url: URL?) {
        writer = nil; input = nil
        DispatchQueue.main.async { [onFinish] in onFinish?(url) }
    }

    // MARK: - Filter + configuration

    private func makeFilterAndConfig(target: RecordTarget, fps: Int) throws -> (SCContentFilter, SCStreamConfiguration) {
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6
        config.scalesToFit = false

        let filter: SCContentFilter

        switch target {
        case .display(let d):
            filter = SCContentFilter(display: d, excludingWindows: [])
            let s = scale(for: d)
            config.width = even(Int(CGFloat(d.width) * s))
            config.height = even(Int(CGFloat(d.height) * s))

        case .window(let w):
            filter = SCContentFilter(desktopIndependentWindow: w)
            let s = scaleForWindow(w)
            config.width = even(Int(w.frame.width * s))
            config.height = even(Int(w.frame.height * s))

        case .area(let d, let globalRect):
            filter = SCContentFilter(display: d, excludingWindows: [])
            let local = displayLocalRect(globalRect, display: d)
            let s = scale(for: d)
            config.sourceRect = local
            config.width = even(Int(local.width * s))
            config.height = even(Int(local.height * s))
        }

        return (filter, config)
    }

    /// Convert a global (top-left origin) screen rect to the display's local
    /// top-left coordinate space that `sourceRect` expects.
    private func displayLocalRect(_ global: CGRect, display: SCDisplay) -> CGRect {
        guard let screen = nsScreen(for: display) else { return global }
        // NSScreen frames are bottom-left origin; global rect here is top-left.
        let originX = global.minX - screen.frame.minX
        let originY = global.minY - screen.frame.minY
        return CGRect(x: originX, y: originY, width: global.width, height: global.height).integral
    }

    private func even(_ n: Int) -> Int { n % 2 == 0 ? n : n + 1 }

    private func scale(for display: SCDisplay) -> CGFloat {
        nsScreen(for: display)?.backingScaleFactor ?? 2
    }

    private func scaleForWindow(_ w: SCWindow) -> CGFloat {
        let mid = CGPoint(x: w.frame.midX, y: w.frame.midY)
        for screen in NSScreen.screens where screen.frame.contains(mid) {
            return screen.backingScaleFactor
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    private func nsScreen(for display: SCDisplay) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let writer, let input else { return }

        // Only append frames the system marks complete; idle/blank frames carry a
        // non-complete status and would stall the writer.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete else { return }

        if writer.status == .unknown {
            let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: start)
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("macsnap: capture stopped with error — \(error.localizedDescription)")
        self.stream = nil
        queue.async { [weak self] in self?.finalizeWriting() }
    }
}

enum RecorderError: Error { case cannotConfigureWriter }
