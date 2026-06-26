import AppKit
import ScreenCaptureKit

/// Orchestrates a recording: checks Screen Recording permission, runs the region
/// picker, drives `ScreenRecorder`, and files the finished MP4 into
/// `~/Desktop/MacSnap Recordings/`.
final class RecordingController {

    private let recorder = ScreenRecorder()
    private let selection = RecordSelectionController()
    private let hotKeys = GlobalHotKeys()

    private(set) var isRecording = false

    /// Fired whenever recording starts or stops, so the menu can re-render.
    var onStateChange: (() -> Void)?
    /// Fired with the saved file once a recording is written.
    var onFinished: ((URL) -> Void)?

    /// `~/Desktop/MacSnap Recordings`, created on first use.
    static func recordingsDirectory() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("MacSnap Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Flow

    func toggle() { isRecording ? stop() : startFlow() }

    func startFlow() {
        guard !isRecording else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            screenRecordingAlert()
            return
        }
        // The overlay drives the flow (pick → adjust → Start → Pause/Stop); we drive
        // the recorder in response.
        selection.onStart = { [weak self] target, format in Task { @MainActor in await self?.begin(target, format) } }
        selection.onPauseToggle = { [weak self] in
            guard let self else { return }
            self.recorder.isPaused ? self.recorder.resume() : self.recorder.pause()
        }
        selection.onStop = { [weak self] in self?.recorder.stop() }   // onFinish saves + dismisses
        selection.onCancel = { [weak self] in self?.selection.dismiss() }

        Task { @MainActor in
            do {
                let content = try await ScreenRecorder.shareableContent()
                selection.begin(content: content)
            } catch {
                NSLog("macsnap: could not read shareable content — \(error.localizedDescription)")
                screenRecordingAlert()
            }
        }
    }

    private func begin(_ target: RecordTarget, _ format: RecordFormat) async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsnap-rec-\(UUID().uuidString).mp4")

        recorder.onFinish = { [weak self] finished in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hotKeys.unregister()                       // restore normal ⌘P / ⌘S
                self.selection.dismiss()
                self.isRecording = false
                self.onStateChange?()
                if let finished { self.save(finished, format: format) }
            }
        }

        do {
            try await recorder.start(target: target, to: url)
            await MainActor.run {
                self.isRecording = true
                // ⌘P pause, ⌘S stop — system-wide while recording.
                self.hotKeys.register(onPause: { [weak self] in self?.selection.hotkeyPause() },
                                      onStop:  { [weak self] in self?.selection.hotkeyStop() })
                self.onStateChange?()
            }
        } catch {
            await MainActor.run { self.hotKeys.unregister(); self.selection.dismiss() }   // failed — drop the overlay
            NSLog("macsnap: recording failed to start — \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRecording else { return }
        recorder.stop()   // its onFinish saves + dismisses the overlay
    }

    private func save(_ temp: URL, format: RecordFormat) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let base = "Recording \(stamp.string(from: Date()))"

        switch format {
        case .video:
            let dest = Self.recordingsDirectory().appendingPathComponent("\(base).mp4")
            do { try FileManager.default.moveItem(at: temp, to: dest); onFinished?(dest) }
            catch { NSLog("macsnap: could not save recording — \(error.localizedDescription)"); onFinished?(temp) }

        case .gif:
            // Convert the captured MP4 to a GIF, then drop the temp video.
            let dest = Self.recordingsDirectory().appendingPathComponent("\(base).gif")
            GIFExporter.export(videoURL: temp, to: dest) { [weak self] ok in
                try? FileManager.default.removeItem(at: temp)
                if ok { self?.onFinished?(dest) }
                else { NSLog("macsnap: GIF export failed"); NSSound.beep() }
            }
        }
    }

    // MARK: - Permission prompt (mirrors the one used for Screenshot site)

    private func screenRecordingAlert() {
        let alert = NSAlert()
        alert.messageText = "One-time setup: Screen Recording"
        alert.informativeText = "To record your screen, macsnap needs Screen Recording.\n\n1. Click Open Settings and turn ON macsnap under Screen Recording.\n2. Come back and start the recording again.\n\nThanks to a stable signature you only do this once."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
