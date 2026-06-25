import AppKit

/// Holds the screenshots you've pinned. Pins are real copies kept in Application
/// Support, so they survive even if you move or delete the original.
final class PinStore {
    let dir: URL
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "heic"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v"]
    static let pinnableExts: Set<String> = imageExts.union(videoExts)

    static func isVideo(_ url: URL) -> Bool { videoExts.contains(url.pathExtension.lowercased()) }

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("macsnap", isDirectory: true)
        dir = base.appendingPathComponent("Pinned", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Copy a screenshot into the pin store. Returns the pinned URL.
    @discardableResult
    func pin(_ file: URL) -> URL? {
        let fm = FileManager.default
        let ext = file.pathExtension
        let base = file.deletingPathExtension().lastPathComponent
        var dest = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext); n += 1
        }
        do { try fm.copyItem(at: file, to: dest); return dest }
        catch { NSLog("macsnap: pin failed — \(error.localizedDescription)"); return nil }
    }

    /// Pin a raw image that isn't a file on disk — dragged from a browser, Preview,
    /// Photos, a screenshot tool, anywhere. Encodes it to PNG in the pin store.
    @discardableResult
    func pinImage(_ image: NSImage, baseName: String = "Dropped Image") -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let fm = FileManager.default
        var dest = dir.appendingPathComponent(baseName).appendingPathExtension("png")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(baseName) \(n)").appendingPathExtension("png"); n += 1
        }
        do { try png.write(to: dest); return dest }
        catch { NSLog("macsnap: pin image failed — \(error.localizedDescription)"); return nil }
    }

    /// Remove a pin (to the Trash, so it's recoverable).
    func unpin(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// True once a copy of `file` (matched by name) already lives in the pin store.
    func isPinned(_ file: URL) -> Bool {
        pins().contains { $0.lastPathComponent == file.lastPathComponent }
    }

    /// Pinned screenshots and recordings, newest first.
    func pins() -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { Self.pinnableExts.contains($0.pathExtension.lowercased()) }
            .sorted { (modDate($0) ?? .distantPast) > (modDate($1) ?? .distantPast) }
    }

    private func modDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
