import AppKit

// Headless self-test (no UI) — used by the test suite to verify shell-config
// generation and escaping. Must run before any NSApplication work.
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

// Diagnostic: print the resolved engine paths (bundled vs ~/bin) and exit. Lets
// the build verify a packaged .app is self-contained.
if CommandLine.arguments.contains("--paths") {
    print("script: \(Paths.script)")
    print("rcloneSetup: \(Paths.rcloneSetup)")
    exit(0)
}

// Menu-bar-only agent (no Dock icon). LSUIElement in Info.plist plus .accessory
// activation policy keep it out of the Dock and app switcher.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
