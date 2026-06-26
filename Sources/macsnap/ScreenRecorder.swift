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

/// What the finished recording is saved as.
enum RecordFormat { case video, gif }

/// Captures a display, a window, or a dragged region with ScreenCaptureKit and
/// writes it straight to an MP4 via AVAssetWriter. Frames are H.264-compressed in
/// real time; the cursor is included. Needs Screen Recording permission (the same
/// grant "Screenshot site" uses).
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "com.macsnap.recorder.samples")

    // Pause support: paused frames are dropped, and the paused span is subtracted
    // from every later frame's timestamp so it isn't in the finished video.
    private var paused = false
    private var timeOffset = CMTime.zero
    private var pauseStartPTS: CMTime?
    private var lastPTS = CMTime.zero

    private(set) var outputURL: URL?
    /// Called on the main queue when writing has finished (or failed → nil).
    var onFinish: ((URL?) -> Void)?

    var isRecording: Bool { stream != nil }
    private(set) var isPaused = false

    func pause() {
        queue.async { [weak self] in
            guard let self, !self.paused else { return }
            self.paused = true
            self.pauseStartPTS = self.lastPTS
        }
        isPaused = true
    }

    func resume() {
        queue.async { [weak self] in
            guard let self, self.paused else { return }
            self.paused = false   // the next frame computes the paused gap
        }
        isPaused = false
    }

    // MARK: - Shareable content

    /// Current displays and on-screen windows, for the picker. Throws if Screen
    /// Recording isn't granted yet.
    static func shareableContent() async throws -> SCShareableContent {
        // Exclude desktop windows (wallpaper, desktop icons) so the window picker
        // only sees real app windows.
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
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
        paused = false; isPaused = false; timeOffset = .zero; pauseStartPTS = nil; lastPTS = .zero

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

    /// Convert a global, top-left-origin screen rect (CG coordinates) to the
    /// display's local top-left space that `sourceRect` expects.
    private func displayLocalRect(_ globalTopLeft: CGRect, display: SCDisplay) -> CGRect {
        let bounds = CGDisplayBounds(display.displayID)   // top-left origin, global
        return CGRect(x: globalTopLeft.minX - bounds.minX,
                      y: globalTopLeft.minY - bounds.minY,
                      width: globalTopLeft.width, height: globalTopLeft.height).integral
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

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        lastPTS = pts
        if paused { return }   // drop frames while paused

        // First frame after a resume: fold the paused span into the running offset.
        if let ps = pauseStartPTS {
            timeOffset = timeOffset + (pts - ps)
            pauseStartPTS = nil
        }

        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: pts - timeOffset)
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }

        // Re-time the frame by the accumulated paused offset so playback is seamless.
        let buffer = timeOffset == .zero ? sampleBuffer : Self.retimed(sampleBuffer, minus: timeOffset)
        if let buffer { input.append(buffer) }
    }

    /// A copy of `buffer` with its presentation/decode timestamps shifted earlier
    /// by `offset` (the total paused duration so far).
    private static func retimed(_ buffer: CMSampleBuffer, minus offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return buffer }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil)
        for i in 0..<count {
            timings[i].presentationTimeStamp = timings[i].presentationTimeStamp - offset
            if timings[i].decodeTimeStamp.isValid { timings[i].decodeTimeStamp = timings[i].decodeTimeStamp - offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                                              sampleTimingEntryCount: count, sampleTimingArray: &timings,
                                              sampleBufferOut: &out)
        return out
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("macsnap: capture stopped with error — \(error.localizedDescription)")
        self.stream = nil
        queue.async { [weak self] in self?.finalizeWriting() }
    }
}

enum RecorderError: Error { case cannotConfigureWriter }
