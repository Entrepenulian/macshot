import AppKit
import SwiftUI
import ScreenCaptureKit

/// The pre-recording picker. Dims the main display and lets you choose what to
/// record: drag an **Area**, click a **Window**, or take the whole **Screen**.
/// Returns a `RecordTarget`, or nil if cancelled (Esc / Cancel).
///
/// Coordinates: selection is computed in global, top-left-origin screen points
/// (CG space), which is exactly what `ScreenRecorder` wants for an area.
final class RecordSelectionController {

    enum Mode { case area, window, screen }

    private var panel: SelectionPanel?
    private var completion: ((RecordTarget?) -> Void)?

    func begin(content: SCShareableContent, completion: @escaping (RecordTarget?) -> Void) {
        guard let screen = NSScreen.main,
              let display = content.displays.first(where: { $0.displayID == screen.displayID })
                ?? content.displays.first else { completion(nil); return }
        self.completion = completion

        // Real, front-to-back app windows only. windowLayer == 0 is the normal
        // window layer — this drops the Dock, menu bar, wallpaper and other system
        // surfaces (the Dock in particular spans the whole screen and would "match"
        // every hover, so the highlight looked like it did nothing).
        let windows = content.windows.filter {
            $0.windowLayer == 0
                && $0.isOnScreen
                && $0.frame.width > 60 && $0.frame.height > 60
                && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                && $0.owningApplication?.bundleIdentifier != "com.apple.dock"
        }

        let panel = SelectionPanel(screen: screen, display: display, windows: windows)
        panel.onFinish = { [weak self] target in self?.finish(target) }
        self.panel = panel
        panel.present()
    }

    private func finish(_ target: RecordTarget?) {
        let done = completion
        completion = nil
        if target != nil {
            // Keep the SAME window and just switch it to recording mode — the dim
            // never moves, shifts, or flashes; only the toolbar + border drop away.
            panel?.enterRecordingMode()
        } else {
            panel?.dismiss()
            panel = nil
        }
        done?(target)
    }


    /// Remove the lingering recording-dim window when recording ends.
    func tearDownRecordingOverlay() {
        panel?.dismiss()
        panel = nil
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }
}

// MARK: - Panel

final class SelectionPanel: NSPanel {
    var onFinish: ((RecordTarget?) -> Void)?
    private let canvas: SelectionCanvas

    init(screen: NSScreen, display: SCDisplay, windows: [SCWindow]) {
        canvas = SelectionCanvas(screen: screen, display: display, windows: windows)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = canvas
        canvas.onFinish = { [weak self] in self?.onFinish?($0) }
    }

    override var canBecomeKey: Bool { true }

    func present() {
        setFrame(canvas.screen.frame, display: true)
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.makeFirstResponder(self?.canvas)
            self?.canvas.installToolbar()
        }
    }

    func dismiss() { orderOut(nil) }

    /// Switch this same window into recording mode: it stays up as the dim, but
    /// becomes click-through and drops its toolbar + selection border.
    func enterRecordingMode() {
        ignoresMouseEvents = true
        canvas.enterRecordingMode()
    }
}


// MARK: - Canvas

final class SelectionCanvas: NSView {
    let screen: NSScreen
    private let display: SCDisplay
    private let windows: [SCWindow]
    var onFinish: ((RecordTarget?) -> Void)?

    private var mode: RecordSelectionController.Mode = .area
    private var dragStart: NSPoint?
    private var dragRect: NSRect?            // in view coords, live during a drag
    private var hoverWindow: SCWindow?
    private var toolbar: NSHostingView<SelectionToolbar>?
    private var recording = false           // after release: keep the dim, drop the chrome
    private var hoverTimer: Timer?          // polls the pointer for window-hover highlight

    private let accent = NSColor.white

