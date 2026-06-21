import AppKit

/// Holds the screenshots you've pinned. Pins are real copies kept in Application
/// Support, so they survive even if you move or delete the original.
final class PinStore {
    let dir: URL
    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "heic"]

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("macshot", isDirectory: true)
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
        catch { NSLog("macshot: pin failed — \(error.localizedDescription)"); return nil }
    }

    /// Remove a pin (to the Trash, so it's recoverable).
    func unpin(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Pinned images, newest first.
    func pins() -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { Self.imageExts.contains($0.pathExtension.lowercased()) }
            .sorted { (modDate($0) ?? .distantPast) > (modDate($1) ?? .distantPast) }
    }

    private func modDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
