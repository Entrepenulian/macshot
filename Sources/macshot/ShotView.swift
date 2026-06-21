import SwiftUI
import AppKit

// Render scaffolding. `solid` swaps glass materials for solid grays so the view can
// be captured offscreen with ImageRenderer. `forceReveal` shows the hover UI without
// a real pointer (used by --render and --demo verification).
enum RenderEnv { static var solid = false; static var forceReveal = false }

// ── monochrome tokens — no accent color, no glow ────────────────────────────
enum Theme {
    static let rImage: CGFloat = 13     // subtle rounding on the screenshot itself
    static let rCard: CGFloat = 18      // the picker panel
    static let ink1 = Color.white.opacity(0.95)
    static let ink2 = Color.white.opacity(0.62)
    static let ink3 = Color.white.opacity(0.42)
    static let ink4 = Color.white.opacity(0.26)
    static let hairline = Color.white.opacity(0.12)
    static let glyph = Color.white.opacity(0.85)            // folder icons, chevrons
    static let rowActive = Color.white.opacity(0.13)
    static let rowActiveLine = Color.white.opacity(0.22)
    static let primaryFill = Color.white.opacity(0.94)      // Save button
    static let primaryInk = Color.black.opacity(0.84)       // text on Save
}

// ── model ───────────────────────────────────────────────────────────────────
final class ShotModel: ObservableObject {
    enum Mode { case revealed, picker, saved }

    let image: NSImage
    @Published var baseName: String
    let ext: String
    let allFolders: [Folder]

    @Published var mode: Mode = .revealed
    @Published var hovering = false
    @Published var copied = false
    @Published var search = ""
    @Published var selection = 0
    @Published var savedLabel = ""
    @Published var pinned = false

    var onCopy: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onMarkup: () -> Void = {}
    var onShare: () -> Void = {}
    var onEngaged: () -> Void = {}
    var onNeedsKey: () -> Void = {}
    var onSave: (Folder, String) -> Void = { _, _ in }
    var onCreate: (String) -> Void = { _ in }

    init(image: NSImage, fileName: String, ext: String, folders: [Folder]) {
        self.image = image
        self.baseName = fileName
        self.ext = ext
        self.allFolders = folders
    }

    var dimsText: String {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return "\(rep.pixelsWide) × \(rep.pixelsHigh)"
        }
        return "\(Int(image.size.width)) × \(Int(image.size.height))"
    }
    var metaText: String { "\(ext.uppercased())  ·  \(dimsText)" }

    var searchTrimmed: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    var filtered: [Folder] {
        let q = searchTrimmed.lowercased()
        return q.isEmpty ? allFolders : allFolders.filter { $0.name.lowercased().contains(q) }
    }
    var canCreate: Bool {
        !searchTrimmed.isEmpty && !allFolders.contains { $0.name.lowercased() == searchTrimmed.lowercased() }
    }
    var rowCount: Int { filtered.count + (canCreate ? 1 : 0) }
    var selectedFolder: Folder? {
        let f = filtered
        return selection < f.count ? f[selection] : nil   // nil = the "Create …" row
    }

    func enterPicker() { mode = .picker; onEngaged() }
    func backToShot() { mode = .revealed; search = ""; selection = 0 }
    func engage() { onEngaged() }
    func moveSelection(_ d: Int) {
        guard rowCount > 0 else { return }
        selection = min(max(selection + d, 0), rowCount - 1)
    }
    func commit() {
        let f = filtered
        if selection < f.count { onSave(f[selection], baseName) }
        else if canCreate { onCreate(searchTrimmed) }
        else if let first = f.first { onSave(first, baseName) }
    }
    func flashCopied() {
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.copied = false }
    }
    func showSaved(_ label: String) { savedLabel = label; mode = .saved }
}

// ── view ────────────────────────────────────────────────────────────────────
struct ShotView: View {
    @ObservedObject var model: ShotModel
    static let width: CGFloat = 384
    private var W: CGFloat { Self.width }

    @State private var appeared = RenderEnv.solid   // pre-revealed when rendering offscreen
    private var revealUI: Bool { RenderEnv.forceReveal || model.hovering }

