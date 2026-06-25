import AppKit
import SwiftUI
import AVFoundation
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

    /// The glass frame around the media. Extra at the top so the traffic lights
    /// sit on the glass, above the media — never over it.
    static let inset = NSEdgeInsets(top: 54, left: 40, bottom: 40, right: 40)

    /// Window content size: the media fit into a comfortable box plus the glass frame.
    private static func fittedContentSize(for pixel: CGSize) -> CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maxMedia = CGSize(width: screen.width * 0.66, height: screen.height * 0.66)
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
            .padding(EdgeInsets(top: 54, leading: 40, bottom: 40, trailing: 40))
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
    @State private var intro = true     // controls greet on open, then auto-hide

    init(url: URL) {
        self.url = url
        _model = StateObject(wrappedValue: PlayerModel(url: url))
    }

    private var controlsVisible: Bool { hovering || !model.isPlaying || intro }

    var body: some View {
        MediaFrame(aspect: model.aspect) {
            PlayerLayerView(player: model.player)
                .background(Color.black)
                .onTapGesture { model.togglePlay() }
        }
        .overlay(alignment: .bottom) {
            controls
                .padding(14)
                .opacity(controlsVisible ? 1 : 0)
                .offset(y: controlsVisible ? 0 : 8)
                .animation(.easeOut(duration: 0.22), value: controlsVisible)
        }
        .onHover { hovering = $0 }
        .onAppear {
            model.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { intro = false }
        }
        .onDisappear { model.pause() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: model.togglePlay) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)

            Text(timecode(model.current)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))

            Scrubber(value: $model.current, total: model.duration) { model.seek(to: $0) }

            Text(timecode(model.duration)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))

            Divider().frame(height: 18).overlay(Color.white.opacity(0.14))

            iconButton("doc.on.doc", "Copy") { copyFile() }
            iconButton(savingGIF ? "hourglass" : "square.stack.3d.down.right", "Save GIF") { saveGIF() }
                .disabled(savingGIF)
            iconButton("folder", "Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .modifier(ViewerGlass(corner: 18))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .frame(maxWidth: 560)
    }

    private func iconButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85)).frame(width: 26, height: 26)
        }
        .buttonStyle(.plain).help(help)
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

    private func timecode(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// A thin liquid-glass scrubber that fills to the playhead and scrubs on drag.
private struct Scrubber: View {
    @Binding var value: Double
    let total: Double
    let onSeek: (Double) -> Void

    private let accent = Color(red: 1.0, green: 0.416, blue: 0.102)

    var body: some View {
        GeometryReader { geo in
            let frac = total > 0 ? min(max(value / total, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18)).frame(height: 4)
                Capsule().fill(accent).frame(width: geo.size.width * frac, height: 4)
                Circle().fill(.white).frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: geo.size.width * frac - 5.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = min(max(g.location.x / geo.size.width, 0), 1)
                onSeek(f * total)
            })
        }
        .frame(height: 16)
    }
}

/// Wraps an AVPlayer in a controls-free layer (so the chrome is entirely ours).
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerNSView { let v = PlayerNSView(); v.playerLayer.player = player; return v }
    func updateNSView(_ nsView: PlayerNSView, context: Context) { nsView.playerLayer.player = player }
}

private final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); playerLayer.frame = bounds }
}

/// Player state for the custom controls: play/pause, position, duration, looping.
final class PlayerModel: ObservableObject {
    let player: AVPlayer
    @Published var isPlaying = false
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var aspect: CGFloat = 16.0 / 9.0

    private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        let item = player.currentItem
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            self.current = t.seconds
            if self.duration == 0, let d = item?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
        }
        if let track = AVURLAsset(url: url).tracks(withMediaType: .video).first {
            let s = track.naturalSize.applying(track.preferredTransform)
            let sz = CGSize(width: abs(s.width), height: abs(s.height))
            if sz.height > 0 { aspect = sz.width / sz.height }
        }
        // Loop the preview, GIF-style.
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: item, queue: .main) { [weak self] _ in
            self?.player.seek(to: .zero); self?.player.play()
        }
    }

    deinit { if let observer { player.removeTimeObserver(observer) } }

    func play() { player.play(); isPlaying = true }
    func pause() { player.pause(); isPlaying = false }
    func togglePlay() { isPlaying ? pause() : play() }
    func seek(to s: Double) {
        player.seek(to: CMTime(seconds: s, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        current = s
    }
}

// MARK: - Shared bits

/// A small floating action bar (used on images).
private struct ActionBar: View {
    struct Item: Identifiable { let id = UUID(); let title: String; let icon: String; let action: () -> Void
        init(_ t: String, _ i: String, _ a: @escaping () -> Void) { title = t; icon = i; action = a } }
    let items: [Item]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                Button(action: item.action) {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon).font(.system(size: 12, weight: .medium))
                        Text(item.title).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .modifier(ViewerGlass(corner: 16))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
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

/// The window backdrop: Liquid Glass tinted toward a neutral grey so the frame
/// around the media is a consistent soft panel rather than near-black.
struct WindowGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(Color(white: 0.46).opacity(0.92)), in: Rectangle())
        } else {
            content.background(Color(white: 0.34)).background(.ultraThinMaterial)
        }
    }
}