    init(screen: NSScreen, display: SCDisplay, windows: [SCWindow]) {
        self.screen = screen
        self.display = display
        self.windows = windows
        super.init(frame: screen.frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    // macsnap is a menu-bar (accessory) app, so this overlay panel is often not the
    // key window. Without this, the first mouse-down is swallowed to activate the
    // window instead of starting the drag — so the area selection "just clicked".
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        // Crosshair to drag an area; a pointing hand to click a window or the screen.
        addCursorRect(bounds, cursor: mode == .area ? .crosshair : .pointingHand)
        // The toolbar is for clicking, not aiming — show the normal arrow over it
        // (its buttons switch to the pointing hand on hover).
        if let tb = toolbar, tb.frame.width > 1 { addCursorRect(tb.frame, cursor: .arrow) }
    }

    // MARK: coordinate conversion (view ↔ global top-left CG)

    /// View point (bottom-left) → global top-left CG point.
    private func toGlobalTopLeft(_ p: NSPoint) -> CGPoint {
        CGPoint(x: screen.frame.minX + p.x, y: screen.frame.maxY - p.y)
    }
    /// Global top-left CG rect → view rect (bottom-left).
    private func toView(_ g: CGRect) -> NSRect {
        NSRect(x: g.minX - screen.frame.minX,
               y: screen.frame.maxY - g.maxY,
               width: g.width, height: g.height)
    }

    // MARK: toolbar

    func installToolbar() {
        let tb = NSHostingView(rootView: SelectionToolbar(
            mode: mode,
            onMode: { [weak self] m in self?.setMode(m) },
            onCancel: { [weak self] in self?.onFinish?(nil) }))
        tb.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tb)
        NSLayoutConstraint.activate([
            tb.centerXAnchor.constraint(equalTo: centerXAnchor),
            tb.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -104),   // clear of the Dock
        ])
        toolbar = tb
        // Rebuild cursor rects once the toolbar has a real frame.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.invalidateCursorRects(for: self)
        }
    }

    /// Keep the exact same dim (and the same clear hole) but drop the toolbar and
    /// the selection border — so when the user releases, nothing about the dimmed
    /// layer moves or flashes.
    func enterRecordingMode() {
        recording = true
        stopHoverPolling()
        toolbar?.removeFromSuperview()
        toolbar = nil
        needsDisplay = true
    }

    deinit { hoverTimer?.invalidate() }


    private func setMode(_ m: RecordSelectionController.Mode) {
        mode = m
        dragRect = nil; dragStart = nil; hoverWindow = nil
        // Window hover can't rely on mouseMoved (a borderless, non-key panel often
        // never gets it). Poll the mouse position on a timer instead — bulletproof.
        if m == .window { startHoverPolling() } else { stopHoverPolling() }
        rebuildToolbar()
        window?.invalidateCursorRects(for: self)   // crosshair ↔ pointing hand
        needsDisplay = true
    }

    private func startHoverPolling() {
        stopHoverPolling()
        refreshHoverWindow()
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.refreshHoverWindow() }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }
    private func stopHoverPolling() { hoverTimer?.invalidate(); hoverTimer = nil }

    /// The window under the current mouse location (front-to-back). Reads the live
    /// pointer position directly, so it works without any mouse-moved events.
    private func refreshHoverWindow() {
        let cg = Self.globalMouseTopLeft()
        let hit = windows.first { $0.frame.contains(cg) }
        if hit?.windowID != hoverWindow?.windowID {
            hoverWindow = hit
            needsDisplay = true
        }
    }

    /// The mouse location in global, top-left-origin CG points (matching SCWindow.frame).
    private static func globalMouseTopLeft() -> CGPoint {
        let loc = NSEvent.mouseLocation                  // global, bottom-left origin
        let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? 0
        return CGPoint(x: loc.x, y: primaryH - loc.y)
    }

    private func rebuildToolbar() {
        toolbar?.rootView = SelectionToolbar(
            mode: mode,
            onMode: { [weak self] m in self?.setMode(m) },
            onCancel: { [weak self] in self?.onFinish?(nil) })
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .area:
            dragStart = p; dragRect = NSRect(origin: p, size: .zero)
        case .screen:
            onFinish?(.display(display))
        case .window:
            if let w = hoverWindow { onFinish?(.window(w)) }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, let s = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragRect = NSRect(x: min(s.x, p.x), y: min(s.y, p.y),
                          width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area, let r = dragRect, r.width > 12, r.height > 12 else {
            dragRect = nil; dragStart = nil; needsDisplay = true; return
        }
        // View rect → global top-left CG rect for the recorder.
        let global = CGRect(x: screen.frame.minX + r.minX,
                            y: screen.frame.maxY - r.maxY,
                            width: r.width, height: r.height).integral
        onFinish?(.area(display, global))
    }

    override func mouseMoved(with event: NSEvent) {
        if mode == .window { refreshHoverWindow() }   // backup to the poll timer
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) }       // Esc
        else { super.keyDown(with: event) }
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Screen mode targets the whole display. While choosing, a soft, even dim
        // (no border) says "click to capture the screen"; once recording, it's fully
        // clear so the capture is clean.
        if mode == .screen {
            if !recording {
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.20).cgColor)
                ctx.fill(bounds)
            }
            return
        }

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.fill(bounds)

        let hole: NSRect? = (mode == .area) ? dragRect : hoverWindow.map { toView($0.frame) }
        guard let r = hole, r.width > 1, r.height > 1 else { return }

        // Clear the target with softly rounded corners.
        let radius: CGFloat = 8
        ctx.setBlendMode(.clear)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        ctx.setBlendMode(.normal)

        guard !recording else { return }

        // A thin guide only for the area drag — never a border around a window or
        // the whole screen.
        if mode == .area {
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(2)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 1, dy: 1),
                               cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
            drawDimensions(r, ctx: ctx)
        }
    }

    private func drawDimensions(_ r: NSRect, ctx: CGContext) {
        let scale = screen.backingScaleFactor
        let label = "\(Int(r.width * scale)) × \(Int(r.height * scale))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 7
        let box = NSRect(x: r.midX - size.width / 2 - pad,
                         y: max(r.minY - size.height - 14, 8),
                         width: size.width + pad * 2, height: size.height + pad)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.75).setFill(); path.fill()
        (label as NSString).draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attrs)
    }
}

