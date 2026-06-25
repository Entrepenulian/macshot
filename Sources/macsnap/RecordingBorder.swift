import AppKit

/// A thin, click-through border drawn around the region being recorded, so you
/// can always see exactly what's being captured. It sits *just outside* the
/// recorded rect, so the border itself never ends up in the video.
final class RecordingBorderOverlay {
    private var panel: NSPanel?
    private let lineWidth: CGFloat = 3

    /// Show the border around a region given in global, top-left-origin screen
    /// points (the same space the recorder uses for an area / a window frame).
    func show(globalTopLeft rect: CGRect) {
        hide()
        let appkit = Self.appKitRect(fromGlobalTopLeft: rect)
        // The panel is the region plus a `lineWidth` margin all around; the border
        // is drawn in that margin so the captured region stays clean.
        let frame = appkit.insetBy(dx: -lineWidth, dy: -lineWidth)

        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true            // click-through: never blocks what you're recording
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let v = BorderView(frame: NSRect(origin: .zero, size: frame.size))
        v.lineWidth = lineWidth
        p.contentView = v
        p.orderFrontRegardless()
        panel = p
    }

    func hide() { panel?.orderOut(nil); panel = nil }

    /// Convert a global top-left-origin CG rect to AppKit's bottom-left global space.
    private static func appKitRect(fromGlobalTopLeft cg: CGRect) -> CGRect {
        let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? cg.height
        return CGRect(x: cg.minX, y: primaryH - cg.maxY, width: cg.width, height: cg.height)
    }
}

/// Draws the hollow border in the outer margin (so it hugs the region from just
/// outside). White line with a faint dark halo so it reads on any backdrop.
private final class BorderView: NSView {
    var lineWidth: CGFloat = 3

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // The region sits at inset `lineWidth`; stroke centred at lineWidth/2 fills
        // the [0, lineWidth] margin — entirely outside the captured region.
        let r = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)

        // Faint dark halo just outside the white line for contrast on light scenes.
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setLineWidth(lineWidth + 2)
        ctx.stroke(r)

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.stroke(r)
    }
}
