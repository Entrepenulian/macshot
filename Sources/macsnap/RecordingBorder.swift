import AppKit

/// While recording a region, the rest of the screen is dimmed and the recorded
/// region stays at full, true colour — the same look as dragging to choose an
/// area, minus any border. It's click-through, and the dim sits *outside* the
/// captured region so it never ends up in the video.
final class RecordingBorderOverlay {
    private var panel: NSPanel?

    /// Show the dim around a region given in global, top-left-origin screen points
    /// (the same space the recorder uses for an area / a window frame).
    func show(globalTopLeft rect: CGRect) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.show(globalTopLeft: rect) }
            return
        }
        hide()
        guard let screen = Self.screen(containing: rect) else { return }

        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true            // click-through: never blocks what you're recording
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // The clear "hole" (the recorded region) in the panel's view coordinates.
        let hole = NSRect(x: rect.minX - screen.frame.minX,
                          y: screen.frame.maxY - rect.maxY,
                          width: rect.width, height: rect.height)
        let v = DimView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.hole = hole
        p.contentView = v
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.hide() }; return }
        panel?.orderOut(nil); panel = nil
    }

    /// The NSScreen the region lives on (its centre), in global top-left CG points.
    private static func screen(containing rect: CGRect) -> NSScreen? {
        let centerCG = CGPoint(x: rect.midX, y: rect.midY)
        for s in NSScreen.screens {
            // CGDisplayBounds is top-left global, matching `rect`.
            if let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               CGDisplayBounds(num).contains(centerCG) {
                return s
            }
        }
        return NSScreen.main
    }
}

/// Dims its whole bounds except a clear hole at the recorded region.
private final class DimView: NSView {
    var hole: NSRect = .zero { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.fill(bounds)
        // Punch the region clear with softly rounded corners (matches the selection).
        ctx.setBlendMode(.clear)
        ctx.addPath(CGPath(roundedRect: hole, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
        ctx.setBlendMode(.normal)
    }
}
