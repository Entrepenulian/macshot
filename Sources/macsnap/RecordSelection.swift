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

        // Front-to-back windows on this display, skipping our own and tiny chrome.
        let windows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                && $0.frame.width > 40 && $0.frame.height > 40 && $0.isOnScreen
        }

        let panel = SelectionPanel(screen: screen, display: display, windows: windows)
        panel.onFinish = { [weak self] target in self?.finish(target) }
        self.panel = panel
        panel.present()
    }

    private func finish(_ target: RecordTarget?) {
        panel?.dismiss()
        panel = nil
        let done = completion
        completion = nil
        done?(target)
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

    private let accent = NSColor(srgbRed: 1.0, green: 0.416, blue: 0.102, alpha: 1)

    init(screen: NSScreen, display: SCDisplay, windows: [SCWindow]) {
        self.screen = screen
        self.display = display
        self.windows = windows
        super.init(frame: screen.frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

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
            tb.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -46),
        ])
        toolbar = tb
    }

    private func setMode(_ m: RecordSelectionController.Mode) {
        mode = m
        dragRect = nil; dragStart = nil; hoverWindow = nil
        rebuildToolbar()
        needsDisplay = true
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
        guard mode == .window else { return }
        let global = toGlobalTopLeft(convert(event.locationInWindow, from: nil))
        let hit = windows.first { $0.frame.contains(global) }   // front-to-back order
        if hit?.windowID != hoverWindow?.windowID { hoverWindow = hit; needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) }       // Esc
        else { super.keyDown(with: event) }
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Dim the whole screen.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.fill(bounds)

        // The clear "hole" + accent frame for the current selection/highlight.
        var hole: NSRect?
        switch mode {
        case .area:    hole = dragRect
        case .screen:  hole = bounds
        case .window:  hole = hoverWindow.map { toView($0.frame) }
        }

        guard let r = hole, r.width > 1, r.height > 1 else { return }

        ctx.setBlendMode(.clear)
        ctx.fill(r)
        ctx.setBlendMode(.normal)

        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(r.insetBy(dx: 1, dy: 1))

        if mode == .area { drawDimensions(r, ctx: ctx) }
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

    private let accent = Color(red: 1.0, green: 0.416, blue: 0.102)

    var body: some View {
        HStack(spacing: 6) {
            pill("Area", "rectangle.dashed", .area)
            pill("Window", "macwindow", .window)
            pill("Screen", "display", .screen)
            Divider().frame(height: 22).overlay(Color.white.opacity(0.12))
            Button(action: onCancel) {
                Text("Cancel").font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .modifier(GlassBackground())
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .fixedSize()
    }

    @ViewBuilder
    private func pill(_ title: String, _ icon: String, _ m: RecordSelectionController.Mode) -> some View {
        let on = mode == m
        Button { onMode(m) } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(on ? .white : .white.opacity(0.7))
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Capsule().fill(on ? accent.opacity(0.9) : .white.opacity(0.001)))
        }
        .buttonStyle(.plain)
    }
}
