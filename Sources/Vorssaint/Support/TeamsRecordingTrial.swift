// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import AVFoundation

/// Developer-only entry point; does not initialize the utility's other services.
/// A real meeting capture still needs a manual, reviewable Start decision.
@MainActor
final class TeamsRecordingTrial: NSObject, NSApplicationDelegate, NSWindowDelegate {
    nonisolated static let flag = "--teams-record-trial"
    static let usage = "Usage: VorssaintDeveloper --teams-record-trial /absolute/existing-output-folder"

    static func runAndExit() -> Never {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, arguments[1] == flag, arguments[2].hasPrefix("/") else {
            fputs(usage + "\n", stderr)
            exit(2)
        }
        let parent = URL(fileURLWithPath: arguments[2], isDirectory: true)
        guard (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            fputs("Choose an existing output folder.\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        let trial = TeamsRecordingTrial(parent: parent)
        app.delegate = trial
        withExtendedLifetime(trial) { app.run() }
        exit(0)
    }

    private let parent: URL
    private let scanner = TeamsCallScanner()
    private var policy = TeamsRecordingPolicy()
    private var timer: Timer?
    private var scanning = false
    private var current: TeamsCallScanner.Reading?
    private var recordingID: String?
    private var session: TeamsAudioSession?
    private var starting = false
    private var finishing = false
    private var quitting = false
    private var stopReason = "Stopped by user."
    private var status: NSStatusItem?
    private let stateItem = NSMenuItem(title: "Watching Teams…", action: nil, keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Stop and Save", action: #selector(stopRecording), keyEquivalent: "s")
    private var prompt: NSWindow?
    private var microphone: NSButton?
    private var signalSources: [DispatchSourceSignal] = []

    init(parent: URL) { self.parent = parent }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.status = status
        status.button?.title = "Teams ◯"
        let menu = NSMenu()
        menu.autoenablesItems = false
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        stopItem.target = self
        stopItem.isEnabled = false
        menu.addItem(stopItem)
        let quit = NSMenuItem(title: "Quit Teams Recorder Trial", action: #selector(quitTrial), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        status.menu = menu
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.quitTrial() }
            source.resume()
            signalSources.append(source)
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        print("Teams recording trial armed. Use its menu-bar control to stop or quit. No audio is captured until Start is pressed.")
        scan()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitTrial()
        return .terminateCancel
    }

    private func scan() {
        guard !scanning, !quitting else { return }
        scanning = true
        let pid = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == TeamsAccessibilityMonitor.bundleIdentifier
        }?.processIdentifier
        scanner.scan(pid: pid) { [weak self] reading in
            guard let self else { return }
            self.scanning = false
            guard !self.quitting else { return }
            self.current = reading
            let effects = self.policy.observe(reading.evidence, at: reading.ended)
            if let session = self.session, !self.finishing {
                var scoped = reading
                if reading.evidence != .present(self.recordingID ?? "") {
                    scoped.observation = TeamsCallObservation()
                    scoped.issue = "Recording call is not currently verified."
                }
                session.observe(scoped)
            }
            self.handle(effects)
            if self.session != nil {
                if self.policy.phase != .finishing {
                    if reading.evidence != .present(self.recordingID ?? "") {
                        self.stateItem.title = "Recording — call state unknown; microphone excluded"
                    } else {
                        self.stateItem.title = self.session?.remoteHeard == true
                            ? "Recording — Teams audio heard" : "Recording — Teams audio not verified"
                    }
                }
            } else if self.policy.phase == .offered {
                self.stateItem.title = "Waiting for recording decision"
            } else {
                self.stateItem.title = reading.issue ?? (self.policy.phase == .dismissed ? "Skipped this call" : "Watching Teams…")
            }
        }
    }

    private func handle(_ effects: [TeamsRecordingPolicy.Effect]) {
        for effect in effects {
            switch effect {
            case .offer: showPrompt()
            case .withdrawOffer: closePrompt()
            case .stop:
                stopReason = "Call ended or a different call was detected."
                finishIfReady()
            }
        }
    }

    private func showPrompt() {
        guard prompt == nil, let current else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 310),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Teams Recorder Trial"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let title = NSTextField(wrappingLabelWithString: "Teams call detected: \(current.title)")
        title.font = .boldSystemFont(ofSize: 15)
        let explanation = NSTextField(wrappingLabelWithString:
            "Record Teams audio and save locally to:\n\(parent.path)\n\nThis trial saves audio and caption observations. Transcripts and action items are not available yet. The microphone uses your Mac’s default input; headphones reduce echo.")
        let microphone = NSButton(checkboxWithTitle: "Include microphone with best-effort Teams mute filtering", target: nil, action: nil)
        microphone.state = .off
        self.microphone = microphone
        let caveat = NSTextField(wrappingLabelWithString: "Mute checks can miss brief changes and exclude some speech. Leave microphone off if private room speech must never be saved.")
        caveat.font = .systemFont(ofSize: 11)
        caveat.textColor = .secondaryLabelColor
        let start = NSButton(title: "Start Recording", target: self, action: #selector(startRecording))
        start.bezelStyle = .rounded
        start.keyEquivalent = "\r"
        let skip = NSButton(title: "Skip This Call", target: self, action: #selector(skipCall))
        skip.bezelStyle = .rounded
        let buttons = NSStackView(views: [skip, start])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, explanation, microphone, caveat, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)])
        }
        prompt = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === prompt {
            policy.dismiss()
            prompt = nil
            microphone = nil
        }
    }

    private func closePrompt() {
        prompt?.delegate = nil
        prompt?.close()
        prompt = nil
        microphone = nil
    }

    @objc private func skipCall() { policy.dismiss(); closePrompt() }

    @objc private func startRecording() {
        guard let reading = current, let pid = reading.pid,
              reading.evidence == .present(policy.callID ?? ""),
              policy.accept(at: TeamsCallScanner.now) else {
            stateItem.title = "Call observation unavailable; wait for Teams detection"
            return
        }
        let includesMicrophone = microphone?.state == .on
        recordingID = policy.callID
        closePrompt()
        starting = true
        stopItem.isEnabled = true
        stateItem.title = "Starting recording…"
        status?.button?.title = "Teams ●"
        Task { [self] in
            do {
                if includesMicrophone {
                    let permitted = await AVCaptureDevice.requestAccess(for: .audio)
                    guard permitted else { throw TeamsAudioSession.SessionError.microphone }
                }
                // Permission dialogs can outlive the call or a Stop request.
                guard policy.phase == .starting else {
                    starting = false
                    finishIfReady()
                    return
                }
                guard let current, current.evidence == .present(recordingID ?? ""),
                      TeamsCallScanner.now - current.ended <= 3 else {
                    throw NSError(domain: "TeamsRecordingTrial", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The call is no longer verified. Recording did not start."])
                }
                let session = try await TeamsAudioSession.prepare(parent: parent, title: reading.title,
                    includesMicrophone: includesMicrophone, onFailure: { [weak self] in self?.stopRecording() })
                self.session = session
                guard policy.phase == .starting else {
                    starting = false
                    finishIfReady()
                    return
                }
                guard let latest = self.current, latest.evidence == .present(recordingID ?? ""),
                      TeamsCallScanner.now - latest.ended <= 3 else {
                    throw NSError(domain: "TeamsRecordingTrial", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The call changed during preparation. Recording did not start."])
                }
                try await session.start(pid: pid, includesMicrophone: includesMicrophone)
                starting = false
                policy.didStart()
                if policy.phase == .finishing { finishIfReady() }
            } catch {
                starting = false
                stopReason = error.localizedDescription
                _ = policy.requestStop()
                if session != nil { finishIfReady() }
                else {
                    policy.didFinish()
                    status?.button?.title = "Teams ◯"
                    stopItem.isEnabled = false
                    stateItem.title = "Recording could not start"
                    showResult(message: error.localizedDescription, folder: nil)
                    if quitting { shutDown() }
                }
            }
        }
    }

    @objc private func stopRecording() {
        stopReason = "Stopped by user or capture failure."
        _ = policy.requestStop()
        finishIfReady()
    }

    private func finishIfReady() {
        guard !starting, !finishing, policy.phase == .finishing else { return }
        guard let session else {
            policy.didFinish()
            stopItem.isEnabled = false
            status?.button?.title = "Teams ◯"
            if quitting { shutDown() }
            return
        }
        finishing = true
        stopItem.isEnabled = false
        stateItem.title = "Saving audio…"
        Task { [self] in
            let message = await session.stop(reason: stopReason)
            self.session = nil
            recordingID = nil
            finishing = false
            policy.didFinish()
            status?.button?.title = "Teams ◯"
            if quitting { shutDown() }
            else { showResult(message: message, folder: session.folder) }
        }
    }

    private func showResult(message: String, folder: URL?) {
        let alert = NSAlert()
        alert.messageText = folder == nil ? "Recording could not start" : "Teams audio trial finished"
        alert.informativeText = message + (folder.map { "\n\nSaved folder: \($0.path)" } ?? "")
        alert.addButton(withTitle: "OK")
        if folder != nil { alert.addButton(withTitle: "Show Folder") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, let folder { NSWorkspace.shared.open(folder) }
    }

    @objc private func quitTrial() {
        guard !quitting else { return }
        quitting = true
        timer?.invalidate()
        closePrompt()
        if starting || session != nil {
            stopReason = "Trial quit."
            _ = policy.requestStop()
            finishIfReady()
        } else { shutDown() }
    }

    private func shutDown() {
        scanner.stop { restored in
            if !restored { fputs("Teams accessibility flag restoration could not be verified.\n", stderr) }
            NSApp.stop(nil)
            // Wake the event loop so a command launched from Terminal exits.
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: false) }
        }
    }
}
