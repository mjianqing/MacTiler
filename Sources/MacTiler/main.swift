import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
if CommandLine.arguments.contains("--smoke-retile") {
    delegate.smokeRetileAndQuit = true
}
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
