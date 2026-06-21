import AppKit
import SwiftUI
import QuartzCore

/// A borderless, non-activating panel that floats over whatever you're doing
/// without stealing focus from the app underneath.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false                 // SwiftUI draws the card's own shadow
        isMovableByWindowBackground = false   // dragging the card drags the file out, not the window
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }     // lets the folder search field accept typing
    override var canBecomeMain: Bool { false }
}

/// Owns one screenshot's lifecycle: builds the model, shows the panel,
/// and performs the real copy / move / markup / share actions.
final class OverlayController: NSObject, NSWindowDelegate {
    var onClosed: (() -> Void)?      // panel finished closing → stack removes + reflows
    var onResized: (() -> Void)?     // panel changed height → stack re-lays-out
    var onShown: (() -> Void)?       // panel first became visible (for latency measurement)

    private let fileURL: URL
    private let store: FolderStore
    private let pins: PinStore
    private let model: ShotModel
    private var panel: OverlayPanel!
    private var hosting: NSHostingController<ShotView>!
    private var autoDismiss: DispatchWorkItem?
    private var closed = false
    private var pinnedURL: URL?      // the copy in the pin store, if pinned

    init(fileURL: URL, store: FolderStore, pins: PinStore = PinStore()) {
        self.fileURL = fileURL
        self.store = store
        self.pins = pins
        let image = NSImage(contentsOf: fileURL) ?? NSImage(size: NSSize(width: 1, height: 1))
        self.model = ShotModel(image: image,
                               fileURL: fileURL,
                               fileName: fileURL.deletingPathExtension().lastPathComponent,
                               ext: fileURL.pathExtension,
                               folders: [store.desktopFolder()] + store.savedFolders(),
                               recentFolders: store.recentFolders())
        super.init()
        wire()
    }

    private func wire() {
        model.onCopy = { [weak self] in self?.copy() }
        model.onDelete = { [weak self] in self?.delete() }
        model.onMarkup = { [weak self] in self?.markup() }
        model.onShare = { [weak self] in self?.share() }
        model.onEngaged = { [weak self] in self?.cancelAutoDismiss() }
        model.onNeedsKey = { [weak self] in self?.panel.makeKeyAndOrderFront(nil) }
        model.onSave = { [weak self] folder, name in self?.save(folder, name: name) }
        model.onCreate = { [weak self] name in self?.create(name) }
        model.onPin = { [weak self] in self?.pinAndSlideAway() }
    }

