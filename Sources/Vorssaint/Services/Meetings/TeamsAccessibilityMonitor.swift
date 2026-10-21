// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices

/// One-shot diagnostics only. No idle polling, call detection or UI actions
/// until real Teams snapshots establish the supported roles and identifiers.
final class TeamsAccessibilityMonitor {
    static let bundleIdentifier = "com.microsoft.teams2"
    private let queue = DispatchQueue(label: "com.vorssaint.teams.accessibility", qos: .utility)

    struct Report: Codable {
        var schemaVersion = 2
        var capturedAt = Date()
        var macOS = ProcessInfo.processInfo.operatingSystemVersionString
        var teamsVersion: String?
        var bundleIdentifier = TeamsAccessibilityMonitor.bundleIdentifier
        var processID: Int32?
        var accessibilityTrusted = false
        var status = "notStarted"
        var windows: [TeamsAXSnapshot.Node] = []
        var selectedWindowIndex: Int?
        var snapshot: TeamsAXSnapshot?
        var observation: TeamsCallObservation?
        var activation: [Activation] = []
        var notes: [String] = []
    }

    struct Activation: Codable {
        let attribute: String
        var previousValue: Bool?
        var setResult: Int32?
        var readBackValue: Bool?
        var restoreResult: Int32?
        var restoredValue: Bool?
    }

    func inspect(windowIndex: Int?, enhancedAccessibility: Bool,
                 completion: @escaping (Report) -> Void) {
        // NSWorkspace inventory is obtained on the caller's main thread;
        // all AX IPC, including root queries, runs on the serial worker.
        let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == Self.bundleIdentifier }
        let pid = app?.processIdentifier
        let version = app?.bundleURL.flatMap { Bundle(url: $0) }?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        queue.async {
            var report = Report()
            report.processID = pid
            report.teamsVersion = version
            report.selectedWindowIndex = windowIndex
            report.accessibilityTrusted = AXIsProcessTrusted()
            guard report.accessibilityTrusted else {
                report.status = "accessibilityDenied"
                completion(report)
                return
            }
            guard let pid else {
                report.status = "teamsNotRunning"
                completion(report)
                return
            }
            let root = AXUIElementCreateApplication(pid)
            let reader = TeamsAXReader()
            let activationNames = enhancedAccessibility
                ? ["AXManualAccessibility", "AXEnhancedUserInterface"] : ["AXManualAccessibility"]
            for name in activationNames {
                AXUIElementSetMessagingTimeout(root, 0.5)
                var change = Activation(attribute: name)
                change.previousValue = reader.bool(root, name)
                change.setResult = AXUIElementSetAttributeValue(root, name as CFString, kCFBooleanTrue).rawValue
                change.readBackValue = reader.bool(root, name)
                report.activation.append(change)
            }
            // Chromium-derived apps may populate the tree asynchronously.
            Thread.sleep(forTimeInterval: 0.3)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            let windows = reader.elements(root, attribute: kAXWindowsAttribute,
                                          limit: 32, deadline: deadline, timeout: 0.5)
            if let error = windows.error { report.notes.append("windowListError:\(error)") }
            if windows.truncated { report.notes.append("windowListTruncated") }
            for (index, window) in windows.elements.enumerated() {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    report.notes.append("windowListDeadline")
                    break
                }
                let fields = reader.attributes(of: window, deadline: deadline, timeout: 0.5)
                report.windows.append(.init(path: "windows/\(index)", depth: 0,
                                            attributes: fields.values, errors: fields.errors,
                                            omissions: fields.textTruncated ? ["textLimit"] : []))
            }
            if let index = windowIndex {
                if windows.elements.indices.contains(index) {
                    report.snapshot = TeamsAXTraversal.collect(root: windows.elements[index], reader: reader)
                    report.observation = report.snapshot.map(TeamsCallObservation.read)
                    report.status = report.snapshot?.incompleteReasons.isEmpty == true ? "captured" : "partial"
                    report.notes.append("Window indices and paths are snapshot-local, not stable selectors.")
                } else {
                    report.status = "windowIndexUnavailable"
                }
            } else {
                report.status = windows.error == nil && report.notes.isEmpty ? "windowsListed" : "partial"
                report.notes.append("No window contents traversed. Select a test-call window with --window-index.")
            }
            // Restore only values actually observed. A write-only unsupported
            // attribute must never be guessed false and disable another client.
            for index in report.activation.indices.reversed() {
                if let original = report.activation[index].previousValue {
                    AXUIElementSetMessagingTimeout(root, 0.5)
                    report.activation[index].restoreResult = AXUIElementSetAttributeValue(root,
                        report.activation[index].attribute as CFString,
                        original ? kCFBooleanTrue : kCFBooleanFalse).rawValue
                    report.activation[index].restoredValue = reader.bool(root, report.activation[index].attribute)
                    if report.activation[index].restoredValue != original {
                        report.notes.append("Restoration of \(report.activation[index].attribute) could not be verified.")
                    }
                } else {
                    report.notes.append("Previous \(report.activation[index].attribute) was unreadable; not restored.")
                }
            }
            completion(report)
        }
    }
}

