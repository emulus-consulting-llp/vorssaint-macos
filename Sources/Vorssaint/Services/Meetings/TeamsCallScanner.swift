// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import ApplicationServices
import CoreMedia

/// Explicitly enabled meeting detection. Scans are serialized by the caller;
/// each has a budget and unsupported/slow observations remain unknown.
final class TeamsCallScanner {
    struct Reading {
        var evidence: TeamsRecordingPolicy.Evidence = .unknown
        var pid: Int32?
        var title = "Teams call"
        var observation = TeamsCallObservation()
        var started: TimeInterval = 0
        var ended: TimeInterval = 0
        var issue: String?
    }

    private let queue = DispatchQueue(label: "com.vorssaint.teams.scanner", qos: .utility)
    private var pid: Int32?
    private var root: AXUIElement?
    private var previousFlags: [(String, Bool)] = []
    private var callWindow: AXUIElement?
    private var callID = UUID().uuidString

    static var now: TimeInterval { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func scan(pid: Int32?, completion: @escaping (Reading) -> Void) {
        queue.async { [self] in
            var reading = Reading()
            reading.pid = pid
            reading.started = Self.now
            defer {
                reading.ended = Self.now
                DispatchQueue.main.async { completion(reading) }
            }
            guard AXIsProcessTrusted() else {
                reading.issue = "Accessibility unavailable; call state unknown."
                return
            }
            if self.pid != pid {
                restore()
                self.pid = pid
            }
            guard let pid else {
                reading.evidence = .absent
                return
            }
            let reader = TeamsAXReader()
            if root == nil {
                let app = AXUIElementCreateApplication(pid)
                root = app
                for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
                    AXUIElementSetMessagingTimeout(app, 0.25)
                    if let previous = reader.bool(app, name) { previousFlags.append((name, previous)) }
                    _ = AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanTrue)
                }
                // Let Teams publish its tree before the next scan. Activation
                // happens once per process, never on every polling tick.
                reading.issue = "Waiting for Teams accessibility."
                return
            }
            guard let root else { return }
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            let windows = reader.elements(root, attribute: kAXWindowsAttribute, limit: 8,
                                          deadline: deadline, timeout: 0.25)
            guard windows.error == nil, !windows.truncated else {
                reading.issue = "Teams window enumeration incomplete."
                return
            }
            if windows.elements.isEmpty {
                reading.evidence = .absent
                // Keep identity through a transient empty list. The lifecycle
                // debounce, not one scan, decides that the call ended.
                return
            }
            var matches: [(AXUIElement, TeamsAXSnapshot, TeamsCallObservation)] = []
            for window in windows.elements {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else {
                    reading.issue = "Teams scan exceeded its time budget."
                    return
                }
                var limits = TeamsAXSnapshot.Limits()
                limits.maxDepth = 35
                limits.maxNodes = 1_500
                limits.duration = remaining
                limits.messagingTimeout = 0.25
                let snapshot = TeamsAXTraversal.collect(root: window, reader: reader, limits: limits)
                let observation = TeamsCallObservation.read(snapshot)
                if observation.callEvidence == .present { matches.append((window, snapshot, observation)) }
            }
            guard matches.count == 1, let match = matches.first else {
                reading.issue = matches.isEmpty ? "No verified call controls; state unknown." : "Multiple call windows; state unknown."
                return
            }
            if callWindow.map({ CFEqual($0, match.0) }) != true {
                callWindow = match.0
                callID = UUID().uuidString
            }
            reading.evidence = .present(callID)
            reading.observation = match.2
            if let title = match.1.nodes.first?.attributes[kAXTitleAttribute], !title.isEmpty {
                reading.title = title
            }
        }
    }

    func stop(completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            let restored = restore()
            DispatchQueue.main.async { completion(restored) }
        }
    }

    @discardableResult
    private func restore() -> Bool {
        var restored = true
        if let root {
            let reader = TeamsAXReader()
            for (name, value) in previousFlags.reversed() {
                AXUIElementSetMessagingTimeout(root, 0.25)
                _ = AXUIElementSetAttributeValue(root, name as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
                if reader.bool(root, name) != value { restored = false }
            }
        }
        previousFlags.removeAll()
        root = nil
        pid = nil
        callWindow = nil
        return restored
    }
}
