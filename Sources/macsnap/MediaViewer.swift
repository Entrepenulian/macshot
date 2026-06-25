import AppKit
import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

/// What the viewer is showing.
enum ViewerMedia {
    case image(URL)
    case video(URL)

    var url: URL { switch self { case .image(let u), .video(let u): return u } }
    var isVideo: Bool { if case .video = self { return true }; return false }
}

/// Opens the custom media viewer: a Liquid-Glass window with the image or video
/// floating in its true aspect ratio. One window per item; reused if already open
/// for the same file.
final class MediaViewerController {
    static let shared = MediaViewerController()
    private var windows: [MediaViewerWindow] = []

    func open(_ media: ViewerMedia) {
        if let existing = windows.first(where: { $0.mediaURL == media.url }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = MediaViewerWindow(media: media)
        win.onClose = { [weak self, weak win] in self?.windows.removeAll { $0 === win } }
        windows.append(win)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Dev-only delegate behind `--viewer <path>`: opens the viewer on one file so
/// its look can be previewed and iterated without recording.
final class ViewerTestController: NSObject, NSApplicationDelegate {
    private let path: String
    init(path: String) { self.path = path }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let url = URL(fileURLWithPath: path)
        let isVideo = ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
        MediaViewerController.shared.open(isVideo ? .video(url) : .image(url))
        NSApp.activate(ignoringOtherApps: true)

        // `--shot <out>`: grab just the viewer window (clean, glass composited) and quit.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--shot"), i + 1 < args.count {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                guard let win = NSApp.windows.first(where: { $0 is MediaViewerWindow }) else { exit(1) }
                if let btn = win.standardWindowButton(.closeButton) {
                    let h = win.contentView?.bounds.height ?? win.frame.height
                    let f = btn.convert(btn.bounds, to: nil)
                    let lightBottomFromTop = h - f.minY
                    let gap = MediaViewerWindow.inset.top - lightBottomFromTop
                    NSLog("MACSNAP-MEASURE lightBottomFromTop=\(lightBottomFromTop) mediaTop=\(MediaViewerWindow.inset.top) gap=\(gap)")
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l\(win.windowNumber)", out]
                try? p.run(); p.waitUntilExit()
                exit(0)
            }
        }
    }
}

// MARK: - Window

final class MediaViewerWindow: NSWindow, NSWindowDelegate {
    let mediaURL: URL
    var onClose: (() -> Void)?

    init(media: ViewerMedia) {
        self.mediaURL = media.url

        let pixel = MediaViewerWindow.pixelSize(of: media)
        let minMediaW = media.isVideo ? MediaViewerWindow.minVideoMediaWidth : 0
        let content = MediaViewerWindow.fittedContentSize(for: pixel, minMediaWidth: minMediaW)

        super.init(contentRect: NSRect(origin: .zero, size: content),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        delegate = self
        // The controller owns this window in its array, so don't let AppKit also
        // release it on close — that double-release would crash (looks like a quit).
        isReleasedWhenClosed = false
        // Lock the window to the media's framed aspect ratio so it hugs the media
        // and the gaps stay put — the window can't be reshaped to a different ratio.
        contentAspectRatio = content
        // Floor the resize so the inline controls can't be squashed: for video, the
        // window can't go narrower than the controls need (height follows the lock).
        let floorW = media.isVideo ? minMediaW + MediaViewerWindow.inset.left + MediaViewerWindow.inset.right
                                   : max(240, content.width * 0.5)
        minSize = NSSize(width: floorW, height: floorW * content.height / content.width)

        let root = MediaViewerView(media: media)
        contentView = NSHostingView(rootView: root)
        center()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// The media's pixel size (video natural size, or image size).
    private static func pixelSize(of media: ViewerMedia) -> CGSize {
        switch media {
        case .image(let url):
            if let img = NSImage(contentsOf: url), img.size.width > 0 { return img.size }
        case .video(let url):
            let asset = AVURLAsset(url: url)
            if let track = asset.tracks(withMediaType: .video).first {
                let s = track.naturalSize.applying(track.preferredTransform)
                let size = CGSize(width: abs(s.width), height: abs(s.height))
                if size.width > 0 { return size }
            }
        }
        return CGSize(width: 1280, height: 800)
    }

    /// The glass frame around the media. Balanced on all sides; the top carries a
    /// little extra only to clear the traffic lights, kept close to the sides so
    /// the frame reads even.
    static let inset = NSEdgeInsets(top: 33, left: 5, bottom: 5, right: 5)

    /// Window content size = the media (scaled to a comfortable size) plus the
    /// fixed glass frame. The media is only ever *scaled*, never padded out, so
    /// the content always carries the media's exact aspect ratio — which means the
    /// gaps equal the insets for any aspect, wide or tall.
    /// The narrowest the media may be drawn so the inline video controls (skip /
    /// play / scrubber / time / AirPlay / PiP) never get squashed.
    static let minVideoMediaWidth: CGFloat = 460

    private static func fittedContentSize(for pixel: CGSize, minMediaWidth: CGFloat = 0) -> CGSize {
        let w = max(pixel.width, 1), h = max(pixel.height, 1)
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maxMedia = CGSize(width: screen.width * 0.62, height: screen.height * 0.62)

        let fit = min(maxMedia.width / w, maxMedia.height / h)   // scale to fit the box
        var scale = min(fit, 1)
        // Don't open too small: scale a small capture up to a comfortable size, but
        // never past what fits on screen. Scaling keeps the aspect exact.
        let minLong: CGFloat = 560
        let longSide = max(w, h) * scale
        if longSide < minLong { scale = min(fit, minLong / max(w, h)) }
        // Videos: never narrower than the controls need (overrides the fit cap so a
        // tall clip still opens wide enough to show the full transport bar).
        if minMediaWidth > 0, w * scale < minMediaWidth { scale = minMediaWidth / w }

        let media = CGSize(width: w * scale, height: h * scale)
        return CGSize(width: media.width + inset.left + inset.right,
                      height: media.height + inset.top + inset.bottom)
    }
}

// MARK: - The view

struct MediaViewerView: View {
    let media: ViewerMedia
    @State private var appeared = false

    var body: some View {
        ZStack {
            // Grey-tinted Liquid Glass fills the whole window so the frame reads as a
            // soft neutral panel (like the reference) on any backdrop.
            Color.clear.modifier(WindowGlass()).ignoresSafeArea()

            Group {
                switch media {
                case .image(let url): ImagePane(url: url)
                case .video(let url): VideoPane(url: url)
                }
            }
            .padding(EdgeInsets(top: 33, leading: 5, bottom: 5, trailing: 5))
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.985)
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.45), value: appeared)
        }
        .ignoresSafeArea()
        .onAppear { appeared = true }
    }
}

