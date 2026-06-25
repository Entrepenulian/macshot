import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

final class GalleryModel: ObservableObject {
    @Published var pins: [URL] = []
    @Published var macsnapEnabled = true
    @Published var isRecording = false

    var onCatchLatest: () -> Void = {}
    var onScreenshotSite: () -> Void = {}
    var onRecord: () -> Void = {}
    var onOpenFolder: () -> Void = {}
    var onToggleMacsnap: () -> Void = {}
    var onQuit: () -> Void = {}
    var onUnpin: (URL) -> Void = { _ in }
    var onOpenPin: (URL) -> Void = { _ in }
    var onCopyPin: (URL) -> Void = { _ in }
    var onDropFiles: ([URL]) -> Bool = { _ in false }
    var onDropImages: ([NSImage]) -> Bool = { _ in false }
}

/// The menu-bar dropdown: dark vibrant glass, a scrolling 2-column gallery of pinned
/// screenshots on top, and the settings in a footer at the bottom.
struct GalleryView: View {
    @ObservedObject var model: GalleryModel
    @State private var dropTargeted = false
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private let accent = Color(red: 1.0, green: 0.416, blue: 0.102)   // #FF6A1A

    private var gridHeight: CGFloat {
        let rows = max(1, Int(ceil(Double(model.pins.count) / 2.0)))
        return min(CGFloat(rows) * 143 + 14, 470)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            pinnedArea
            footer
        }
        .frame(width: 322)
        .modifier(GlassBackground())
        // The whole panel accepts the drop — release an image anywhere over macsnap and
        // it pins. Forgiving on purpose: you don't have to land exactly on the grid.
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
    }

    // The pinned section is also a drop target: drag image files from Finder (onto the
    // menu-bar icon, which opens this) and release here to pin them. A dashed accent
    // ring lights up while a valid drag hovers.
    private var pinnedArea: some View {
        Group {
            if model.pins.isEmpty { emptyState } else { grid }
        }
        .overlay(dropHighlight)
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
    }

    @ViewBuilder private var dropHighlight: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .padding(8)
                .transition(.opacity)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers { load(provider) }
        return !providers.isEmpty
    }

    /// Prefer a real file (keeps the original); otherwise pin the raw image data — which
    /// is how images dragged from browsers, Preview, Photos, etc. arrive.
    private func load(_ provider: NSItemProvider) {
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    DispatchQueue.main.async { _ = self.model.onDropFiles([url]) }
                } else {
                    self.loadImageData(provider)   // a remote URL, not a file → use the data
                }
            }
        } else {
            loadImageData(provider)
        }
    }

    private func loadImageData(_ provider: NSItemProvider) {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) ?? false })
        else { return }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async { _ = self.model.onDropImages([image]) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Pinned").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            if !model.pins.isEmpty {
                Text("\(model.pins.count)")
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(.white.opacity(0.13)))
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 11)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(model.pins, id: \.self) { url in
                    PinThumb(url: url,
                             onUnpin: { model.onUnpin(url) },
                             onOpen: { model.onOpenPin(url) },
                             onCopy: { model.onCopyPin(url) })
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .scrollIndicators(.hidden)
        .frame(height: gridHeight)
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            ZStack {
                Circle().fill(accent.opacity(0.15)).frame(width: 56, height: 56)
                Image(systemName: "pin.fill").font(.system(size: 20)).foregroundStyle(accent)
            }
            VStack(spacing: 4) {
                Text("No pins yet").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text("Pin a screenshot to keep it here.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 28).padding(.bottom, 40).padding(.horizontal, 24)
    }

    // MARK: settings footer

    private var footer: some View {
        VStack(spacing: 1) {
            // The setting — same icon column + label edge as the actions below it.
            HStack(spacing: 11) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)).frame(width: 17)
                Text("Use macsnap for screenshots")
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { model.macsnapEnabled }, set: { _ in model.onToggleMacsnap() }))
                    .labelsHidden().toggleStyle(.switch).tint(accent).controlSize(.small)
            }
            .padding(.horizontal, 13).frame(height: 36)

            ActionRow(icon: "macwindow", title: "Screenshot site", action: model.onScreenshotSite)
            ActionRow(icon: model.isRecording ? "stop.circle.fill" : "record.circle",
                      title: model.isRecording ? "Stop recording" : "Record",
                      tint: model.isRecording ? .red : nil,
                      action: model.onRecord)
            ActionRow(icon: "clock.arrow.circlepath", title: "Catch latest screenshot", action: model.onCatchLatest)
            ActionRow(icon: "folder", title: "Open screenshot folder", action: model.onOpenFolder)
            ActionRow(icon: "power", title: "Quit macsnap", action: model.onQuit)
        }
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(0.07)))
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 10)
    }
}

/// One action in the bottom settings list — leading icon, label, full-row hover.
/// Shares the exact icon column + label edge as the toggle row above, so every
/// item lines up structurally (no hand-tuned paddings).
struct ActionRow: View {
    let icon: String
    let title: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(tint ?? .white.opacity(hover ? 0.85 : 0.5)).frame(width: 17)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(tint ?? .white.opacity(hover ? 1 : 0.9))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .padding(.horizontal, 4)
    }
}