    /// Pin keeps a copy in the pin store (shown in the menu-bar gallery), then the
    /// preview slides away to the right and the rest of the stack reflows.
    private func pinAndSlideAway() {
        guard !closed else { return }
        pinnedURL = pins.pin(fileURL)
        model.pinned = (pinnedURL != nil)
        closed = true
        cancelAutoDismiss()
        model.pinning = true             // ShotView slides the preview away (transitions-dev, 0.34s)
        let p = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            p?.orderOut(nil)
            self?.onClosed?()
        }
    }

    // MARK: presentation (the OverlayStack positions us in the corner)

    var panelSize: NSSize { panel?.frame.size ?? NSSize(width: ShotView.width, height: 250) }

    func setOrigin(_ origin: NSPoint) {
        guard let panel else { return }
        if panel.alphaValue > 0.01 {
            // animator().setFrame is the animatable path for NSWindow (setFrameOrigin isn't).
            panel.animator().setFrame(NSRect(origin: origin, size: panel.frame.size), display: true)
        } else {
            panel.setFrameOrigin(origin)        // not shown yet → place instantly
        }
    }

    /// Build the panel invisibly. Its SwiftUI size resolves asynchronously, so we
    /// fade it in only once it has a real height and the stack has positioned it.
    func build() {
        hosting = NSHostingController(rootView: ShotView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: ShotView.width, height: 250))
        panel.delegate = self
        panel.alphaValue = 0
        panel.contentViewController = hosting
    }

    func present() {
        panel.orderFrontRegardless()
        scheduleAutoDismiss()
    }

    func windowDidResize(_ notification: Notification) {
        onResized?()
        if let panel, panel.frame.height > 1, panel.alphaValue < 0.01 {
            panel.alphaValue = 1     // snap visible the moment it's sized; SwiftUI does a quick fade
            onShown?()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        cancelAutoDismiss()
        let p = panel
        // 1. Fade this panel fully away (transitions-dev modal-close: ~0.18s, decelerate ease).
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            p?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            p?.orderOut(nil)
            // 2. Only once it's gone, let the others slide down to fill the gap.
            self?.onClosed?()
        })
    }

    private func scheduleAutoDismiss() {
        let work = DispatchWorkItem { [weak self] in self?.close() }
        autoDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }
    private func cancelAutoDismiss() { autoDismiss?.cancel(); autoDismiss = nil }

    // MARK: actions

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        var objects: [NSPasteboardWriting] = [fileURL as NSURL]
        if let img = NSImage(contentsOf: fileURL) { objects.append(img) }
        pb.writeObjects(objects)
        model.flashCopied()
    }

    private func markup() {
        NSWorkspace.shared.open(fileURL)
        close()
    }

    /// Delete the screenshot outright (move it to the Trash) so it isn't kept anywhere.
    private func delete() {
        do { try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil) }
        catch { NSLog("macshot: delete failed — \(error.localizedDescription)") }
        dissolveAndClose()
    }

    /// The card dissolves (blur + shrink + sink + fade), then the rest of the stack reflows.
    private func dissolveAndClose() {
        guard !closed else { return }
        closed = true
        cancelAutoDismiss()
        model.deleting = true            // ShotView animates the dissolve (0.30s)
        let p = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            p?.orderOut(nil)
            self?.onClosed?()
        }
    }

    /// Verification hooks: fire the exact closures the buttons fire.
    func testInvokeDelete() { model.onDelete() }
    func testInvokePin() { model.onPin() }

    private func share() {
        guard let view = panel.contentView else { return }
        let picker = NSSharingServicePicker(items: [fileURL])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private func save(_ folder: Folder, name: String) {
        do {
            _ = try store.move(fileURL, into: folder.url, baseName: name)
            if !folder.isRoot { store.remember(folder.url) }     // bump to most-recent in the picker list
            store.rememberSave(folder)                           // record for the quick-save pills
            model.showSaved(folder.isRoot ? "Desktop" : folder.name)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in self?.close() }
        } catch {
            NSLog("macshot: save failed — \(error.localizedDescription)")
            presentFileError()
        }
    }

    private func presentFileError() {
        let alert = NSAlert()
        alert.messageText = "Couldn’t file this screenshot"
        alert.informativeText = "macshot may need permission to use your Desktop. Grant it in System Settings → Privacy & Security → Files and Folders, then try again. Your screenshot is untouched."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    private func create(_ name: String) {
        do {
            let url = try store.createFolder(named: name)
            save(Folder(id: url.path, name: name, url: url, count: 0), name: model.baseName)
        } catch {
            NSLog("macshot: create folder failed — \(error.localizedDescription)")
            presentFileError()
        }
    }
}

/// Stacks screenshot panels in the bottom-right corner: oldest sits in the corner,
/// each new one appears above the previous with a gap. Panels reflow (slide down)
/// when one is filed or dismissed, and shift up when one grows into the picker.
final class OverlayStack {
    private var controllers: [OverlayController] = []
    private let margin: CGFloat = 16     // gap from screen edges
    private let gap: CGFloat = 12        // gap between stacked panels

    func add(_ c: OverlayController) {
        controllers.append(c)            // newest on top
        c.onClosed  = { [weak self, weak c] in if let c { self?.remove(c) } }
        c.onResized = { [weak self] in self?.layout() }   // fires when its size resolves → positions it
        c.build()
        enforceCap()
        c.present()
    }

    private func remove(_ c: OverlayController) {
        guard controllers.contains(where: { $0 === c }) else { return }
        controllers.removeAll { $0 === c }
        layout()
    }

    /// Keep the stack from marching off the top of the screen.
    private func enforceCap() {
        guard let screen = NSScreen.main else { return }
        let maxCount = max(2, Int((screen.visibleFrame.height - margin) / 262))
        var removed = false
        while controllers.count > maxCount {
            controllers.removeFirst().close()   // file stays on the Desktop; just stops showing
            removed = true
        }
        if removed { layout() }
    }

    private func layout() {
        guard let screen = NSScreen.main else { return }
        let v = screen.frame          // true screen corner (below the Dock), like the native thumbnail
        var y = v.minY + margin
        var placements: [(OverlayController, NSPoint)] = []
        for c in controllers {           // oldest → bottom, newest → top
            let s = c.panelSize
            placements.append((c, NSPoint(x: v.maxX - s.width - margin, y: y)))
            y += s.height + gap
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.30                                                          // transitions-dev --resize-dur
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)  // --resize-ease
            for (c, p) in placements { c.setOrigin(p) }
        }
    }
}
