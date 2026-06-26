import AppKit
import SwiftUI
import ScreenCaptureKit

/// The recording picker + controls overlay. Choose what to record (drag an Area,
/// click a Window, or the whole Screen); for an Area you can then resize it with
/// handles before starting. Once recording it shows Pause / Stop with a timer.
final class RecordSelectionController {

    enum Mode { case area, window, screen }

    private var panel: SelectionPanel?

    /// Begin recording the chosen target.
    var onStart: ((RecordTarget) -> Void)?
    /// Toggle pause/resume (the bar's paused state is managed in the overlay).
    var onPauseToggle: (() -> Void)?
    /// Stop and finish recording.
    var onStop: (() -> Void)?
    /// The picker was cancelled before recording started.
    var onCancel: (() -> Void)?

    func begin(content: SCShareableContent) {
        guard let screen = NSScreen.main,
              let display = content.displays.first(where: { $0.displayID == screen.displayID })
                ?? content.displays.first else { onCancel?(); return }

        // Real, front-to-back app windows only. windowLayer == 0 is the normal window
        // layer — drops the Dock, menu bar, wallpaper (the Dock spans the whole screen
        // and would "match" every hover, so the highlight looked like it did nothing).
        let windows = content.windows.filter {
            $0.windowLayer == 0
                && $0.isOnScreen
                && $0.frame.width > 60 && $0.frame.height > 60
                && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                && $0.owningApplication?.bundleIdentifier != "com.apple.dock"
        }

        let panel = SelectionPanel(screen: screen, display: display, windows: windows)
        panel.canvas.onCancel = { [weak self] in self?.dismiss(); self?.onCancel?() }
        panel.canvas.onStart = { [weak self] target in self?.onStart?(target) }
        panel.canvas.onPauseToggle = { [weak self] in self?.onPauseToggle?() }
        panel.canvas.onStop = { [weak self] in self?.onStop?() }
        self.panel = panel
        panel.present()
    }

    /// Remove the overlay (after Stop, or on cancel).
    func dismiss() {
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
    let canvas: SelectionCanvas

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

    enum Phase { case picking, adjusting, recording }
    private(set) var phase: Phase = .picking
    private var mode: RecordSelectionController.Mode = .area

    // Picking
    private var dragStart: NSPoint?
    private var dragRect: NSRect?            // live area drag, view coords
    private var hoverWindow: SCWindow?
    private var hoverTimer: Timer?

    // Confirmed target rect (view coords) for adjusting / recording.
    private var selRect: NSRect = .zero
    private var targetIsScreen = false       // recording the whole display (no dim)

    // Adjust (resize / move)
    private enum Grab: Equatable { case none, move, handle(Int), redraw }
    private var grab: Grab = .none
    private var grabMouse: NSPoint = .zero
    private var grabRect: NSRect = .zero

    // Recording timer
    private var paused = false
    private var recStart = Date()
    private var pausedTotal: TimeInterval = 0
    private var pauseStart: Date?
    private var recTimer: Timer?

    private var toolbar: NSHostingView<SelectionBarView>?

    // Callbacks
    var onCancel: () -> Void = {}
    var onStart: (RecordTarget) -> Void = { _ in }
    var onPauseToggle: () -> Void = {}
    var onStop: () -> Void = {}

    private let handleHitRadius: CGFloat = 14

    init(screen: NSScreen, display: SCDisplay, windows: [SCWindow]) {
        self.screen = screen
        self.display = display
        self.windows = windows
        super.init(frame: screen.frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { hoverTimer?.invalidate(); recTimer?.invalidate() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // During recording, only the controls bar is interactive — clicks elsewhere
    // pass straight through to the app being recorded.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if phase == .recording {
            if let tb = toolbar, let hit, hit.isDescendant(of: tb) { return hit }
            return nil
        }
        return hit
    }

    override func resetCursorRects() {
        switch phase {
        case .picking:
            addCursorRect(bounds, cursor: mode == .area ? .crosshair : .pointingHand)
        case .adjusting:
            addCursorRect(bounds, cursor: .crosshair)
            // Move inside, resize on the edge handles.
            addCursorRect(selRect.insetBy(dx: handleHitRadius, dy: handleHitRadius), cursor: .openHand)
            for (i, p) in handlePoints(selRect).enumerated() {
                let c: NSCursor = (i == 3 || i == 4) ? .resizeLeftRight : (i == 1 || i == 6) ? .resizeUpDown : .crosshair
                addCursorRect(NSRect(x: p.x - handleHitRadius, y: p.y - handleHitRadius,
                                     width: handleHitRadius * 2, height: handleHitRadius * 2), cursor: c)
            }
        case .recording:
            break
        }
        if let tb = toolbar, tb.frame.width > 1 { addCursorRect(tb.frame, cursor: .arrow) }
    }

    // MARK: coordinate conversion

    private func toView(_ g: CGRect) -> NSRect {
        NSRect(x: g.minX - screen.frame.minX, y: screen.frame.maxY - g.maxY, width: g.width, height: g.height)
    }
    /// View rect → global, top-left-origin CG rect (what the recorder wants).
    private func toGlobalRect(_ r: NSRect) -> CGRect {
        CGRect(x: screen.frame.minX + r.minX, y: screen.frame.maxY - r.maxY,
               width: r.width, height: r.height).integral
    }

    // MARK: handles (0=TL 1=TM 2=TR 3=ML 4=MR 5=BL 6=BM 7=BR; view coords, y-up)

    private func handlePoints(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
         NSPoint(x: r.minX, y: r.midY),                                 NSPoint(x: r.maxX, y: r.midY),
         NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY)]
    }

