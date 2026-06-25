import AppKit

// macsnap — a menu-bar agent that catches new screenshots and lets you file
// them into a Desktop folder from a floating glass panel.
//
// Runs as an .accessory app: no Dock icon, just a menu-bar item + the overlay.

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

if CommandLine.arguments.contains("--dragtest") {
    // Verify the dragged item carries an image type that other apps will accept.
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("macsnap-drag-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("Screenshot drag.png")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", url.path]
    try? p.run(); p.waitUntilExit()
    let provider = NSItemProvider(contentsOf: url)
    let types = provider?.registeredTypeIdentifiers ?? []
    let droppable = types.contains { $0.contains("png") || $0.contains("image") }

    // The panel must NOT be draggable as a window — so an incomplete drag snaps back.
    _ = NSApplication.shared
    let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100))
    let staysPut = !panel.isMovableByWindowBackground

    print("drag item created:          \(provider != nil)")
    print("registered types:           \(types)")
    print("droppable into image apps:  \(droppable)")
    print("panel stays put (snaps back): \(staysPut)")
    print(droppable && staysPut ? "\nDRAG OK" : "\nDRAG ISSUE")
    try? fm.removeItem(at: dir)
    exit(droppable && staysPut ? 0 : 1)
}

if let i = CommandLine.arguments.firstIndex(of: "--webshottest") {
    let app = NSApplication.shared
    let urlStr = (i + 1 < CommandLine.arguments.count) ? CommandLine.arguments[i + 1] : "https://example.com"
    guard let url = URL(string: urlStr) else { print("bad url"); exit(1) }
    WebShot.capture(url: url, to: URL(fileURLWithPath: "/tmp/webshot.png")) { ok in
        print(ok ? "WEBSHOT OK → /tmp/webshot.png" : "WEBSHOT FAILED")
        exit(ok ? 0 : 1)
    }
    app.run()
}

if CommandLine.arguments.contains("--sitetest") {
    _ = NSApplication.shared
    print("AX trusted: \(WebCapture.axTrusted(prompt: false))")
    if let b = WebCapture.frontmostBrowser() {
        print("browser: \(b.localizedName ?? "?") — \(b.bundleIdentifier ?? "?")")
        if let win = WebCapture.frontmostWindowBounds(of: b) {
            print("window: \(Int(win.minX)),\(Int(win.minY)) size \(Int(win.width))×\(Int(win.height))")
            if let wa = WebCapture.webAreaFrame(of: b) {
                print("MEASURED CHROME INSET: \(Int(wa.minY - win.minY))   (set this as the per-browser inset)")
            }
        }
        if let f = WebCapture.webAreaFrame(of: b) {
            print("web area: \(Int(f.minX)),\(Int(f.minY)) size \(Int(f.width))×\(Int(f.height))")
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))", "/tmp/sitetest.png"]
            try? p.run(); p.waitUntilExit()
            print("captured /tmp/sitetest.png")
        } else { print("no web area found") }
    } else { print("no running browser") }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--render") {
    _ = NSApplication.shared
    let out = (i + 1 < CommandLine.arguments.count) ? CommandLine.arguments[i + 1] : "/tmp/macsnap.png"
    MainActor.assumeIsolated { RenderTest.run(out) }
    exit(0)
}

// Dev: open the custom viewer on a file (image or video) to preview/iterate its look.
if let i = CommandLine.arguments.firstIndex(of: "--viewer") {
    let app = NSApplication.shared
    let path = (i + 1 < CommandLine.arguments.count) ? CommandLine.arguments[i + 1] : ""
    let delegate = ViewerTestController(path: path)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}

let app = NSApplication.shared
let delegate: NSApplicationDelegate
if CommandLine.arguments.contains("--demo") { delegate = DemoController() }
else if CommandLine.arguments.contains("--latencytest") { delegate = LatencyController() }
else if CommandLine.arguments.contains("--deletetest") { delegate = DeleteTestController() }
else if CommandLine.arguments.contains("--pintest") { delegate = PinTestController() }
else { delegate = AppController() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
