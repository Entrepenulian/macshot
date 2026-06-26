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
    private let barModel = BarModel()   // drives the animated bar-state transitions

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
            barModel.dims = dimsString()   // live readout in the bar while resizing
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
            syncBar(); window?.invalidateCursorRects(for: self)
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
        syncBar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// The X in adjust mode returns to the record-type picker instead of cancelling.
    private func backToPicking() {
        phase = .picking
        selRect = .zero
        dragRect = nil; dragStart = nil; grab = .none
        if mode == .window { startHoverPolling() }
        syncBar()
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
        syncBar()
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
        syncBar()
    }

    // MARK: recording timer

    private func startRecTimer() {
        recTimer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.barModel.elapsed = self.elapsedString()
        }
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
        syncBar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: toolbar

    func installToolbar() {
        syncBar()   // seed the model
        let view = SelectionBarView(
            model: barModel,
            onMode: { [weak self] m in self?.setMode(m) },
            onCancel: { [weak self] in self?.onCancel() },
            onBack: { [weak self] in self?.backToPicking() },
            onStart: { [weak self] in self?.startAreaRecording() },
            onPauseToggle: { [weak self] in self?.togglePause() },
            onStop: { [weak self] in self?.onStop() })
        let tb = NSHostingView(rootView: view)
        tb.translatesAutoresizingMaskIntoConstraints = false
        tb.sizingOptions = [.intrinsicContentSize]
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

    private func dimsString() -> String {
        let scale = screen.backingScaleFactor
        return "\(Int(selRect.width * scale)) × \(Int(selRect.height * scale))"
    }

    /// Push the current state into the bar model; the SwiftUI view animates the
    /// transition between bar states.
    private func syncBar() {
        barModel.phase = {
            switch phase { case .picking: return .picking; case .adjusting: return .adjusting; case .recording: return .recording }
        }()
        barModel.mode = mode
        barModel.paused = paused
        barModel.dims = dimsString()
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


// MARK: - Bar model + view (animated picking / adjusting / recording)

/// Drives the bar. Published changes let the SwiftUI view animate calmly between
/// the three bar states instead of snapping.
final class BarModel: ObservableObject {
    @Published var phase: SelectionBarView.Phase = .picking
    @Published var mode: RecordSelectionController.Mode = .area
    @Published var paused = false
    @Published var elapsed = "0:00"
    @Published var dims = ""
}

struct SelectionBarView: View {
    enum Phase { case picking, adjusting, recording }
    @ObservedObject var model: BarModel
    var onMode: (RecordSelectionController.Mode) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onBack: () -> Void = {}
    var onStart: () -> Void = {}
    var onPauseToggle: () -> Void = {}
    var onStop: () -> Void = {}

    var body: some View {
        ZStack {
            switch model.phase {
            case .picking:   pickingBar.transition(.calmSwap)
            case .adjusting: adjustingBar.transition(.calmSwap)
            case .recording: recordingBar.transition(.calmSwap)
            }
        }
        .padding(7)
        .modifier(ToolbarGlass())
        .shadow(color: .black.opacity(0.4), radius: 26, y: 10)
        .fixedSize()
        // Calm cross-blur swap + smooth capsule resize (transitions-dev: text-swap
        // + card-resize), no bounce.
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.32), value: model.phase)
        .animation(.easeInOut(duration: 0.2), value: model.paused)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 24).padding(.horizontal, 5)
    }

    private var pickingBar: some View {
        HStack(spacing: 3) {
            SelectionPill(title: "Area", icon: "rectangle.dashed", on: model.mode == .area) { onMode(.area) }
            SelectionPill(title: "Window", icon: "macwindow", on: model.mode == .window) { onMode(.window) }
            SelectionPill(title: "Screen", icon: "display", on: model.mode == .screen) { onMode(.screen) }
            divider
            SelectionPill(title: "", icon: "xmark", on: false, action: onCancel)
        }
    }

    private var adjustingBar: some View {
        HStack(spacing: 3) {
            Text(model.dims).font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 8)
            divider
            StartRecordButton(action: onStart)
            // X here goes back to the record-type picker (not cancel).
            SelectionPill(title: "", icon: "xmark", on: false, action: onBack)
        }
    }

    private var recordingBar: some View {
        HStack(spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(model.paused ? Color.white.opacity(0.5) : Color.red).frame(width: 9, height: 9)
                Text(model.elapsed).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            divider
            BarButton(title: model.paused ? "Resume" : "Pause",
                      systemImage: model.paused ? "play.fill" : "pause.fill",
                      style: .neutral, action: onPauseToggle)
            BarButton(title: "Stop", systemImage: "stop.fill", style: .stop, action: onStop)
        }
    }
}

/// A calm cross-blur swap for the bar contents (fade + blur + a hair of scale).
private struct BarSwapModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.opacity(active ? 0 : 1).blur(radius: active ? 4 : 0).scaleEffect(active ? 0.97 : 1)
    }
}
private extension AnyTransition {
    static var calmSwap: AnyTransition {
        .modifier(active: BarSwapModifier(active: true), identity: BarSwapModifier(active: false))
    }
}

/// The premium "Start Recording" button: a glossy red capsule with a soft red
/// glow, a clean white record dot, a lift on hover, and a tactile press.
private struct StartRecordButton: View {
    let action: () -> Void
    @State private var hover = false

    private let top = Color(red: 1.0, green: 0.41, blue: 0.37)
    private let bottom = Color(red: 0.93, green: 0.20, blue: 0.16)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle().fill(.white).frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                Text("Start Recording").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(
                ZStack {
                    Capsule().fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
                    // top gloss
                    Capsule().fill(LinearGradient(colors: [.white.opacity(0.32), .clear],
                                                  startPoint: .top, endPoint: .center))
                        .blendMode(.plusLighter)
                    Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1)
                }
            )
            .brightness(hover ? 0.05 : 0)
            .shadow(color: bottom.opacity(hover ? 0.55 : 0.38), radius: hover ? 14 : 9, y: hover ? 5 : 3)
            .scaleEffect(hover ? 1.025 : 1)
        }
        .buttonStyle(PressScaleStyle())
        .onHover { h in hover = h; if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .animation(.easeOut(duration: 0.16), value: hover)
    }
}

/// A tactile press: scale to 0.96 while held (make-interfaces-feel-better).
private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

/// Neutral glass / red stop bar buttons.
private struct BarButton: View {
    enum Style { case neutral, stop }
    let title: String
    let systemImage: String
    let style: Style
    let action: () -> Void
    @State private var hover = false

    private let red = Color(red: 1.0, green: 0.32, blue: 0.28)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12.5, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(style == .stop ? red : .white.opacity(hover ? 1 : 0.85))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(style == .stop ? red.opacity(hover ? 0.20 : 0.12)
                                                       : .white.opacity(hover ? 0.16 : 0.001)))
            .overlay(Capsule().strokeBorder(style == .stop ? red.opacity(0.35) : .clear))
        }
        .buttonStyle(PressScaleStyle())
        .onHover { h in hover = h; if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .animation(.easeOut(duration: 0.14), value: hover)
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