    private func handleAt(_ p: NSPoint) -> Int? {
        for (i, h) in handlePoints(selRect).enumerated() where hypot(p.x - h.x, p.y - h.y) <= handleHitRadius {
            return i
        }
        return nil
    }

    private func resized(_ start: NSRect, handle i: Int, to p: NSPoint) -> NSRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if i == 0 || i == 3 || i == 5 { minX = p.x }      // left
        if i == 2 || i == 4 || i == 7 { maxX = p.x }      // right
        if i == 0 || i == 1 || i == 2 { maxY = p.y }      // top (y-up)
        if i == 5 || i == 6 || i == 7 { minY = p.y }      // bottom
        let x = min(minX, maxX), y = min(minY, maxY)
        return NSRect(x: x, y: y, width: max(40, abs(maxX - minX)), height: max(40, abs(maxY - minY)))
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch phase {
        case .picking:
            switch mode {
            case .area:   dragStart = p; dragRect = NSRect(origin: p, size: .zero)
            case .screen: startRecording(target: .display(display), rect: bounds, isScreen: true)
            case .window: if let w = hoverWindow { startRecording(target: .window(w), rect: toView(w.frame), isScreen: false) }
            }
        case .adjusting:
            if let i = handleAt(p) { grab = .handle(i); grabRect = selRect; grabMouse = p }
            else if selRect.insetBy(dx: 2, dy: 2).contains(p) { grab = .move; grabRect = selRect; grabMouse = p }
            else { grab = .redraw; dragStart = p; dragRect = NSRect(origin: p, size: .zero) }   // re-draw a new area
        case .recording:
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch phase {
        case .picking where mode == .area:
            guard let s = dragStart else { return }
            dragRect = NSRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        case .adjusting:
            switch grab {
            case .handle(let i): selRect = resized(grabRect, handle: i, to: p)
            case .move:
                let dx = p.x - grabMouse.x, dy = p.y - grabMouse.y
                selRect = grabRect.offsetBy(dx: dx, dy: dy)
            case .redraw:
                guard let s = dragStart else { return }
                dragRect = NSRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
            case .none: break
            }
        default: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch phase {
        case .picking where mode == .area:
            if let r = dragRect, r.width > 16, r.height > 16 {
                selRect = r; enterAdjusting()
            } else {
                dragRect = nil; dragStart = nil
            }
        case .adjusting:
            if grab == .redraw, let r = dragRect, r.width > 16, r.height > 16 { selRect = r }
            grab = .none; dragRect = nil; dragStart = nil
            rebuildBar(); window?.invalidateCursorRects(for: self)
        default: break
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        if phase == .picking, mode == .window { refreshHoverWindow() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() }    // Esc cancels (only meaningful before recording)
        else { super.keyDown(with: event) }
    }

    // MARK: phase transitions

    private func enterAdjusting() {
        phase = .adjusting
        stopHoverPolling()
        rebuildBar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// The X in adjust mode returns to the record-type picker instead of cancelling.
    private func backToPicking() {
        phase = .picking
        selRect = .zero
        dragRect = nil; dragStart = nil; grab = .none
        if mode == .window { startHoverPolling() }
        rebuildBar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func startRecording(target: RecordTarget, rect: NSRect, isScreen: Bool) {
        selRect = rect
        targetIsScreen = isScreen
        phase = .recording
        stopHoverPolling()
        recStart = Date(); pausedTotal = 0; pauseStart = nil; paused = false
        startRecTimer()
        rebuildBar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        onStart(target)
    }

    func startAreaRecording() {
        startRecording(target: .area(display, toGlobalRect(selRect)), rect: selRect, isScreen: false)
    }

    private func togglePause() {
        paused.toggle()
        if paused { pauseStart = Date() }
        else if let ps = pauseStart { pausedTotal += Date().timeIntervalSince(ps); pauseStart = nil }
        onPauseToggle()
        rebuildBar()
    }

    // MARK: recording timer

    private func startRecTimer() {
        recTimer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.rebuildBar() }
        RunLoop.main.add(t, forMode: .common)
        recTimer = t
    }

    private func elapsedString() -> String {
        var secs = Date().timeIntervalSince(recStart) - pausedTotal
        if let ps = pauseStart { secs -= Date().timeIntervalSince(ps) }
        let t = max(0, Int(secs))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: window hover

    private func startHoverPolling() {
        stopHoverPolling()
        refreshHoverWindow()
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.refreshHoverWindow() }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }
    private func stopHoverPolling() { hoverTimer?.invalidate(); hoverTimer = nil }

    private func refreshHoverWindow() {
        let cg = Self.globalMouseTopLeft()
        let hit = windows.first { $0.frame.contains(cg) }
        if hit?.windowID != hoverWindow?.windowID { hoverWindow = hit; needsDisplay = true }
    }
    private static func globalMouseTopLeft() -> CGPoint {
        let loc = NSEvent.mouseLocation
        let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? 0
        return CGPoint(x: loc.x, y: primaryH - loc.y)
    }

    // MARK: mode (picking)

    private func setMode(_ m: RecordSelectionController.Mode) {
        mode = m
        dragRect = nil; dragStart = nil; hoverWindow = nil
        if m == .window { startHoverPolling() } else { stopHoverPolling() }
        rebuildBar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: toolbar

    func installToolbar() {
        let tb = NSHostingView(rootView: makeBar())
        tb.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tb)
        NSLayoutConstraint.activate([
            tb.centerXAnchor.constraint(equalTo: centerXAnchor),
            tb.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -104),
        ])
        toolbar = tb
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.invalidateCursorRects(for: self)
        }
    }

    private func rebuildBar() { toolbar?.rootView = makeBar() }

    private func makeBar() -> SelectionBarView {
        let scale = screen.backingScaleFactor
        let dims = "\(Int(selRect.width * scale)) × \(Int(selRect.height * scale))"
        let barPhase: SelectionBarView.Phase = {
            switch phase { case .picking: return .picking; case .adjusting: return .adjusting; case .recording: return .recording }
        }()
        return SelectionBarView(
            phase: barPhase, mode: mode, paused: paused, elapsed: elapsedString(), dims: dims,
            onMode: { [weak self] m in self?.setMode(m) },
            onCancel: { [weak self] in self?.onCancel() },
            onBack: { [weak self] in self?.backToPicking() },
            onStart: { [weak self] in self?.startAreaRecording() },
            onPauseToggle: { [weak self] in self?.togglePause() },
            onStop: { [weak self] in self?.onStop() })
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let radius: CGFloat = 8

        // Screen target: a soft even dim while choosing; clear once recording.
        if phase == .picking && mode == .screen {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.20).cgColor); ctx.fill(bounds)
            return
        }
        if phase == .recording && targetIsScreen { return }

