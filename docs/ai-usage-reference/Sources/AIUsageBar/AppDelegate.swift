import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let refreshInterval: TimeInterval = 60
    private static let launchAgentLabel = "co.emulus.aiusagebar"

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let claudeSource = ClaudeSource()
    private let geminiSource = GeminiSource()

    private var state = UsageState()
    private var timer: Timer?
    private var directoryWatch: DispatchSourceFileSystemObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // One handler for both buttons: a popover has no menu items, so the
        // actions that used to live in the menu move to a right-click menu.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSViewController()

        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        watchUsageCache()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        directoryWatch?.cancel()
    }

    // MARK: - Refresh

    @objc func refreshNow() { refresh() }

    private func refresh() {
        refreshClaude()

        geminiSource.fetch { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self else { return }
                self.state.gemini = Self.merge(new: snapshot, into: self.state.gemini)
                self.rerender()
            }
        }
    }

    private func refreshClaude() {
        let snapshot = claudeSource.read()
        state.claude = Self.merge(new: snapshot, into: state.claude)
        rerender()
    }

    /// Keeps the last good reading visible when a refresh fails, so a transient
    /// error blanks the age rather than the numbers.
    private static func merge(new: Snapshot, into old: Snapshot) -> Snapshot {
        if !new.buckets.isEmpty { return new }
        guard old.hasData else { return new }

        var merged = old
        merged.error = new.error ?? "unavailable"
        return merged
    }

    private func rerender() {
        statusItem.button?.image = GaugeRenderer.statusItemImage(
            used: state.headlineUsed,
            stale: state.headlineIsPartial
        )
        // The image carries the number too, so any leftover title would double it.
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly

        if let used = state.headlineUsed {
            let percentStr = Format.percent(used)
            statusItem.button?.toolTip = "AI Usage: \(percentStr)"
            statusItem.button?.setAccessibilityLabel("AI Usage, \(percentStr)")
        } else {
            statusItem.button?.toolTip = "AI Usage: No Data"
            statusItem.button?.setAccessibilityLabel("AI Usage, No Data")
        }

        // Rebuilt rather than mutated: the panel is cheap, and rebuilding keeps
        // one code path for "render this state" instead of a diffing one.
        if popover.isShown { popover.contentViewController?.view = makePanel() }
    }

    private func makePanel() -> PanelView {
        PanelView(state: state, target: self, refresh: #selector(refreshNow), quit: #selector(quit))
    }

    // MARK: - Presentation

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            button.isHighlighted = false
            return
        }
        refresh()
        popover.contentViewController?.view = makePanel()
        button.isHighlighted = true
        // Activate *before* showing, not after. Without activating at all the
        // popover opens behind the frontmost app and the first click outside it
        // is swallowed dismissing it; doing it afterwards fixes that but leaves
        // the window non-key for the frame it first draws in, which is half of
        // why it opened translucent. Activating first lets it come up key.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: - NSPopoverDelegate

    func popoverWillShow(_ notification: Notification) {
        statusItem.button?.isHighlighted = true
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.isHighlighted = false
    }

    /// Right-click menu: Refresh / Open at Login / Quit, which a popover cannot
    /// host as menu items.
    private func showContextMenu() {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = launchAgentInstalled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Attaching the menu and clicking is the supported way to pop one from a
        // status item without leaving it attached for left clicks.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Instant updates

    /// Watches `~/.aiusage` rather than the files themselves: hooks write
    /// atomically via rename, which would break a watch bound to the old inode.
    private func watchUsageCache() {
        let directory = ClaudeSource.cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(fd) }
        source.resume()
        directoryWatch = source
    }

    // MARK: - Launch at login

    private var launchAgentURL: URL {
        URL(fileURLWithPath: NSString(string: "~/Library/LaunchAgents/\(Self.launchAgentLabel).plist").expandingTildeInPath)
    }

    private var launchAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    @objc func toggleLaunchAtLogin() {
        if launchAgentInstalled {
            launchctl(["bootout", "gui/\(getuid())/\(Self.launchAgentLabel)"])
            try? FileManager.default.removeItem(at: launchAgentURL)
        } else {
            writeLaunchAgent()
            launchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path])
        }
        rerender()
    }

    private func writeLaunchAgent() {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": Self.launchAgentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ) else { return }

        try? FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: launchAgentURL)
    }

    @discardableResult
    private func launchctl(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}
