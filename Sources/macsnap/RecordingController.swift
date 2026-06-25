import AppKit
import ScreenCaptureKit

/// Orchestrates a recording: checks Screen Recording permission, runs the region
/// picker, drives `ScreenRecorder`, and files the finished MP4 into
/// `~/Desktop/MacSnap Recordings/`.
final class RecordingController {

    private let recorder = ScreenRecorder()
    private let selection = RecordSelectionController()

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
        Task { @MainActor in
            do {
                let content = try await ScreenRecorder.shareableContent()
                selection.begin(content: content) { [weak self] target in
                    guard let self, let target else { return }   // nil = cancelled
                    Task { @MainActor in await self.begin(target) }
                }
            } catch {
                NSLog("macsnap: could not read shareable content — \(error.localizedDescription)")
                screenRecordingAlert()
            }
        }
    }

    private func begin(_ target: RecordTarget) async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsnap-rec-\(UUID().uuidString).mp4")

        recorder.onFinish = { [weak self] finished in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRecording = false
                self.onStateChange?()
                if let finished { self.save(finished) }
            }
        }

        do {
            try await recorder.start(target: target, to: url)
            isRecording = true
            onStateChange?()
        } catch {
            NSLog("macsnap: recording failed to start — \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRecording else { return }
        recorder.stop()
    }

    private func save(_ temp: URL) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let dest = Self.recordingsDirectory()
            .appendingPathComponent("Recording \(stamp.string(from: Date())).mp4")
        do {
            try FileManager.default.moveItem(at: temp, to: dest)
            onFinished?(dest)
        } catch {
            NSLog("macsnap: could not save recording — \(error.localizedDescription)")
            onFinished?(temp)   // hand back the temp so the work isn't lost
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
