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
        // Above the menu bar / Dock AND above fullscreen app windows (which render
        // above .statusBar in their own Space) — so the corner preview shows over
        // anything: a normal window, a fullscreen app, any Space.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false                 // SwiftUI draws each card's own shadow
        isMovableByWindowBackground = false   // dragging a card drags the file out, not the window
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }     // lets the folder search field accept typing
    override var canBecomeMain: Bool { false }
}

/// The live corner stack's data: the ordered screenshot cards (oldest → newest) and
/// the height of the visible viewport. `StackView` renders it; `OverlayStack` mutates it.
final class StackModel: ObservableObject {
    @Published var cards: [ShotModel] = []
    @Published var scrollTarget: UUID?          // card to scroll into view (newest, or an opened picker)

    let maxVisible = 3                           // at most 3 previews on screen; the rest scroll
    let gap: CGFloat = 12
    var screenCap: CGFloat = 800

    /// Visible viewport height: the newest `maxVisible` cards, or a focused picker.
    var viewportHeight: CGFloat {
        guard !cards.isEmpty else { return 0 }
        if let picker = cards.first(where: { $0.mode == .picker }) {
            return min(picker.currentHeight, screenCap)
        }
        let visible = cards.prefix(maxVisible)        // newest are at the front (top)
        let h = visible.map(\.cardHeight).reduce(0, +) + CGFloat(max(0, visible.count - 1)) * gap
        return min(h, screenCap)
    }
}

/// The scrollable corner stack. Newest sits on top (just like before); older previews
/// stack below and scroll into view. Capped to show `maxVisible` at once — nothing is
/// ever dropped, only scrolled out of sight. No scroll bar; the top/bottom soft-fade only
/// on the side that has hidden content; the whole panel (gaps included) owns the scroll.
struct StackView: View {
    @ObservedObject var model: StackModel
    @State private var atTop = true
    @State private var atBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: model.gap) {
                    ForEach(model.cards) { card in
                        ShotView(model: card)
                            .id(card.id)
                    }
                }
                .frame(width: ShotView.width)
                .padding(.vertical, 1)
                // A near-invisible fill so every pixel of the stack (cards AND the gaps
                // between them) belongs to the panel and scrolls it — never the page behind.
                .background(Color.black.opacity(0.02))
            }
            .frame(width: ShotView.width, height: model.viewportHeight)
            .defaultScrollAnchor(.top)                  // pin to newest (top); older scroll down
            .scrollIndicators(.hidden)                  // no scroll bar, ever
            .scrollDisabled(model.cards.count <= model.maxVisible)   // no scroll until there's overflow
            .mask(edgeFade)                             // soft fade where content is hidden
            .modifier(ScrollEdgeTracker(atTop: $atTop, atBottom: $atBottom))
            .animation(.easeOut(duration: 0.22), value: atTop)
            .animation(.easeOut(duration: 0.22), value: atBottom)
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.34)) {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
        }
    }

    /// Fades only the edges with off-screen content — and ONLY when there are more than
    /// `maxVisible` previews (so 3 or fewer keep crisp edges, no fade at all).
    private var edgeFade: some View {
        let scrollable = model.cards.count > model.maxVisible
        let f = min(0.42, 26 / max(model.viewportHeight, 1))
        let top: CGFloat = (scrollable && !atTop) ? f : 0
        let bot: CGFloat = (scrollable && !atBottom) ? f : 0
        return LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: top),
            .init(color: .black, location: 1 - bot),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

/// Tracks whether the scroll is at the very top / bottom so the edge fade only shows on
/// the side that has hidden content. `onScrollGeometryChange` needs macOS 15+; older
/// systems just skip the directional tracking (the stack still scrolls fine).
private struct ScrollEdgeTracker: ViewModifier {
    @Binding var atTop: Bool
    @Binding var atBottom: Bool
    private struct Edges: Equatable { let top: Bool; let bottom: Bool }

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Edges.self) { geo in
                Edges(top: geo.contentOffset.y <= 0.5,
                      bottom: geo.contentOffset.y >= geo.contentSize.height - geo.containerSize.height - 0.5)
            } action: { _, e in atTop = e.top; atBottom = e.bottom }
        } else {
            content
        }
    }
}

