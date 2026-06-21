import AppKit
import SwiftUI

/// Shows the real native panel(s) on a live screen for verification.
///   macshot --demo           → hover/controls state
///   macshot --demo picker    → folder picker state
///   macshot --demo stack     → three stacked screenshots of different aspect ratios
///   macshot --demo reflow    → two stacked, then the bottom one is dismissed
final class DemoController: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel!
    private var stack: OverlayStack?
    private var controllers: [OverlayController] = []
    private var demoStatusItem: NSStatusItem?
    private var demoPanel: GalleryPanel?
    private let mode: String =
        CommandLine.arguments.contains("quicksave") ? "quicksave" :
        CommandLine.arguments.contains("gallery") ? "gallery" :
        CommandLine.arguments.contains("reflow") ? "reflow" :
        CommandLine.arguments.contains("stack") ? "stack" :
        CommandLine.arguments.contains("picker") ? "picker" : "hover"

    // (w, h, colorIndex) — wide, normal, tall
    private let shots: [(Int, Int, Int)] = [(1600, 500, 0), (1512, 982, 1), (900, 1400, 2)]

    func applicationDidFinishLaunching(_ notification: Notification) {
        if mode == "gallery" { showGallery(); return }
        if mode == "stack" || mode == "reflow" { showStack(reflow: mode == "reflow"); return }

        RenderEnv.forceReveal = true
        let folders: [Folder] = mode == "picker"
            ? [Folder(id: "d", name: "Desktop", url: URL(fileURLWithPath: "/tmp"), count: 0, isRoot: true),
               Folder(id: "a", name: "inspiration for UI", url: URL(fileURLWithPath: "/tmp"), count: 8),
               Folder(id: "b", name: "website info", url: URL(fileURLWithPath: "/tmp"), count: 3)]
            : [Folder(id: "d", name: "Desktop", url: URL(fileURLWithPath: "/tmp"), count: 0, isRoot: true)]

        let recents: [Folder] = mode == "quicksave"
            ? [Folder(id: "r1", name: "Design", url: URL(fileURLWithPath: "/tmp"), count: 0),
               Folder(id: "r2", name: "Receipts", url: URL(fileURLWithPath: "/tmp"), count: 0),
               Folder(id: "r3", name: "website info", url: URL(fileURLWithPath: "/tmp"), count: 0)]
            : []
        let model = ShotModel(image: shotImage(1512, 982, 1), fileName: "Screenshot 2026-06-20",
                              ext: "png", folders: folders, recentFolders: recents)
        if mode == "picker" { model.mode = .picker }
        if mode == "quicksave" { model.mode = .quickSave }

        let hosting = NSHostingController(rootView: ShotView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: ShotView.width, height: 260))
        panel.contentViewController = hosting
        panel.orderFrontRegardless()
        if mode == "picker" { panel.makeKeyAndOrderFront(nil) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let screen = NSScreen.main else { return }
            let v = screen.frame
            let size = self.panel.frame.size
            self.panel.setFrameOrigin(NSPoint(x: v.maxX - size.width - 16, y: v.minY + 16))
            let full = screen.frame
            let topLeftY = full.height - (self.panel.frame.origin.y + size.height)
            let pad: CGFloat = 30
            print("CAPTURE_RECT \(Int(self.panel.frame.origin.x - pad)) \(Int(topLeftY - pad)) \(Int(size.width + pad * 2)) \(Int(size.height + pad * 2))")
            fflush(stdout)
        }
    }

    private func showStack(reflow: Bool) {
        let store = FolderStore()
        let stack = OverlayStack()
        self.stack = stack
        let count = reflow ? 2 : 3
        for i in 0..<count {
            let (w, h, c) = shots[i]
            let url = URL(fileURLWithPath: "/tmp/macshot-demo-\(i).png")
            writePNG(shotImage(w, h, c), to: url)
            let controller = OverlayController(fileURL: url, store: store)
            controllers.append(controller)
            stack.add(controller)
        }
        if reflow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                self?.controllers.first?.close()      // dismiss the bottom (oldest)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { Self.printStackRect() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { Self.printStackRect() }
        }
    }

    private static func printStackRect() {
        guard let screen = NSScreen.main else { return }
        let full = screen.frame
        let w: CGFloat = 440, h = min(900, full.height - 10)
        print("CAPTURE_RECT \(Int(full.width - w)) \(Int(max(0, full.height - h))) \(Int(w)) \(Int(h))")
        fflush(stdout)
    }

    private func showGallery() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("macshot-gallery-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let store = PinStore(root: root)
        for i in 0..<5 {
            let url = root.appendingPathComponent("Pin \(i + 1).png")
            writePNG(shotImage(1200, 800, i), to: url)
            store.pin(url)
        }
        let model = GalleryModel()
        model.pins = store.pins()

        // Real status item + the real flush GalleryPanel — exactly the production path.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "macshot")
        img?.isTemplate = true
        item.button?.image = img
        demoStatusItem = item

        let hosting = NSHostingView(rootView: GalleryView(model: model))
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 10 || size.height < 10 { size = NSSize(width: 300, height: 360) }
        let panel = GalleryPanel(contentSize: size)
        panel.contentView = hosting
        demoPanel = panel

        if let screen = item.button?.window?.screen ?? NSScreen.main {
            let x = screen.frame.maxX - size.width - 8             // mimic the real app's right-side icon
            let y = screen.visibleFrame.maxY - size.height        // top flush under the menu bar
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let f = panel.frame
            let pad: CGFloat = 26
            print("CAPTURE_RECT \(Int(f.origin.x - pad)) 0 \(Int(f.width + pad * 2)) \(Int(NSScreen.main!.frame.height - f.origin.y + pad))")
            fflush(stdout)
        }
    }

    private func writePNG(_ img: NSImage, to url: URL) {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    private func shotImage(_ w: Int, _ h: Int, _ colorIndex: Int) -> NSImage {
        let size = NSSize(width: w, height: h)
        let bars: [NSColor] = [
            NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.85, alpha: 1),
            NSColor(calibratedRed: 0.85, green: 0.35, blue: 0.40, alpha: 1),
            NSColor(calibratedRed: 0.25, green: 0.65, blue: 0.45, alpha: 1),
        ]
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(white: 0.97, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
        let barH = CGFloat(h) * 0.14
        bars[colorIndex % bars.count].setFill()
        NSRect(x: 0, y: CGFloat(h) - barH, width: CGFloat(w), height: barH).fill()
        NSColor(white: 0.86, alpha: 1).setFill()
        let rows = max(3, h / 180)
        for i in 0..<rows {
            NSRect(x: CGFloat(w) * 0.06, y: CGFloat(h) - barH - 40 - CGFloat(i) * 70,
                   width: CGFloat(w) * 0.88, height: 36).fill()
        }
        img.unlockFocus()
        return img
    }
}