        // Dim everything, then clear the target region.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.fill(bounds)

        let hole: NSRect?
        switch phase {
        case .picking: hole = (mode == .area) ? dragRect : hoverWindow.map { toView($0.frame) }
        case .adjusting: hole = (grab == .redraw) ? (dragRect ?? selRect) : selRect
        case .recording: hole = selRect
        }
        guard let r = hole, r.width > 1, r.height > 1 else { return }

        ctx.setBlendMode(.clear)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        ctx.setBlendMode(.normal)

        if phase == .recording { return }

        if phase == .picking && mode == .area {
            // Thin solid guide while dragging out the initial area.
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(2)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 1, dy: 1), cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
            drawDimensions(r, ctx: ctx)
        } else if phase == .adjusting && grab != .redraw {
            drawDashedFrame(r, ctx: ctx)
            drawHandles(r, ctx: ctx)
            drawDimensions(r, ctx: ctx)
        } else if phase == .adjusting && grab == .redraw {
            // mid re-draw: solid guide
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(2)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 1, dy: 1), cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
        }
    }

    private func drawDashedFrame(_ r: NSRect, ctx: CGContext) {
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.stroke(r)
        ctx.setLineDash(phase: 0, lengths: [])
    }

    private func drawHandles(_ r: NSRect, ctx: CGContext) {
        let blue = NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1).cgColor
        let radius: CGFloat = 6
        for p in handlePoints(r) {
            let dot = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            ctx.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.setFillColor(blue); ctx.fillEllipse(in: dot)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(2)
            ctx.strokeEllipse(in: dot)
        }
    }

    private func drawDimensions(_ r: NSRect, ctx: CGContext) {
        let scale = screen.backingScaleFactor
        let label = "\(Int(r.width * scale)) × \(Int(r.height * scale))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 7
        let box = NSRect(x: r.midX - size.width / 2 - pad, y: max(r.minY - size.height - 16, 8),
                         width: size.width + pad * 2, height: size.height + pad)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (label as NSString).draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attrs)
    }
}


