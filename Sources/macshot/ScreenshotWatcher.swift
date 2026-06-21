import AppKit
import CoreServices

/// Watches the folder where macOS saves screenshots and fires when a new one lands.
final class ScreenshotWatcher {
    let directory: URL
    var onNewScreenshot: ((URL) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var known: Set<String> = []

    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "heic"]

    init(directory: URL? = nil) {
        self.directory = directory ?? ScreenshotWatcher.screenshotDirectory()
    }

    var directoryName: String {
        directory.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    /// Resolve the configured screenshot location, defaulting to ~/Desktop.
    static func screenshotDirectory() -> URL {
        if let loc = CFPreferencesCopyAppValue(
            "location" as CFString, "com.apple.screencapture" as CFString) as? String,
           !loc.isEmpty {
            return URL(fileURLWithPath: (loc as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
    }

    func start() {
        known = currentImageNames()
        fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("macshot: could not watch \(directory.path) (errno \(errno))")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename], queue: .main)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
        }
        source = src
        src.resume()
        NSLog("macshot: watching \(directory.path)")
    }

    func stop() { source?.cancel(); source = nil }

    private func currentImageNames() -> Set<String> {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return Set(items.filter { Self.imageExts.contains($0.pathExtension.lowercased()) }
            .map { $0.lastPathComponent })
    }

    private func scan() {
        let now = currentImageNames()
        let added = now.subtracting(known)
        known = now
        for name in added {
            verify(directory.appendingPathComponent(name))
        }
    }

    /// Fire the instant the file is a *complete* screenshot — no fixed delay. The first
    /// check runs synchronously the moment the file appears, so a normal screenshot
    /// (written atomically) shows up essentially instantly. Only a still-writing file
    /// polls, and at a tight 30ms cadence.
    private func verify(_ url: URL, attempt: Int = 0) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if isScreenCapture(url), isComplete(url) {
            onNewScreenshot?(url)
            return
        }
        guard attempt < 80 else { return }           // ~2.4s safety cap
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.verify(url, attempt: attempt + 1)
        }
    }

    /// True once the file ends with its format's end-of-file marker (so it's fully written).
    private func isComplete(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        switch url.pathExtension.lowercased() {
        case "png":
            guard size >= 8 else { return false }
            try? handle.seek(toOffset: size - 8)
            return handle.readData(ofLength: 8) == Data([0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]) // IEND + CRC
        case "jpg", "jpeg":
            guard size >= 2 else { return false }
            try? handle.seek(toOffset: size - 2)
            return handle.readData(ofLength: 2) == Data([0xFF, 0xD9])                                     // EOI
        default:
            return size > 0     // heic/tiff/gif: accept once non-empty (rare for screenshots)
        }
    }

    private func isScreenCapture(_ url: URL) -> Bool {
        // Spotlight metadata is the definitive signal.
        if let item = MDItemCreate(nil, url.path as CFString),
           let value = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? NSNumber,
           value.boolValue {
            return true
        }
        // Fallback heuristic before Spotlight indexes (covers default naming).
        let n = url.lastPathComponent
        return n.hasPrefix("Screenshot") || n.hasPrefix("Screen Shot") || n.hasPrefix("CleanShot")
    }
}
