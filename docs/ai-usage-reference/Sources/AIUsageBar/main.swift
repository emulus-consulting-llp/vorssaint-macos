import AppKit

// Text diagnostic path: verify the data without the UI.
if CommandLine.arguments.contains("--dump") {
    Diagnostics.dump()
    exit(0)
}

// Renders the UI to PNGs offscreen, so the artwork can be checked without a
// screenshot. Takes an output directory.
if let index = CommandLine.arguments.firstIndex(of: "--preview") {
    let directory = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : FileManager.default.currentDirectoryPath
    Preview.run(directory: directory)
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// .accessory keeps it out of the Dock and the app switcher: a menu bar app only.
application.setActivationPolicy(.accessory)
application.run()