// MARK: - Bar (SwiftUI, liquid glass) — picking / adjusting / recording

struct SelectionBarView: View {
    enum Phase { case picking, adjusting, recording }
    let phase: Phase
    let mode: RecordSelectionController.Mode
    let paused: Bool
    let elapsed: String
    let dims: String
    var onMode: (RecordSelectionController.Mode) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onBack: () -> Void = {}
    var onStart: () -> Void = {}
    var onPauseToggle: () -> Void = {}
    var onStop: () -> Void = {}

    var body: some View {
        content
            .padding(7)
            .modifier(ToolbarGlass())
            .shadow(color: .black.opacity(0.4), radius: 26, y: 10)
            .fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .picking:    pickingBar
        case .adjusting:  adjustingBar
        case .recording:  recordingBar
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 24).padding(.horizontal, 5)
    }

    private var pickingBar: some View {
        HStack(spacing: 3) {
            SelectionPill(title: "Area", icon: "rectangle.dashed", on: mode == .area) { onMode(.area) }
            SelectionPill(title: "Window", icon: "macwindow", on: mode == .window) { onMode(.window) }
            SelectionPill(title: "Screen", icon: "display", on: mode == .screen) { onMode(.screen) }
            divider
            SelectionPill(title: "", icon: "xmark", on: false, action: onCancel)
        }
    }

    private var adjustingBar: some View {
        HStack(spacing: 3) {
            Text(dims).font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 8)
            divider
            BarButton(title: "Start Recording", systemImage: "record.circle.fill",
                      style: .recordStart, action: onStart)
            // X here goes back to the record-type picker (not cancel).
            SelectionPill(title: "", icon: "xmark", on: false, action: onBack)
        }
    }

    private var recordingBar: some View {
        HStack(spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(paused ? Color.white.opacity(0.5) : Color.red).frame(width: 9, height: 9)
                Text(elapsed).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            divider
            BarButton(title: paused ? "Resume" : "Pause",
                      systemImage: paused ? "play.fill" : "pause.fill",
                      style: .neutral, action: onPauseToggle)
            BarButton(title: "Stop", systemImage: "stop.fill", style: .stop, action: onStop)
        }
    }
}

/// A bar action button with three looks: a prominent start, a neutral glass
/// control, and a red stop.
private struct BarButton: View {
    enum Style { case recordStart, neutral, stop }
    let title: String
    let systemImage: String
    let style: Style
    let action: () -> Void
    @State private var hover = false

    private let red = Color(red: 1.0, green: 0.27, blue: 0.23)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12.5, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(bg))
            .overlay(Capsule().strokeBorder(stroke))
        }
        .buttonStyle(.plain)
        .onHover { h in hover = h; if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .animation(.easeOut(duration: 0.14), value: hover)
    }

    private var fg: Color {
        switch style {
        case .recordStart: return .white
        case .neutral:     return .white.opacity(hover ? 1 : 0.85)
        case .stop:        return red
        }
    }
    private var bg: Color {
        switch style {
        case .recordStart: return red.opacity(hover ? 1 : 0.92)
        case .neutral:     return .white.opacity(hover ? 0.16 : 0.001)
        case .stop:        return red.opacity(hover ? 0.18 : 0.10)
        }
    }
    private var stroke: Color {
        switch style {
        case .recordStart: return .white.opacity(0.18)
        case .neutral:     return .clear
        case .stop:        return red.opacity(0.35)
        }
    }
}

/// One pill in the picker (Area/Window/Screen/X). Active = solid white, dark text.
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
                if let icon { Image(systemName: icon).font(.system(size: iconOnly ? 11 : 12.5, weight: .semibold)) }
                if !iconOnly { Text(title).font(.system(size: 13, weight: .medium)) }
            }
            .foregroundStyle(on ? Color.black : .white.opacity(hover ? 1 : 0.82))
            .padding(.horizontal, iconOnly ? 9 : 14).padding(.vertical, 8)
            .background(Capsule().fill(on ? Color.white : .white.opacity(hover ? 0.16 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { h in hover = h; if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .animation(.easeOut(duration: 0.14), value: hover)
    }
}

private struct ToolbarGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        } else {
            content.background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        }
    }
}