// MARK: - Toolbar (SwiftUI, liquid glass)

struct SelectionToolbar: View {
    var mode: RecordSelectionController.Mode
    var onMode: (RecordSelectionController.Mode) -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            SelectionPill(title: "Area", icon: "rectangle.dashed", on: mode == .area) { onMode(.area) }
            SelectionPill(title: "Window", icon: "macwindow", on: mode == .window) { onMode(.window) }
            SelectionPill(title: "Screen", icon: "display", on: mode == .screen) { onMode(.screen) }

            Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 26).padding(.horizontal, 5)

            SelectionPill(title: "", icon: "xmark", on: false, action: onCancel)
        }
        .padding(7)
        .modifier(ToolbarGlass())
        .shadow(color: .black.opacity(0.4), radius: 26, y: 10)
        .fixedSize()
    }
}

/// One pill in the selection toolbar. Active = solid white with dark text for a
/// crisp, confident state; inactive lifts on hover.
private struct SelectionPill: View {
    let title: String
    let icon: String?
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    private var iconOnly: Bool { title.isEmpty }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: iconOnly ? 11 : 12.5, weight: .semibold))
                }
                if !iconOnly { Text(title).font(.system(size: 13, weight: .medium)) }
            }
            .foregroundStyle(on ? Color.black : .white.opacity(hover ? 1 : 0.82))
            .padding(.horizontal, iconOnly ? 9 : 14).padding(.vertical, 8)
            .background(Capsule().fill(on ? Color.white : .white.opacity(hover ? 0.16 : 0)))
        }
        .buttonStyle(.plain)
        // Pointing hand over the buttons; the arrow cursor rect covers the gaps.
        .onHover { h in
            hover = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .animation(.easeOut(duration: 0.14), value: hover)
    }
}

/// A defined clear-glass capsule for the floating selection toolbar.
private struct ToolbarGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        }
    }
}
