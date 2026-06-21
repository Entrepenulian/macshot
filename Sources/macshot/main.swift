import AppKit

// macshot — a menu-bar agent that catches new screenshots and lets you file
// them into a Desktop folder from a floating glass panel.
//
// Runs as an .accessory app: no Dock icon, just a menu-bar item + the overlay.

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

if let i = CommandLine.arguments.firstIndex(of: "--render") {
    _ = NSApplication.shared
    let out = (i + 1 < CommandLine.arguments.count) ? CommandLine.arguments[i + 1] : "/tmp/macshot.png"
    MainActor.assumeIsolated { RenderTest.run(out) }
    exit(0)
}

let app = NSApplication.shared
let delegate: NSApplicationDelegate
if CommandLine.arguments.contains("--demo") { delegate = DemoController() }
else if CommandLine.arguments.contains("--latencytest") { delegate = LatencyController() }
else { delegate = AppController() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