/// The media frame: true aspect ratio, soft rounded corners, a hairline outline,
/// and a grounding shadow so it reads as a real object on the glass.
private struct MediaFrame<Content: View>: View {
    let aspect: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Image

private struct ImagePane: View {
    let url: URL
    @State private var image: NSImage?
    @State private var hovering = false

    private var aspect: CGFloat {
        guard let s = image?.size, s.height > 0 else { return 16.0 / 10.0 }
        return s.width / s.height
    }

    var body: some View {
        MediaFrame(aspect: aspect) {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Rectangle().fill(.white.opacity(0.04))
            }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 2) {
                CopyButton { copy() }
                ActionLabelButton(icon: "folder", title: "Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .padding(4)
            .modifier(GlassPill())
            .shadow(color: .black.opacity(0.32), radius: 16, y: 6)
            .padding(.bottom, 10)
            .opacity(hovering ? 1 : 0)
            .offset(y: hovering ? 0 : 6)
            .animation(.easeOut(duration: 0.18), value: hovering)
        }
        .onHover { hovering = $0 }
        .onAppear { DispatchQueue.global(qos: .userInitiated).async {
            let img = NSImage(contentsOf: url); DispatchQueue.main.async { image = img } } }
    }

    private func copy() {
        let pb = NSPasteboard.general; pb.clearContents()
        if let image { pb.writeObjects([image]) }
        pb.writeObjects([url as NSURL])
    }
}

// MARK: - Video

private struct VideoPane: View {
    let url: URL
    @StateObject private var model: PlayerModel
    @State private var hovering = false
    @State private var savingGIF = false

    init(url: URL) {
        self.url = url
        _model = StateObject(wrappedValue: PlayerModel(url: url))
    }

    var body: some View {
        MediaFrame(aspect: model.aspect) {
            AVKitPlayerView(player: model.player)
        }
        // App actions the native transport doesn't cover, tucked top-right on hover.
        .overlay(alignment: .topTrailing) {
            actions
                .padding(12)
                .opacity(hovering ? 1 : 0)
                .offset(y: hovering ? 0 : -4)
                .animation(.easeOut(duration: 0.18), value: hovering)
        }
        .onHover { hovering = $0 }
        .onAppear { model.play() }
        .onDisappear { model.pause() }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            CopyButton(labeled: false) { copyFile() }
            GlassIconButton(icon: savingGIF ? "hourglass" : "square.stack.3d.down.right",
                            help: "Save GIF") { saveGIF() }
                .disabled(savingGIF)
            GlassIconButton(icon: "folder", help: "Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .padding(5)
        .modifier(GlassPill())
        .shadow(color: .black.opacity(0.32), radius: 16, y: 6)
    }

    private func copyFile() {
        let pb = NSPasteboard.general; pb.clearContents(); pb.writeObjects([url as NSURL])
    }

    private func saveGIF() {
        savingGIF = true
        let dest = url.deletingPathExtension().appendingPathExtension("gif")
        GIFExporter.export(videoURL: url, to: dest) { ok in
            savingGIF = false
            if ok { NSWorkspace.shared.activateFileViewerSelecting([dest]) } else { NSSound.beep() }
        }
    }

}

/// The native AVKit player. Its floating transport IS the system's own
/// Liquid-Glass media controls. The control pill anchors to the bottom of the
/// `AVPlayerView`, so insetting that view's bottom by `controlsLift` raises the
/// pill by the same amount; the video keeps filling via `resizeAspectFill`.
private struct AVKitPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var controlsLift: CGFloat = 14

