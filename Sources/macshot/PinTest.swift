import AppKit

/// End-to-end check of the pin button → pin store → gallery flow: builds the real
/// panel, fires the same closure the pin button fires, and confirms the screenshot
/// is copied into the pin store and would appear in the gallery. Temp files only.
///   swift run macshot --pintest
final class PinTestController: NSObject, NSApplicationDelegate {
    private var stack: OverlayStack?
    private var controller: OverlayController?
    private var dir: URL!
    private var pins: PinStore!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let fm = FileManager.default
        dir = fm.temporaryDirectory.appendingPathComponent("macshot-pin-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("Screenshot pin-test.png")
        writePNG(sampleImage(), to: fileURL)
        pins = PinStore(root: dir.appendingPathComponent("pinroot"))

        let stack = OverlayStack()
        self.stack = stack
        let c = OverlayController(fileURL: fileURL, store: FolderStore(), pins: pins)
        self.controller = c
        stack.add(c)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            let before = self.pins.pins().count
            self.controller?.testInvokePin()            // === clicking the pin button ===
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let after = self.pins.pins().count
                let gallery = GalleryModel()
                gallery.pins = self.pins.pins()          // what the menu-bar gallery would load
                let originalKept = fm.fileExists(atPath: fileURL.path)
                print("pins before click:         \(before)")
                print("pins after pin click:      \(after)")
                print("original screenshot kept:  \(originalKept)")
                print("gallery would show:        \(gallery.pins.count) item(s)")
                let ok = before == 0 && after == 1 && originalKept && gallery.pins.count == 1
                print(ok ? "\nPIN OK" : "\nPIN FAILED")
                try? fm.removeItem(at: self.dir)
                NSApp.terminate(nil)
            }
        }
    }

    private func writePNG(_ img: NSImage, to url: URL) {
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }

    private func sampleImage() -> NSImage {
        let size = NSSize(width: 1200, height: 800)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(white: 0.97, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedRed: 0.25, green: 0.55, blue: 0.45, alpha: 1).setFill()
        NSRect(x: 0, y: size.height - 110, width: size.width, height: 110).fill()
        img.unlockFocus()
        return img
    }
}
