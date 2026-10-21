// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import AVFoundation
import Combine

/// Shared by the native app and the small developer trial entry point.
/// Capture starts only after the user accepts the detected call's prompt.
@MainActor
final class TeamsRecorderService: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = TeamsRecorderService()
    static let enabledKey = "teamsRecorderEnabled"
    static let folderKey = "teamsRecorderFolder"
    static let lastFolderKey = "teamsRecorderLastFolder"
    private let parentOverride: URL?
    var parent: URL {
        if let parentOverride { return parentOverride }
        let path = UserDefaults.standard.string(forKey: Self.folderKey) ?? ""
        if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vorssaint Meetings", isDirectory: true)
    }
    @Published private(set) var isMonitoring = false
    @Published private(set) var stateText = "Meeting detection is off" {
        didSet { stateItem.title = stateText }
    }
    @Published private(set) var lastFolder: URL?
    @Published private(set) var isTranscribing = false
    @Published private(set) var lastResult = ""
    private var shutdownCallbacks: [() -> Void] = []
    var canStop: Bool { starting || (session != nil && !finishing) }
    var isBusy: Bool { starting || finishing || session != nil || isTranscribing || quitting }
    var needsTerminationHandling: Bool { isMonitoring || isBusy }

    private let scanner = TeamsCallScanner()
    private var policy = TeamsRecordingPolicy()
    private var timer: Timer?
    private var scanning = false
    private var current: TeamsCallScanner.Reading?
    private var recordingID: String?
    @Published private var session: TeamsAudioSession?
    @Published private var starting = false
    @Published private var finishing = false
    @Published private var quitting = false
    var onStopDetection: (() -> Void)?
    private var stopReason = "Stopped by user."
    private var status: NSStatusItem?
    private let stateItem = NSMenuItem(title: "Watching Teams…", action: nil, keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Stop and Save", action: #selector(stopRecording), keyEquivalent: "s")
    private var prompt: NSWindow?
    private var microphone: NSButton?
    private var transcription: NSButton?
    private var transcriptionConfiguration: TeamsTranscriptionService.Configuration?
    private var transcriptionCancellation: BoundedProcessCancellation?

    init(parent: URL? = nil) {
        parentOverride = parent
        if let path = UserDefaults.standard.string(forKey: Self.lastFolderKey), !path.isEmpty {
            lastFolder = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    func syncWithPreferences() {
        if AppFeature.screenRecorder.isAvailable && UserDefaults.standard.bool(forKey: Self.enabledKey) {
            startMonitoring()
        } else if isMonitoring || isBusy { shutdown() }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func startMonitoring() {
        guard !isMonitoring, !quitting, !isBusy else { return }
        isMonitoring = true
        policy = TeamsRecordingPolicy()
        stateText = "Watching Teams…"
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.status = status
        status.button?.title = "Teams ◯"
        status.button?.toolTip = "Vorssaint · Teams Meeting Recorder"
        let menu = NSMenu()
        menu.autoenablesItems = false
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        stopItem.target = self
        stopItem.isEnabled = false
        menu.addItem(stopItem)
        let show = NSMenuItem(title: "Show Last Meeting", action: #selector(showLastFolder), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let stopDetection = NSMenuItem(title: "Stop Meeting Detection", action: #selector(stopDetectionFromMenu), keyEquivalent: "")
        stopDetection.target = self
        menu.addItem(stopDetection)
        status.menu = menu
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        scan()
    }

    private func scan() {
        guard isMonitoring, !scanning, !quitting, !finishing else { return }
        scanning = true
        let pid = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == TeamsAccessibilityMonitor.bundleIdentifier
        }?.processIdentifier
        scanner.scan(pid: pid) { [weak self] reading in
            guard let self else { return }
            self.scanning = false
            guard self.isMonitoring, !self.quitting, !self.finishing else { return }
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
                        self.stateText = "Recording — call state unknown; microphone excluded"
                    } else {
                        self.stateText = self.session?.remoteHeard == true
                            ? "Recording — Teams audio heard" : "Recording — Teams audio not verified"
                    }
                }
            } else if self.policy.phase == .offered {
                self.stateText = "Waiting for recording decision"
            } else {
                self.stateText = reading.issue ?? (self.policy.phase == .dismissed ? "Skipped this call" : "Watching Teams…")
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Vorssaint · Teams Meeting"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let title = NSTextField(wrappingLabelWithString: "Teams call detected: \(current.title)")
        title.font = .boldSystemFont(ofSize: 15)
        let explanation = NSTextField(wrappingLabelWithString:
            "Record Teams audio and save locally to:\n\(parent.path)\n\nSaves audio and readable Teams captions. Optional speech transcription stays on this Mac. Turn on live captions in Teams to capture them. The microphone uses your Mac’s default input; headphones reduce echo.")
        let microphone = NSButton(checkboxWithTitle: "Include microphone with best-effort Teams mute filtering", target: nil, action: nil)
        microphone.state = .off
        self.microphone = microphone
        let available = TeamsTranscriptionService.Configuration.installed != nil
        let transcription = NSButton(checkboxWithTitle: available ? "Transcribe locally after saving audio" : "Local speech model unavailable — Teams captions will still be saved", target: nil, action: nil)
        transcription.state = available ? .on : .off
        transcription.isEnabled = available
        self.transcription = transcription
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
        let stack = NSStackView(views: [title, explanation, microphone, caveat, transcription, buttons])
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
            transcription = nil
        }
    }

    private func closePrompt() {
        prompt?.delegate = nil
        prompt?.close()
        prompt = nil
        microphone = nil
        transcription = nil
    }

    @objc private func skipCall() { policy.dismiss(); closePrompt() }

    @objc private func startRecording() {
        guard let reading = current, let pid = reading.pid,
              reading.evidence == .present(policy.callID ?? ""),
              policy.accept(at: TeamsCallScanner.now) else {
            stateText = "Call observation unavailable; wait for Teams detection"
            return
        }
        let includesMicrophone = microphone?.state == .on
        transcriptionConfiguration = transcription?.state == .on ? TeamsTranscriptionService.Configuration.installed : nil
        recordingID = policy.callID
        closePrompt()
        starting = true
        stopItem.isEnabled = true
        stateText = "Starting recording…"
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
                    throw NSError(domain: "TeamsRecorder", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The call is no longer verified. Recording did not start."])
                }
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let session = try await TeamsAudioSession.prepare(parent: parent, title: reading.title,
                    includesMicrophone: includesMicrophone, onFailure: { [weak self] in self?.captureFailed() })
                self.session = session
                guard policy.phase == .starting else {
                    starting = false
                    finishIfReady()
                    return
                }
                guard let latest = self.current, latest.evidence == .present(recordingID ?? ""),
                      TeamsCallScanner.now - latest.ended <= 3 else {
                    throw NSError(domain: "TeamsRecorder", code: 1,
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
                    stateText = "Recording could not start"
                    if quitting { lastResult = error.localizedDescription; shutDown() }
                    else { showResult(message: error.localizedDescription, folder: nil) }
                }
            }
        }
    }

    private func captureFailed() {
        stopReason = "Audio capture failed."
        _ = policy.requestStop()
        finishIfReady()
    }

    @objc func stopRecording() {
        stopReason = "Stopped by user."
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
        stateText = "Saving audio…"
        Task { [self] in
            var message = await session.stop(reason: stopReason)
            remember(session.folder)
            self.session = nil
            recordingID = nil
            if !quitting, let configuration = transcriptionConfiguration {
                message += "\n\n" + (await transcribe(folder: session.folder, configuration: configuration))
            }
            transcriptionConfiguration = nil
            finishing = false
            policy.didFinish()
            status?.button?.title = "Teams ◯"
            if quitting { shutDown() }
            else { showResult(message: message, folder: session.folder) }
        }
    }

    private func showResult(message: String, folder: URL?) {
        let alert = NSAlert()
        lastResult = message
        stateText = folder == nil ? "Recording could not start" : "Meeting saved"
        alert.messageText = folder == nil ? "Recording could not start" : "Meeting saved"
        alert.informativeText = message + (folder.map { "\n\nSaved folder: \($0.path)" } ?? "")
        alert.addButton(withTitle: "OK")
        if folder != nil { alert.addButton(withTitle: "Show Folder") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, let folder { NSWorkspace.shared.open(folder) }
    }

    @objc func showLastFolder() {
        if let lastFolder { NSWorkspace.shared.open(lastFolder) }
    }

    @objc private func stopDetectionFromMenu() {
        if let onStopDetection { onStopDetection(); return }
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        shutdown()
    }

    private func remember(_ folder: URL) {
        lastFolder = folder
        if parentOverride == nil { UserDefaults.standard.set(folder.path, forKey: Self.lastFolderKey) }
    }

    func cancelTranscription() { transcriptionCancellation?.cancel() }

    func processSavedMeeting(_ folder: URL, transcribeAudio: Bool) {
        guard !isBusy else { return }
        policy.dismiss()
        closePrompt()
        finishing = true
        stateText = "Exporting Teams captions…"
        Task { [self] in
            var message: String
            do {
                let count = try await Task.detached { try TeamsCaptions.export(folder: folder) }.value
                message = "Saved captions.md (\(count) caption rows)."
                remember(folder)
            } catch { message = "Could not export captions; the original files were preserved." }
            if transcribeAudio, !quitting {
                if let configuration = TeamsTranscriptionService.Configuration.installed {
                    message += "\n\n" + (await transcribe(folder: folder, configuration: configuration))
                } else { message += "\n\nLocal speech transcription is unavailable. Install whisper.cpp and its speech model first." }
            }
            finishing = false
            if quitting { shutDown() }
            else { showResult(message: message, folder: folder) }
        }
    }

    private func transcribe(folder: URL, configuration: TeamsTranscriptionService.Configuration) async -> String {
        let cancellation = BoundedProcessCancellation()
        transcriptionCancellation = cancellation
        isTranscribing = true
        stateText = "Transcribing locally…"
        defer { transcriptionCancellation = nil; isTranscribing = false }
        do {
            let result = try await Task.detached { [weak self] in
                try await TeamsTranscriptionService.transcribe(folder: folder,
                    configuration: configuration, cancellation: cancellation, progress: { [weak self] progress in
                        Task { @MainActor [weak self] in self?.stateText = progress }
                    })
            }.value
            return "Saved transcript.md locally (\(result.turns) turns). Review recognition and speaker labels."
        } catch {
            return (error as? TeamsTranscriptionService.Failure)?.localizedDescription
                ?? "Local transcription could not finish. Saved audio and captions are available for retry."
        }
    }

    func shutdown(completion: (() -> Void)? = nil) {
        if let completion { shutdownCallbacks.append(completion) }
        guard !quitting else { return }
        quitting = true
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        closePrompt()
        transcriptionCancellation?.cancel()
        if finishing { return } // The owning task finalizes before restoration.
        if starting || session != nil {
            stopReason = "Meeting recorder stopped."
            _ = policy.requestStop()
            finishIfReady()
        } else { shutDown() }
    }

    private func shutDown() {
        scanner.stop { [weak self] restored in
            guard let self else { return }
            if let status = self.status { NSStatusBar.system.removeStatusItem(status) }
            self.status = nil
            self.quitting = false
            self.scanning = false
            self.current = nil
            self.policy = TeamsRecordingPolicy()
            self.stateText = restored ? "Meeting detection is off" : "Stopped; Teams accessibility restoration could not be verified"
            let callbacks = self.shutdownCallbacks
            self.shutdownCallbacks.removeAll()
            callbacks.forEach { $0() }
        }
    }
}