    func makeNSView(context: Context) -> LiftedPlayerView {
        let v = LiftedPlayerView()
        v.lift = controlsLift
        v.playerView.player = player
        return v
    }
    func updateNSView(_ nsView: LiftedPlayerView, context: Context) {
        nsView.playerView.player = player
        nsView.lift = controlsLift
        nsView.needsLayout = true
    }
}

/// Hosts an `AVPlayerView` inset at the bottom so the floating control pill sits
/// a few points higher than the media's bottom edge.
final class LiftedPlayerView: NSView {
    let playerView = AVPlayerView()
    var lift: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        playerView.controlsStyle = .inline            // the modern integrated Liquid-Glass bar
        playerView.videoGravity = .resizeAspectFill   // fill despite the bottom inset
        playerView.allowsPictureInPicturePlayback = true
        playerView.showsFullScreenToggleButton = false
        addSubview(playerView)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerView.frame = NSRect(x: 0, y: lift, width: bounds.width, height: bounds.height - lift)
    }
}

/// Holds the player, the media aspect (for the glass frame), and a GIF-style loop.
final class PlayerModel: ObservableObject {
    let player: AVPlayer
    @Published var aspect: CGFloat = 16.0 / 9.0

    init(url: URL) {
        player = AVPlayer(url: url)
        if let track = AVURLAsset(url: url).tracks(withMediaType: .video).first {
            let s = track.naturalSize.applying(track.preferredTransform)
            let sz = CGSize(width: abs(s.width), height: abs(s.height))
            if sz.height > 0 { aspect = sz.width / sz.height }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: player.currentItem, queue: .main) { [weak self] _ in
            self?.player.seek(to: .zero); self?.player.play()
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }
}

// MARK: - Shared bits

/// A labelled glass action button (icon + title) with a capsule hover.
private struct ActionLabelButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12.5, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(hover ? 1 : 0.86))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(.white.opacity(hover ? 0.13 : 0)))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .animation(.easeOut(duration: 0.14), value: hover)
    }
}

/// Copy with confirmation: on tap it copies, the icon cross-fades to a checkmark
/// with a scale + blur swap (the transitions-dev icon-swap), and the label flips
/// to "Copied" — reverting after a beat.
private struct CopyButton: View {
    var labeled: Bool = true
    let action: () -> Void
    @State private var copied = false
    @State private var hover = false

    var body: some View {
        Button {
            action()
            withAnimation(.easeInOut(duration: 0.26)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.26)) { copied = false }
            }
        } label: {
            HStack(spacing: 6) {
                iconSlot
                if labeled {
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(hover || copied ? 1 : 0.86))
                        .contentTransition(.opacity)
                        .fixedSize()
                }
            }
            .padding(.horizontal, labeled ? 12 : 0).padding(.vertical, labeled ? 8 : 0)
            .frame(width: labeled ? nil : 28, height: labeled ? nil : 28)
            .background(Capsule().fill(.white.opacity(hover ? 0.13 : 0)))
        }
        .buttonStyle(.plain)
        .disabled(copied)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.14), value: hover)
        .help("Copy")
    }

    /// Two icons sharing one slot, cross-faded with scale (0.25→1) and blur (4→0).
    private var iconSlot: some View {
        ZStack {
            swapIcon("doc.on.doc", shown: !copied)
            swapIcon("checkmark", shown: copied)
        }
        .frame(width: 16, height: 16)
    }

    private func swapIcon(_ name: String, shown: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.25)
            .blur(radius: shown ? 0 : 4)
            .animation(.easeInOut(duration: 0.26), value: copied)
    }
}

/// An icon-only glass button (used on the video, top-right).
private struct GlassIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.88))
                .frame(width: 28, height: 28)
                .background(Capsule().fill(.white.opacity(hover ? 0.14 : 0)))
        }
        .buttonStyle(.plain).help(help)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.14), value: hover)
    }
}

/// Liquid Glass for the viewer surfaces. Real `glassEffect` on macOS 26, vibrancy
/// fallback below it.
struct ViewerGlass: ViewModifier {
    var corner: CGFloat = 0
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// A clear-glass **pill** for floating action bars, so the outer shape and the
/// capsule hover states are the same shape.
struct GlassPill: ViewModifier {
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

/// The window backdrop: the clearest native Liquid Glass, so the frame around
/// the media is true see-through glass rather than a flat panel.
struct WindowGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.clear, in: Rectangle())
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}
