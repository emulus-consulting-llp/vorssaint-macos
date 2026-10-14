// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices

struct UsageApplicationSnapshot: Equatable {
    var pid: pid_t
    var name: String
    var bundleID: String?
    var processID: String

    init(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        name = app.localizedName ?? app.bundleIdentifier ?? String(pid)
        bundleID = app.bundleIdentifier
        processID = "\(pid):\(app.launchDate?.timeIntervalSince1970 ?? 0)"
    }
}

/// All state and AX calls belong to the service worker. The AX source is
/// delivered by the main run loop, but its callback only enqueues a read.
final class UsageFocusCollector {
    private let queue: DispatchQueue
    private let gate: UsageObservationGate
    private var app: UsageApplicationSnapshot?
    private var observer: AXObserver?
    private var observedWindow: AXUIElement?
    private var identities: [String: [(AXUIElement, UUID)]] = [:]
    private var storeTitles = true
    private var storePaths = true
    private var generation: UUID?
    private let callbackLock = NSLock()
    private var callbackPending = false
    private var retryToken = UUID()
    var onForeground: ((UsageForeground?, UsageMoment) -> Void)?

    init(queue: DispatchQueue, gate: UsageObservationGate) { self.queue = queue; self.gate = gate }

    func read(app next: UsageApplicationSnapshot?, titles: Bool, paths: Bool, generation: UUID, at moment: UsageMoment) {
        let appChanged = self.app != next
        if self.app != next || self.generation != generation {
            detach()
            app = next
            self.generation = generation
        }
        storeTitles = titles
        storePaths = paths
        if appChanged, gate.accepts(generation) {
            // App activation is already known. Do not charge a slow AX read
            // to the previous app while resolving the newly focused window.
            let fallback = next.map { UsageForeground(appName: $0.name, bundleID: $0.bundleID, processID: $0.processID) }
            onForeground?(fallback, moment)
        }
        refresh(at: moment, retriesRemaining: appChanged ? 3 : 0)
    }

    func stop() {
        retryToken = UUID()
        generation = nil
        detach()
        app = nil
    }

    func forget(processID: String) { identities.removeValue(forKey: processID) }

    private func refresh(at moment: UsageMoment, retriesRemaining: Int = 0) {
        retryToken = UUID()
        guard let generation, gate.accepts(generation) else { return }
        guard let app else { onForeground?(nil, moment); return }
        var result = UsageForeground(appName: app.name, bundleID: app.bundleID, processID: app.processID)
        guard AXIsProcessTrusted() else {
            detach()
            if gate.accepts(generation) { onForeground?(result, moment) }
            return
        }
        let application = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(application, 0.35)
        if observer == nil { installObserver(application: application, pid: app.pid) }
        let window = UsageFocusSupport.window(
            focused: { self.element(application, attribute: kAXFocusedWindowAttribute) },
            main: { self.element(application, attribute: kAXMainWindowAttribute) },
            windows: { self.value(application, attribute: kAXWindowsAttribute) as? [AXUIElement] ?? [] },
            isFocused: { self.value($0, attribute: kAXFocusedAttribute) as? Bool == true },
            isMain: { self.value($0, attribute: kAXMainAttribute) as? Bool == true },
            isMinimized: { self.value($0, attribute: kAXMinimizedAttribute) as? Bool == true })
        guard let window else {
            observeWindow(nil)
            if gate.accepts(generation) { onForeground?(result, moment) }
            retryMetadata(remaining: retriesRemaining, generation: generation, processID: app.processID)
            return
        }
        AXUIElementSetMessagingTimeout(window, 0.35)
        var known = identities[app.processID] ?? []
        if let id = known.first(where: { CFEqual($0.0, window) })?.1 { result.windowID = id }
        else {
            let id = UUID()
            known.append((window, id))
            result.windowID = id
        }
        // Prune closed windows even when they closed while another app was
        // foreground and their destruction notification was not observed.
        var rawWindows: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) == .success,
           let live = rawWindows as? [AXUIElement] {
            known.removeAll { candidate in !live.contains { CFEqual($0, candidate.0) } && !CFEqual(window, candidate.0) }
        }
        identities[app.processID] = known
        observeWindow(window)
        if storeTitles { result.title = string(window, attribute: kAXTitleAttribute) }
        if storePaths {
            result.documentPath = UsageFocusSupport.documentPath(
                document: { self.value(window, attribute: kAXDocumentAttribute) },
                url: { self.value(window, attribute: kAXURLAttribute) })
        }
        if gate.accepts(generation) { onForeground?(result, moment) }
        if (storePaths && result.documentPath == nil) || (storeTitles && result.title == nil) {
            retryMetadata(remaining: retriesRemaining, generation: generation, processID: app.processID)
        }
    }

    private func retryMetadata(remaining: Int, generation: UUID, processID: String) {
        guard remaining > 0 else { return }
        let token = retryToken
        queue.asyncAfter(deadline: .now() + 0.25 * Double(4 - remaining)) { [weak self] in
            guard let self, self.retryToken == token, self.generation == generation,
                  self.app?.processID == processID, self.gate.accepts(generation) else { return }
            self.refresh(at: .now, retriesRemaining: remaining - 1)
        }
    }

    private func installObserver(application: AXUIElement, pid: pid_t) {
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let created else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(created, application, name as CFString, context)
        }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    private func observeWindow(_ window: AXUIElement?) {
        if let old = observedWindow, let window, CFEqual(old, window) { return }
        if observedWindow == nil && window == nil { return }
        if let old = observedWindow, let observer {
            for name in [kAXTitleChangedNotification, kAXUIElementDestroyedNotification] {
                AXObserverRemoveNotification(observer, old, name as CFString)
            }
        }
        observedWindow = window
        if let window, let observer {
            let context = Unmanaged.passUnretained(self).toOpaque()
            for name in [kAXTitleChangedNotification, kAXUIElementDestroyedNotification] {
                AXObserverAddNotification(observer, window, name as CFString, context)
            }
        }
    }

    private func detach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        observedWindow = nil
    }

    private func element(_ source: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = value(source, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func string(_ source: AXUIElement, attribute: String) -> String? {
        guard let text = value(source, attribute: attribute) as? String, !text.isEmpty else { return nil }
        return text
    }

    private func value(_ source: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static let callback: AXObserverCallback = { observer, element, name, context in
        guard let context else { return }
        let collector = Unmanaged<UsageFocusCollector>.fromOpaque(context).takeUnretainedValue()
        guard collector.callbackLock.withLock({
            if collector.callbackPending { return false }
            collector.callbackPending = true
            return true
        }) else { return }
        let moment = UsageMoment.now
        collector.queue.async {
            defer { collector.callbackLock.withLock { collector.callbackPending = false } }
            guard let current = collector.observer, CFEqual(observer, current), collector.generation != nil else { return }
            if name as String == kAXUIElementDestroyedNotification, let process = collector.app?.processID {
                collector.identities[process]?.removeAll { CFEqual($0.0, element) }
                collector.observedWindow = nil
            }
            collector.refresh(at: moment, retriesRemaining: 3)
        }
    }
}
