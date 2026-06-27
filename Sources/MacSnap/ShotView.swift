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
final class ShotModel: ObservableObject, Identifiable {
    enum Mode { case revealed, quickSave, picker, saved }

    let id = UUID()
    let image: NSImage
    let fileURL: URL
    @Published var baseName: String
    let ext: String
    let allFolders: [Folder]
    let recentFolders: [Folder]      // last folders saved into — the quick-save pills

    @Published var mode: Mode = .revealed
    @Published var hovering = false
    @Published var copied = false
    @Published var search = ""
    @Published var selection = 0
    @Published var savedLabel = ""
    @Published var pinned = false
    @Published var deleting = false   // drives the dissolve-out when trashed
    @Published var pinning = false    // drives the slide-away when pinned
    @Published var closing = false    // drives a soft fade-out (auto-dismiss / after save)

    var onModeChange: () -> Void = {} // stack re-lays-out + scrolls when the picker opens/closes
    var onCopy: () -> Void = {}
    var onDelete: () -> Void = {}
    var onMarkup: () -> Void = {}
    var onShare: () -> Void = {}
    var onEngaged: () -> Void = {}
    var onPin: () -> Void = {}
    var onNeedsKey: () -> Void = {}
    var onSave: (Folder, String) -> Void = { _, _ in }
    var onCreate: (String) -> Void = { _ in }

    init(image: NSImage, fileURL: URL = URL(fileURLWithPath: "/dev/null"),
         fileName: String, ext: String, folders: [Folder], recentFolders: [Folder] = []) {
        self.image = image
        self.fileURL = fileURL
        self.baseName = fileName
        self.ext = ext
        self.allFolders = folders
        self.recentFolders = recentFolders
    }

    /// The quick-save pills: up to 4 most-recent folders, falling back to the Desktop
    /// baseline so there's always at least one target. They share the row width equally.
    var quickFolders: [Folder] {
        let r = Array(recentFolders.prefix(4))
        if !r.isEmpty { return r }
        if let root = allFolders.first(where: { $0.isRoot }) { return [root] }
        return Array(allFolders.prefix(1))
    }

    // Live filesystem search results (any Finder folder matching the query), filled
    // asynchronously so typing stays smooth. Empty when the search box is empty.
    @Published var systemMatches: [Folder] = []
    var folderSearch: (String) -> [Folder] = { _ in [] }
    private var searchSeq = 0
    func runSearch() {
        let q = searchTrimmed
        searchSeq += 1
        let seq = searchSeq
        if q.isEmpty { systemMatches = []; onModeChange(); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let r = self.folderSearch(q)
            DispatchQueue.main.async {
                guard seq == self.searchSeq else { return }   // ignore stale (out-of-order) results
                self.systemMatches = r
                self.onModeChange()                            // re-fit the list height
            }
        }
    }

    var dimsText: String {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return "\(rep.pixelsWide) × \(rep.pixelsHigh)"
        }
        return "\(Int(image.size.width)) × \(Int(image.size.height))"
    }
    var metaText: String { "\(ext.uppercased())  ·  \(dimsText)" }

    // Rendered card height — drives the scrollable corner stack's sizing.
    // `displayHeight` (set by the stack) lets the newest few cards shrink just enough to
    // always fit on screen, so the most-recent 3 stay stacked instead of overflowing into
    // a scroll. 0 means "use the natural height".
    @Published var displayHeight: CGFloat = 0
    var naturalCardHeight: CGFloat { ShotView.cardHeight(for: image) }
    var cardHeight: CGFloat { displayHeight > 0 ? displayHeight : naturalCardHeight }
    var pickerHeight: CGFloat { 138 + min(CGFloat(max(rowCount, 1)) * 40 + 4, 248) }
    var currentHeight: CGFloat { mode == .picker ? pickerHeight : cardHeight }

    var searchTrimmed: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    var filtered: [Folder] {
        let q = searchTrimmed.lowercased()
        guard !q.isEmpty else { return allFolders }
        // Folders you already know about (Desktop + ones you've saved into) first, then any
        // other Finder folder the live search turned up (deduped by path).
        let base = allFolders.filter { $0.name.lowercased().contains(q) }
        var seen = Set(base.map { $0.url.path })
        var out = base
        for f in systemMatches where !seen.contains(f.url.path) {
            seen.insert(f.url.path); out.append(f)
        }
        return out
    }
    var canCreate: Bool {
        !searchTrimmed.isEmpty && !filtered.contains { $0.name.lowercased() == searchTrimmed.lowercased() }
    }
    var rowCount: Int { filtered.count + (canCreate ? 1 : 0) }
    var selectedFolder: Folder? {
        let f = filtered
        return selection < f.count ? f[selection] : nil   // nil = the "Create …" row
    }

    func enterQuickSave() { mode = .quickSave; onEngaged(); onModeChange() }
    func enterPicker() { mode = .picker; onEngaged(); onModeChange() }
    func backToShot() { mode = .revealed; search = ""; selection = 0; onModeChange() }
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
    func showSaved(_ label: String) { savedLabel = label; mode = .saved; onModeChange() }
}

// ── view ────────────────────────────────────────────────────────────────────
struct ShotView: View {
    @ObservedObject var model: ShotModel
    static let width: CGFloat = 384
    private var W: CGFloat { Self.width }