/// Owns one screenshot's lifecycle: builds the model and performs the real
/// copy / move / markup / share / pin actions. The shared `OverlayStack` panel
/// renders the card — this no longer owns a window of its own.
final class OverlayController: NSObject {
    var onClosed: (() -> Void)?      // exit animation finished → stack removes the card + reflows
    var onShown: (() -> Void)?       // card became visible (latency measurement)
    var onModeChange: (() -> Void)?  // picker opened/closed → stack re-sizes + scrolls

    var hostAnchor: () -> NSView? = { nil }   // share sheet anchors to the stack panel
    var makeHostKey: () -> Void = {}          // picker search field needs the panel key

    let fileURL: URL
    let model: ShotModel
    private let store: FolderStore
    private let pins: PinStore
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
        model.onNeedsKey = { [weak self] in self?.makeHostKey() }
        model.onModeChange = { [weak self] in self?.onModeChange?() }
        model.onSave = { [weak self] folder, name in self?.save(folder, name: name) }
        model.onCreate = { [weak self] name in self?.create(name) }
        model.onPin = { [weak self] in self?.pinAndSlideAway() }
    }

    /// The stack calls this once the card is on screen. The card stays put until
    /// the user acts on it (save / copy / pin / dismiss) — it never times out.
    func didPresent() {
        onShown?()
    }

    // MARK: lifecycle — each ends by playing the card's exit animation, then onClosed

    func close() { finish(after: 0.18) { self.model.closing = true } }                 // soft fade

    /// Pin keeps a copy in the pin store (menu-bar gallery), then the preview slides away.
    private func pinAndSlideAway() {
        guard !closed else { return }
        pinnedURL = pins.pin(fileURL)
        model.pinned = (pinnedURL != nil)
        finish(after: 0.34) { self.model.pinning = true }                              // slide off right
    }

    /// Delete outright (move to Trash), then dissolve the card away.
    private func delete() {
        guard !closed else { return }
        do { try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil) }
        catch { NSLog("macsnap: delete failed — \(error.localizedDescription)") }
        finish(after: 0.30) { self.model.deleting = true }                             // blur + shrink + sink
    }

    private func markup() { NSWorkspace.shared.open(fileURL); close() }

    /// Play the card's exit animation in place, then let the stack remove + reflow.
    private func finish(after delay: TimeInterval, _ animate: @escaping () -> Void) {
        guard !closed else { return }
        closed = true
        cancelAutoDismiss()
        animate()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.onClosed?() }
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

    private func share() {
        guard let view = hostAnchor() else { return }
        let picker = NSSharingServicePicker(items: [fileURL])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minX)
    }

    private func save(_ folder: Folder, name: String) {
        do {
            _ = try store.move(fileURL, into: folder.url, baseName: name)
            if !folder.isRoot { store.remember(folder.url) }     // bump to most-recent in the picker list
            store.rememberSave(folder)                           // record for the quick-save pills
            model.showSaved(folder.isRoot ? "Desktop" : folder.name)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in self?.close() }
        } catch {
            NSLog("macsnap: save failed — \(error.localizedDescription)")
            presentFileError()
        }
    }

    private func create(_ name: String) {
        do {
            let url = try store.createFolder(named: name)
            save(Folder(id: url.path, name: name, url: url, count: 0), name: model.baseName)
        } catch {
            NSLog("macsnap: create folder failed — \(error.localizedDescription)")
            presentFileError()
        }
    }

    private func presentFileError() {
        let alert = NSAlert()
        alert.messageText = "Couldn’t file this screenshot"
        alert.informativeText = "MacSnap may need permission to use your Desktop. Grant it in System Settings → Privacy & Security → Files and Folders, then try again. Your screenshot is untouched."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Verification hooks: fire the exact closures the buttons fire.
    func testInvokeDelete() { model.onDelete() }
    func testInvokePin() { model.onPin() }
}

