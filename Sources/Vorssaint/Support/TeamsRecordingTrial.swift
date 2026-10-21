// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Standalone developer harness for the same service used by Settings.
@MainActor
final class TeamsRecordingTrial: NSObject, NSApplicationDelegate {
    nonisolated static let flag = "--teams-record-trial"
    private let recorder: TeamsRecorderService
    private var signals: [DispatchSourceSignal] = []
    init(parent: URL) { recorder = TeamsRecorderService(parent: parent) }

    static func runAndExit() -> Never {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, arguments[1] == flag, arguments[2].hasPrefix("/"),
              (try? URL(fileURLWithPath: arguments[2]).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            fputs("Usage: VorssaintDeveloper --teams-record-trial /absolute/existing-output-folder\n", stderr)
            exit(2)
        }
        let trial = TeamsRecordingTrial(parent: URL(fileURLWithPath: arguments[2]))
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = trial
        withExtendedLifetime(trial) { app.run() }
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        recorder.onStopDetection = { [weak self] in self?.stop() }
        recorder.requestAccessibility()
        recorder.startMonitoring()
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            signals.append(source)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stop()
        return .terminateCancel
    }

    private func stop() {
        recorder.shutdown {
            NSApp.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: false) }
        }
    }
}
