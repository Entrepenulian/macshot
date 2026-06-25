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
        let content = MediaViewerWindow.fittedContentSize(for: pixel)

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
        minSize = NSSize(width: 440, height: 320)

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
    static let inset = NSEdgeInsets(top: 38, left: 22, bottom: 26, right: 22)

    /// Window content size: the media fit into a comfortable box plus the glass frame.
    private static func fittedContentSize(for pixel: CGSize) -> CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maxMedia = CGSize(width: screen.width * 0.62, height: screen.height * 0.62)
        let scale = min(maxMedia.width / pixel.width, maxMedia.height / pixel.height, 1)
        let media = CGSize(width: pixel.width * scale, height: pixel.height * scale)
        return CGSize(width: max(440, media.width + inset.left + inset.right),
                      height: max(320, media.height + inset.top + inset.bottom))
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
            .padding(EdgeInsets(top: 38, leading: 22, bottom: 26, trailing: 22))
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
            ActionBar(items: [
                .init("Copy", "doc.on.doc") { copy() },
                .init("Reveal", "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) },
            ])
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
            GlassIconButton(icon: "doc.on.doc", help: "Copy") { copyFile() }
            GlassIconButton(icon: savingGIF ? "hourglass" : "square.stack.3d.down.right",
                            help: "Save GIF") { saveGIF() }
                .disabled(savingGIF)
            GlassIconButton(icon: "folder", help: "Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .padding(5)
        .modifier(ViewerGlass(corner: 15))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(0.16)))
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
/// Liquid-Glass media controls — we only supply the player and the glass frame.
private struct AVKitPlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.videoGravity = .resizeAspect
        v.allowsPictureInPicturePlayback = true
        v.showsFullScreenToggleButton = false
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) { nsView.player = player }
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

/// A small floating action bar (used on images).
private struct ActionBar: View {
    struct Item: Identifiable { let id = UUID(); let title: String; let icon: String; let action: () -> Void
        init(_ t: String, _ i: String, _ a: @escaping () -> Void) { title = t; icon = i; action = a } }
    let items: [Item]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in ActionLabelButton(item: item) }
        }
        .padding(4)
        .modifier(ViewerGlass(corner: 16))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.32), radius: 16, y: 6)
    }
}

private struct ActionLabelButton: View {
    let item: ActionBar.Item
    @State private var hover = false
    var body: some View {
        Button(action: item.action) {
            HStack(spacing: 6) {
                Image(systemName: item.icon).font(.system(size: 12.5, weight: .semibold))
                Text(item.title).font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(hover ? 1 : 0.86))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(.white.opacity(hover ? 0.13 : 0)))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .animation(.easeOut(duration: 0.14), value: hover)
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