/// Hosts every live screenshot card in ONE scrollable panel anchored in the bottom-right
/// corner. Adding a card slides it in at the bottom; filing / pinning / deleting plays the
/// card's exit and the rest reflow. Only `maxVisible` show at once — older ones scroll.
final class OverlayStack {
    private var controllers: [OverlayController] = []
    private let stackModel = StackModel()
    private var panel: OverlayPanel!
    private var hosting: NSHostingController<StackView>!
    private let margin: CGFloat = 16     // gap from screen edges
    private var spaceObservers: [NSObjectProtocol] = []

    init() { build() }
    deinit { spaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    private func build() {
        hosting = NSHostingController(rootView: StackView(model: stackModel))
        hosting.sizingOptions = []                    // the stack drives the panel frame, not SwiftUI
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: ShotView.width, height: 1))
        panel.contentViewController = hosting
        panel.alphaValue = 0

        // Belt-and-suspenders so the preview ALWAYS rides along to the corner of
        // whatever you switch to. `.canJoinAllSpaces` usually handles this, but
        // re-asserting on every space/app switch makes it bulletproof — it follows
        // to a different window, a different desktop, or a fullscreen app.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            spaceObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reassert()
            })
        }
    }

    /// Re-pin the panel to the active screen's corner and bring it forward, so a
    /// space or app switch can never leave it behind.
    private func reassert() {
        guard !stackModel.cards.isEmpty else { return }
        relayout(animated: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func add(_ c: OverlayController) {
        controllers.append(c)
        c.onClosed = { [weak self, weak c] in if let c { self?.remove(c) } }
        c.onModeChange = { [weak self] in        // picker opened/closed: resize + scroll next runloop
            DispatchQueue.main.async {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)) {
                    self?.stackModel.objectWillChange.send()   // mode changed → recompute height (animated)
                }
                self?.relayout(animated: true); self?.scrollToFocus()
            }
        }
        c.hostAnchor = { [weak self] in self?.panel.contentView }
        c.makeHostKey = { [weak self] in self?.panel.makeKeyAndOrderFront(nil) }

        stackModel.cards.insert(c.model, at: 0)   // newest on top — INSTANT so existing cards never budge
        let firstShow = panel.alphaValue < 0.01
        relayout(animated: false)                 // instant resize; only the new card animates itself in
        panel.orderFrontRegardless()
        if firstShow { panel.alphaValue = 1 }

        // No manual scroll — defaultScrollAnchor(.top) keeps the new (top) card in view, so
        // the preview just appears without a self-scroll jitter. Just mark it shown.
        DispatchQueue.main.async { [weak c] in c?.didPresent() }
    }

    private func remove(_ c: OverlayController) {
        guard controllers.contains(where: { $0 === c }) else { return }
        controllers.removeAll { $0 === c }
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.34)) {
            stackModel.cards.removeAll { $0.id == c.model.id }
        }
        relayout()
        if stackModel.cards.isEmpty {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in self?.panel.orderOut(nil) })
        }
    }

    private func scrollToFocus() {
        if let picker = stackModel.cards.first(where: { $0.mode == .picker }) {
            stackModel.scrollTarget = picker.id
        }
    }

    /// Size the panel to the visible viewport and keep it anchored in the bottom-right corner.
    private func relayout(animated: Bool = true) {
        guard let screen = NSScreen.main, let panel else { return }
        stackModel.screenCap = screen.frame.height - 2 * margin
        let h = max(1, stackModel.viewportHeight)
        let frame = NSRect(x: screen.frame.maxX - ShotView.width - margin,
                           y: screen.frame.minY + margin,
                           width: ShotView.width, height: h)
        if animated && panel.isVisible && panel.alphaValue > 0.01 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.30                                                          // --resize-dur
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)  // --resize-ease
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}
