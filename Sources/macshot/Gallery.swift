import SwiftUI
import AppKit

final class GalleryModel: ObservableObject {
    @Published var pins: [URL] = []
    @Published var macshotEnabled = true

    var onCatchLatest: () -> Void = {}
    var onOpenFolder: () -> Void = {}
    var onToggleMacshot: () -> Void = {}
    var onQuit: () -> Void = {}
    var onUnpin: (URL) -> Void = { _ in }
    var onOpenPin: (URL) -> Void = { _ in }
}

/// The menu-bar dropdown: dark vibrant glass, a scrolling 2-column gallery of pinned
/// screenshots on top, and the settings in a footer at the bottom.
struct GalleryView: View {
    @ObservedObject var model: GalleryModel
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private let accent = Color(red: 1.0, green: 0.416, blue: 0.102)   // #FF6A1A

    private var gridHeight: CGFloat {
        let rows = max(1, Int(ceil(Double(model.pins.count) / 2.0)))
        return min(CGFloat(rows) * 143 + 14, 470)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.pins.isEmpty { emptyState } else { grid }
            footer
        }
        .frame(width: 322)
        .modifier(GlassBackground())
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
                    PinThumb(url: url, onUnpin: { model.onUnpin(url) }, onOpen: { model.onOpenPin(url) })
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
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
                Text("Use macshot for screenshots")
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { model.macshotEnabled }, set: { _ in model.onToggleMacshot() }))
                    .labelsHidden().toggleStyle(.switch).tint(accent).controlSize(.small)
            }
            .padding(.horizontal, 13).frame(height: 36)

            ActionRow(icon: "clock.arrow.circlepath", title: "Catch latest screenshot", action: model.onCatchLatest)
            ActionRow(icon: "folder", title: "Open screenshot folder", action: model.onOpenFolder)
            ActionRow(icon: "power", title: "Quit macshot", action: model.onQuit)
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
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(hover ? 0.85 : 0.5)).frame(width: 17)
                Text(title)
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(hover ? 1 : 0.9))
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
    @State private var hover = false
    @State private var image: NSImage?

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
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(.white.opacity(hover ? 0.28 : 0.10), lineWidth: 1))   // image outline (pure white)
                .contentShape(Rectangle())
                .onTapGesture { onOpen() }
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }

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
            let img = NSImage(contentsOf: url)
            DispatchQueue.main.async { self.image = img }
        }
    }
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