    // Fixed width; height follows the screenshot's real aspect ratio, capped so a very
    // tall shot doesn't make a giant panel (and a very wide one doesn't get too thin).
    static let minImageH: CGFloat = 120
    static let maxImageH: CGFloat = 300
    private var imageH: CGFloat {
        let s = model.image.size
        guard s.width > 0, s.height > 0 else { return 216 }
        return min(max(W * (s.height / s.width), Self.minImageH), Self.maxImageH)
    }

    // Fit the list to its rows (no big empty area), capped so it can scroll if long.
    private var listHeight: CGFloat { min(CGFloat(max(model.rowCount, 1)) * 40 + 4, 248) }

    private var pathText: String {
        let base = "\(model.baseName).\(model.ext)"
        if let f = model.selectedFolder {
            return f.isRoot ? "~/Desktop/\(base)" : "~/Desktop/\(f.name)/\(base)"
        }
        let name = model.searchTrimmed
        return name.isEmpty ? "~/Desktop/\(base)" : "~/Desktop/\(name)/\(base)"
    }

    var body: some View {
        Group {
            if model.mode == .picker { pickerFace } else { shotFace }
        }
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.12)) { appeared = true } }
        .animation(.spring(response: 0.30, dampingFraction: 0.88), value: model.mode)
        .animation(.easeOut(duration: 0.16), value: model.hovering)
        .onHover { h in model.hovering = h; if h { model.engage() } }
    }

    // MARK: shot face — at rest it's just the raw screenshot; hover reveals the UI

    private var shotFace: some View {
        ZStack {
            Image(nsImage: model.image)
                .resizable().interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: W, height: imageH, alignment: .top)   // crop (if any) hangs off the bottom
                .clipped()
                .blur(radius: revealUI ? 3.5 : 0)
                .overlay(Color.black.opacity(revealUI ? 0.20 : 0))

            if model.mode == .saved { savedOverlay }
            else { controls.opacity(revealUI ? 1 : 0) }
        }
        .frame(width: W, height: imageH)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rImage, style: .continuous))
    }

    private var controls: some View {
        ZStack {
            VStack {
                Text(model.metaText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
            }
            .padding(.top, 12)

            corner(model.pinned ? "pin.fill" : "pin", offset: 0) { model.pinned.toggle(); model.engage() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            corner("xmark", offset: 0) { model.onDismiss() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            corner("pencil", offset: 0) { model.onMarkup() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            corner("square.and.arrow.up", offset: -1) { model.onShare() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            VStack(spacing: 10) {
                pill(model.copied ? "checkmark" : "doc.on.doc",
                     model.copied ? "Copied" : "Copy", primary: false) { model.onCopy() }
                pill("folder", "Save", primary: true) { model.enterPicker() }
            }
        }
        .padding(11)
    }

    private var savedOverlay: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(.white.opacity(0.14)).frame(width: 46, height: 46)
                Image(systemName: "checkmark")
                    .font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.ink1)
            }
            Text("Filed in \(model.savedLabel)")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink1)
        }
    }

    // MARK: picker face

    private var pickerFace: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: model.image)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    TextField("", text: $model.baseName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.ink1)
                    Text(pathText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button(action: { model.backToShot() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.white.opacity(0.07)))
                        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Back")
            }

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.ink3)
                SearchField(text: $model.search,
                            placeholder: "Search folders or type a new name",
                            onUp:     { model.moveSelection(-1) },
                            onDown:   { model.moveSelection(1) },
                            onSubmit: { model.commit() },
                            onCancel: { model.backToShot() })
                    .frame(height: 22)
                Text("esc").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)))
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.30)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.rowActiveLine, lineWidth: 1))

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.filtered.enumerated()), id: \.element.id) { idx, folder in
                        folderRow(folder, active: model.selection == idx)
                            .onHover { if $0 { model.selection = idx } }
                            .onTapGesture { model.onSave(folder, model.baseName) }
                    }
                    if model.canCreate {
                        createRow(name: model.searchTrimmed, active: model.selection == model.filtered.count)
                            .onHover { if $0 { model.selection = model.filtered.count } }
                            .onTapGesture { model.onCreate(model.searchTrimmed) }
                    }
                }
            }
            .frame(height: listHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(14)
        .frame(width: W)
        .background(pickerBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .onAppear { model.onNeedsKey() }
        .onChange(of: model.search) { _, _ in model.selection = 0 }
    }

    @ViewBuilder private var pickerBackground: some View {
        if RenderEnv.solid { Color(white: 0.12) }
        else { ZStack { Rectangle().fill(.ultraThinMaterial); Color.black.opacity(0.22) } }
    }

    private func folderRow(_ folder: Folder, active: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: folder.isRoot ? "desktopcomputer" : "folder.fill").font(.system(size: 15))
                .foregroundStyle(Theme.glyph).frame(width: 26)
            Text(folder.name).font(.system(size: 13.5)).foregroundStyle(Theme.ink1).lineLimit(1)
            Spacer(minLength: 6)
            if active {
                Image(systemName: "return").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink1)
            } else if folder.isRoot {
                Text("default").font(.system(size: 10)).foregroundStyle(Theme.ink4)
            } else {
                Text("\(folder.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink3)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(active ? Theme.rowActive : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(active ? Theme.rowActiveLine : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private func createRow(name: String, active: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "folder.badge.plus").font(.system(size: 15))
                .foregroundStyle(Theme.glyph).frame(width: 26)
            (Text("Create ").foregroundStyle(Theme.ink1)
             + Text("“\(name)”").foregroundStyle(Theme.ink1).fontWeight(.semibold))
                .font(.system(size: 13.5)).lineLimit(1)
            Spacer(minLength: 6)
            Image(systemName: "return").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink1).opacity(active ? 1 : 0.4)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(active ? Theme.rowActive : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(active ? Theme.rowActiveLine : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private func corner(_ symbol: String, offset: CGFloat, action: @escaping () -> Void) -> some View {
        CircleButton(symbol: symbol, iconOffsetY: offset, action: action)
    }
    private func pill(_ symbol: String, _ label: String, primary: Bool, action: @escaping () -> Void) -> some View {
        PillButton(symbol: symbol, label: label, primary: primary, action: action)
    }
}

// ── buttons (monochrome, icons centered in a fixed circle) ──────────────────
struct CircleButton: View {
    let symbol: String
    var iconOffsetY: CGFloat = 0
    let action: () -> Void
    @State private var hover = false
    @State private var press = false

    var body: some View {
        Button(action: action) {
            ZStack {
                background.overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                Image(systemName: symbol)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.ink1)
                    .offset(y: iconOffsetY)          // optical centering nudge per glyph
            }
            .frame(width: 32, height: 32)
            .scaleEffect(press ? 0.94 : (hover ? 1.06 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.24, dampingFraction: 0.7), value: hover)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: press)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in press = true }.onEnded { _ in press = false })
    }

    @ViewBuilder private var background: some View {
        if RenderEnv.solid { Circle().fill(Color(white: 0.17)) }
        else { Circle().fill(.ultraThinMaterial) }
    }
}