    @State private var appeared = RenderEnv.solid   // pre-revealed when rendering offscreen
    private var revealUI: Bool { RenderEnv.forceReveal || model.hovering }
    // Quick-save keeps the UI up even if the pointer drifts off mid-interaction.
    private var showUI: Bool { revealUI || model.mode == .quickSave }

    // Fixed width; height follows the screenshot's real aspect ratio, capped so a very
    // tall shot doesn't make a giant panel (and a very wide one doesn't get too thin).
    static let minImageH: CGFloat = 120
    static let maxImageH: CGFloat = 300
    static func cardHeight(for image: NSImage) -> CGFloat {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return 216 }
        return min(max(width * (s.height / s.width), minImageH), maxImageH)
    }
    private var imageH: CGFloat { model.cardHeight }

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
        // Dissolve: the card loses focus (blur), recedes (scale), sinks, and drains away.
        .scaleEffect(model.deleting ? 0.95 : 1, anchor: .center)
        .blur(radius: model.deleting ? 17 : 0)
        .brightness(model.deleting ? -0.06 : 0)
        // pin → slide off right; a brand-new card eases DOWN into its own slot (a self-contained
        // entrance that never disturbs the cards already on screen).
        .offset(x: model.pinning ? 84 : 0, y: (model.deleting ? 6 : 0) + (appeared ? 0 : -10))
        .opacity((model.deleting || model.pinning || model.closing) ? 0 : (appeared ? 1 : 0))
        .onAppear { withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)) { appeared = true } }
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.34), value: model.mode)   // transitions-dev resize ease
        .animation(.easeOut(duration: 0.16), value: model.hovering)
        .animation(.easeOut(duration: 0.30), value: model.deleting)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.34), value: model.pinning) // transitions-dev slide-away
        .animation(.easeOut(duration: 0.18), value: model.closing)
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
                // No hover blur/darken — the preview stays crisp; only the controls
                // appear over it (they carry their own frosted backgrounds for legibility).

            if model.mode == .saved { savedOverlay }
            else { controls.opacity(showUI ? 1 : 0) }
        }
        .frame(width: W, height: imageH)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rImage, style: .continuous))
        // Drag the shot out as a real file: drop it into any app that takes an image
        // (Mail, Slack, Notes, a text field, Finder…) and that app shows its own drop
        // target. Let go on nothing and it just snaps back — the panel never moves.
        .onDrag({
            model.engage()
            return fileDragProvider(for: model.fileURL)
        }, preview: {
            Image(nsImage: model.image)
                .resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        })
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

            // Corners step aside during quick-save so the focus is the save targets.
            if model.mode != .quickSave {
                ZStack {
                    corner(model.pinned ? "pin.fill" : "pin", offset: 0) { model.onPin() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    corner("trash", offset: 0) { model.onDelete() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    corner("pencil", offset: 0) { model.onMarkup() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    corner("square.and.arrow.up", offset: -1) { model.onShare() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                .transition(.opacity)
            }

            // Save morphs the two pills into the quick-save set (last folders + ✕ / •••).
            Group {
                if model.mode == .quickSave { quickSaveCluster }
                else { defaultPills }
            }
            .transition(.scale(scale: 0.97, anchor: .center).combined(with: .opacity))
        }
        .padding(11)
    }

    private var defaultPills: some View {
        VStack(spacing: 10) {
            pill(model.copied ? "checkmark" : "doc.on.doc",
                 model.copied ? "Copied" : "Copy", primary: false) { model.onCopy() }
            pill("folder", "Save", primary: true) { model.enterQuickSave() }
        }
    }

    private var quickSaveCluster: some View {
        VStack(spacing: 10) {
            // Folder targets sit side by side, sharing the width equally; long names
            // truncate with an ellipsis instead of stretching the pill.
            HStack(spacing: 8) {
                ForEach(model.quickFolders) { folder in
                    pill("folder", folder.isRoot ? "Desktop" : folder.name, primary: false, fill: true) {
                        model.onSave(folder, model.baseName)
                    }
                }
            }
            HStack(spacing: 12) {
                corner("xmark", offset: 0) { model.backToShot() }
                corner("ellipsis", offset: 0) { model.enterPicker() }
            }
            .padding(.top, 3)
        }
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
        .onChange(of: model.search) { _, _ in model.selection = 0; model.runSearch() }
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
    private func pill(_ symbol: String, _ label: String, primary: Bool, fill: Bool = false, action: @escaping () -> Void) -> some View {
        PillButton(symbol: symbol, label: label, primary: primary, fill: fill, action: action)
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
    var fill: Bool = false          // fill an equal share of the row + truncate (quick-save targets)
    let action: () -> Void
    @State private var hover = false
    @State private var press = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: fill ? 5 : 7) {
                Image(systemName: symbol).font(.system(size: fill ? 12.5 : 14, weight: .semibold))
                Text(label).font(.system(size: fill ? 13 : 14.5, weight: .semibold))
                    .lineLimit(1).truncationMode(fill ? .tail : .middle)
            }
            .foregroundStyle(primary ? Theme.primaryInk : Theme.ink1)
            .padding(.horizontal, fill ? 9 : 0)
            .frame(minWidth: fill ? nil : 132, maxWidth: fill ? .infinity : nil)
            .frame(height: 44)
            .fixedSize(horizontal: !fill, vertical: false)
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