/// One pinned screenshot: a square (1:1) thumbnail, draggable into other apps,
/// with an unpin button on hover.
struct PinThumb: View {
    let url: URL
    let onUnpin: () -> Void
    let onOpen: () -> Void
    let onCopy: () -> Void
    @State private var hover = false
    @State private var image: NSImage?

    private var isVideo: Bool { PinStore.isVideo(url) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .aspectRatio(1, contentMode: .fit)                 // 1:1, fills the column
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                    }
                }
                // A recording shows a play badge: greyed at rest, white on hover.
                .overlay {
                    if isVideo {
                        Image(systemName: "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(hover ? 1 : 0.7))
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.32), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(hover ? 0.5 : 0.25)))
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(.white.opacity(hover ? 0.28 : 0.10), lineWidth: 1))   // image outline (pure white)
                .contentShape(Rectangle())
                .onTapGesture { onOpen() }
                .onDrag { fileDragProvider(for: url) }
                // Right-click: copy (the headline action), plus open and unpin for
                // parity with the hover controls.
                .contextMenu {
                    Button { onCopy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button { onOpen() } label: { Label(isVideo ? "Play" : "Open", systemImage: "arrow.up.forward.app") }
                    Divider()
                    Button(role: .destructive) { onUnpin() } label: { Label("Unpin", systemImage: "pin.slash") }
                }

            if hover {
                Button(action: onUnpin) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white).frame(width: 18, height: 18)
                        .background(Circle().fill(.black.opacity(0.7)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.18)))
                }
                .buttonStyle(.plain).padding(6).help("Unpin")
            }
        }
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
        .onAppear(perform: load)
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let img = isVideo ? Self.videoThumbnail(url) : NSImage(contentsOf: url)
            DispatchQueue.main.async { self.image = img }
        }
    }

    /// A poster frame for a video pin (a moment in, to avoid a black first frame).
    private static func videoThumbnail(_ url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 600, height: 600)
        let dur = asset.duration.seconds
        let t = CMTime(seconds: min(0.5, max(0, dur * 0.1)), preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// A drag payload every destination accepts as a real file — Finder, Mail, native apps,
/// browser web drop zones (ChatGPT, Gmail), AND terminal/Electron targets like CMUX's chat
/// input. Three things make it universal:
///
/// 1. We hand over a **copy in an unprotected temp dir**, never the original. A corner shot
///    lives on the TCC-protected Desktop, which a browser or sandboxed destination can't read
///    in place — so an in-place hand-off delivers nothing. The temp copy is readable by
///    anyone. The original is only read, never moved or deleted.
/// 2. A *promised file representation* under the concrete type (e.g. `public.png`) — web
///    upload zones read this into `dataTransfer.files`.
/// 3. A real `public.file-url` to that temp copy — targets that read a *path* off the drag
///    (terminals / Electron, like CMUX) need this; (2) alone gives no path. Crucially this is
///    `public.file-url` (what Finder provides, and browsers accept as a file) — NOT the
///    generic `public.url`, which browsers would misread as a link and ignore.
func fileDragProvider(for url: URL) -> NSItemProvider {
    let src = dragTempCopy(of: url) ?? url
    let provider = NSItemProvider()
    provider.suggestedName = url.lastPathComponent
    let uti = (UTType(filenameExtension: url.pathExtension) ?? .image).identifier
    provider.registerFileRepresentation(forTypeIdentifier: uti, fileOptions: [], visibility: .all) { completion in
        completion(src, true, nil)            // temp copy is unprotected → safe to read in place
        return nil
    }
    provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
        completion(src.dataRepresentation, nil)   // a real public.file-url (path), not public.url
        return nil
    }
    return provider
}

/// Copy `url` into an unprotected temp dir so any destination — browser, terminal, sandboxed
/// app — can read it regardless of where the original lives (e.g. the TCC-protected Desktop).
/// The original is only read, never moved or deleted; copies from past drags are pruned here.
private func dragTempCopy(of url: URL) -> URL? {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("macsnap-drags", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    if let old = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
        let cutoff = Date().addingTimeInterval(-86_400)   // keep a day; prune older
        for f in old where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < cutoff {
            try? fm.removeItem(at: f)
        }
    }
    let dest = dir.appendingPathComponent(url.lastPathComponent)
    try? fm.removeItem(at: dest)
    do { try fm.copyItem(at: url, to: dest); return dest } catch { return nil }
}

/// macOS 26 Liquid Glass behind the popover; falls back to vibrancy on older systems.
/// A slight dark tint keeps the white text readable on a light backdrop.
struct GlassBackground: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(VisualEffect(material: .popover, blending: .behindWindow)).clipShape(shape)
        }
    }
}

/// Native vibrancy behind the popover content (dark "liquid glass").
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = blending
        v.state = .active; v.isEmphasized = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material; v.blendingMode = blending }
}