struct PillButton: View {
    let symbol: String
    let label: String
    let primary: Bool
    let action: () -> Void
    @State private var hover = false
    @State private var press = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                Text(label).font(.system(size: 14.5, weight: .semibold))
            }
            .foregroundStyle(primary ? Theme.primaryInk : Theme.ink1)
            .frame(minWidth: 132).frame(height: 44)
            .background(background)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(primary ? Color.clear : Theme.hairline, lineWidth: 1))
            .scaleEffect(press ? 0.96 : (hover ? 1.02 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.24, dampingFraction: 0.7), value: hover)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: press)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in press = true }.onEnded { _ in press = false })
    }

    @ViewBuilder private var background: some View {
        if primary {
            Capsule().fill(Theme.primaryFill)
        } else if RenderEnv.solid {
            Capsule().fill(Color(white: 0.17))
        } else {
            Capsule().fill(.ultraThinMaterial)
        }
    }
}

/// AppKit-backed search field so arrow / return / escape reach the folder list
/// instead of being eaten by the field editor.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onUp: () -> Void
    var onDown: () -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13.5)
        field.textColor = NSColor.white.withAlphaComponent(0.95)
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):          parent.onUp();     return true
            case #selector(NSResponder.moveDown(_:)):        parent.onDown();   return true
            case #selector(NSResponder.insertNewline(_:)):   parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}