/// Every queried element receives its own timeout. Never changes the process-
/// wide default, which would affect Vorssaint's other Accessibility features.
struct TeamsAXReader: TeamsAXReading {
    func sameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool { CFEqual(lhs, rhs) }

    private func prepare(_ element: AXUIElement, deadline: TimeInterval, timeout: TimeInterval) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(min(timeout, remaining)))
        return true
    }

    func attributes(of element: AXUIElement, deadline: TimeInterval,
                    timeout: TimeInterval) -> TeamsAXAttributes {
        var result = TeamsAXAttributes()
        // Read subrole before value so secure fields never have their text read.
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute,
                     kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                     kAXHelpAttribute, kAXEnabledAttribute, "AXSelected", "AXDOMIdentifier",
                     "AXARIALive", "AXARIAAtomic", "AXARIABusy", "AXARIACurrent"]
        for name in names {
            if result.values[kAXSubroleAttribute] == "AXSecureTextField" { break }
            guard prepare(element, deadline: deadline, timeout: timeout) else {
                result.errors["deadline"] = Int(AXError.cannotComplete.rawValue)
                break
            }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if error == .success, let value {
                // Never stringify arbitrary AX objects or descendants.
                if let text = value as? String {
                    result.values[name] = String(text.prefix(2_048))
                    if text.count > 2_048 { result.textTruncated = true }
                }
                else if CFGetTypeID(value) == CFBooleanGetTypeID() {
                    result.values[name] = (value as? Bool) == true ? "true" : "false"
                } else if let number = value as? NSNumber { result.values[name] = number.stringValue }
            } else if error != .attributeUnsupported && error != .noValue {
                result.errors[name] = Int(error.rawValue)
                if error == .cannotComplete || error == .invalidUIElement { break }
            }
        }
        return result
    }

    func children(of element: AXUIElement, limit: Int, deadline: TimeInterval,
                  timeout: TimeInterval) -> TeamsAXChildren<AXUIElement> {
        elements(element, attribute: kAXChildrenAttribute, limit: limit, deadline: deadline, timeout: timeout)
    }

    func elements(_ element: AXUIElement, attribute: String, limit: Int,
                  deadline: TimeInterval, timeout: TimeInterval) -> TeamsAXChildren<AXUIElement> {
        guard prepare(element, deadline: deadline, timeout: timeout) else {
            return .init(error: Int(AXError.cannotComplete.rawValue))
        }
        var count = 0
        let countError = AXUIElementGetAttributeValueCount(element, attribute as CFString, &count)
        // Missing children are normal for a leaf. A missing root windows
        // attribute is NOT proof that Teams has no windows (or ended a call).
        if attribute == kAXChildrenAttribute,
           countError == .attributeUnsupported || countError == .noValue { return .init() }
        guard countError == .success else { return .init(error: Int(countError.rawValue)) }
        let requested = min(count, max(0, limit))
        guard requested > 0 else { return .init(truncated: count > 0) }
        guard prepare(element, deadline: deadline, timeout: timeout) else {
            return .init(error: Int(AXError.cannotComplete.rawValue))
        }
        var array: CFArray?
        let error = AXUIElementCopyAttributeValues(element, attribute as CFString, 0, requested, &array)
        guard error == .success else { return .init(error: Int(error.rawValue)) }
        guard let elements = array as? [AXUIElement] else {
            return .init(error: Int(AXError.failure.rawValue))
        }
        return .init(elements: elements, truncated: count > requested)
    }

    func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }
}
