// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import CoreGraphics

struct UsageTimelinePreferences: Equatable {
    var enabled: Bool
    var paused: Bool
    var idleMinutes: Int
    var titles: Bool
    var paths: Bool
    var excluded: Set<String>

    init(defaults: UserDefaults = .standard) {
        enabled = defaults.bool(forKey: DefaultsKey.usageTimelineEnabled)
        paused = defaults.bool(forKey: DefaultsKey.usageTimelinePaused)
        let minutes = defaults.integer(forKey: DefaultsKey.usageTimelineIdleMinutes)
        idleMinutes = [0, 1, 3, 5, 10].contains(minutes) ? minutes : 5
        titles = defaults.bool(forKey: DefaultsKey.usageTimelineTitles)
        paths = defaults.bool(forKey: DefaultsKey.usageTimelinePaths)
        excluded = Set(defaults.stringArray(forKey: DefaultsKey.usageTimelineExcludedApps) ?? [])
    }
}

/// Public methods and published state are main-thread only. Reducer, collector
/// and SQLite are confined to one worker so pause/deletion barriers also reject
/// AX callbacks that were already in flight.
final class UsageTimelineService: ObservableObject {
    static let shared = UsageTimelineService()
    private static var instantiated = false

    static func flushIfLoadedBeforeTermination() {
        if instantiated { shared.flushBeforeTermination() }
    }
    @Published private(set) var enabled = false
    @Published private(set) var paused = false
    @Published private(set) var state: UsagePresence = .unrecorded
    @Published private(set) var hasError = false
    @Published private(set) var appOnly = false
    @Published private(set) var revision = 0

    private let worker = DispatchQueue(label: "Vorssaint.UsageTimeline", qos: .utility)
    private let gate = UsageObservationGate()
    private lazy var collector: UsageFocusCollector = {
        let collector = UsageFocusCollector(queue: worker, gate: gate)
        collector.onForeground = { [weak self] focus, moment in self?.receive(focus, at: moment) }
        return collector
    }()
    // Worker state.
    private var store: UsageTimelineStore?
    private var reducer: UsageReducer?
    private var failed = false
    private var lastCheckpoint: TimeInterval = 0
    private var lastMetadata: TimeInterval = 0
    // Main-thread state.
    private var preferences: UsageTimelinePreferences?
    private var conditions = UsageConditions()
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var defaultsObserver: NSObjectProtocol?
    private var permissionObserver: AnyCancellable?

    private init() {
        Self.instantiated = true
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            self?.syncWithPreferences()
        }
        permissionObserver = Permissions.shared.$accessibility.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.sample(forceMetadata: true) }
        }
    }

    func syncWithPreferences() {
        let next = UsageTimelinePreferences()
        let available = UserDefaults.standard.bool(forKey: DefaultsKey.featureAvailable("usageTimeline"))
        guard preferences != next || enabled != (available && next.enabled) else { return }
        let wasEnabled = enabled
        let wasPaused = paused
        preferences = next
        enabled = available && next.enabled
        paused = next.paused
        removeObservers()
        conditions = UsageConditions.configured(previous: conditions, current: initialConditions(paused: paused),
                                                wasEnabled: wasEnabled, wasPaused: wasPaused)
        if enabled && !paused && !hasError { installObservers() }
        let shouldRun = enabled
        let moment = UsageMoment.now
        let initial = conditions
        worker.async {
            self.collector.stop()
            if !shouldRun {
                self.persist(at: moment)
                self.reducer = nil
                self.publishState(.unrecorded)
                return
            }
            if self.failed { return }
            do {
                try self.openStore()
                if !wasEnabled || self.reducer == nil {
                    self.reducer = UsageReducer(at: moment, conditions: initial)
                } else {
                    self.reducer?.setConditions(initial, at: moment)
                    // Metadata preferences affect new observations only.
                    self.reducer?.observe(nil, at: moment)
                }
                self.persist(at: moment)
                self.publishState(initial.presence)
            } catch { self.fail() }
        }
        sample(forceMetadata: true)
    }

    func startTracking() {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.featureAvailable("usageTimeline")) else { return }
        UserDefaults.standard.set(false, forKey: DefaultsKey.usageTimelinePaused)
        UserDefaults.standard.set(true, forKey: DefaultsKey.usageTimelineEnabled)
        syncWithPreferences()
    }

    func setPaused(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: DefaultsKey.usageTimelinePaused)
        syncWithPreferences()
    }

    func retry() {
        hasError = false
        preferences = nil
        worker.async {
            self.failed = false
            self.store = nil
            self.reducer = nil
        }
        syncWithPreferences()
    }

    func loadDay(_ date: Date, completion: @escaping (UsageDay?) -> Void) {
        let range = UsageDay.range(for: date)
        let moment = UsageMoment.now
        worker.async {
            do {
                try self.openStore()
                var intervals = try self.store!.intervals(in: range)
                // A visible view can extend the live interval without turning
                // an idle/paused window into a background writer every second.
                if !self.failed, var reducer = self.reducer {
                    let live = reducer.checkpoint(at: moment)
                    let ids = Set(live.map(\.id))
                    intervals.removeAll { ids.contains($0.id) }
                    intervals.append(contentsOf: live)
                }
                let day = UsageDay.build(intervals: intervals, range: range, until: moment.date)
                DispatchQueue.main.async { completion(day) }
            } catch {
                self.fail()
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    func deleteHistory(day: Date?, completion: @escaping (Bool) -> Void) {
        removeObservers()
        let range = day.map { UsageDay.range(for: $0) }
        let moment = UsageMoment.now
        let resume = enabled
        let initial = initialConditions(paused: paused)
        worker.async {
            self.collector.stop()
            self.persist(at: moment)
            self.reducer = nil
            do {
                try self.openStore()
                try self.store!.delete(in: range)
                self.failed = false
                if resume {
                    self.reducer = UsageReducer(at: .now, conditions: initial)
                    self.persist(at: .now)
                }
                DispatchQueue.main.async {
                    self.hasError = false
                    self.revision += 1
                    self.conditions = initial
                    if self.enabled && !self.paused { self.installObservers() }
                    self.sample(forceMetadata: true)
                    completion(true)
                }
            } catch {
                self.fail()
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// A synchronous worker barrier guarantees the last span is durable before
    /// normal app termination. Never called by the worker itself.
    func flushBeforeTermination() {
        removeObservers()
        let moment = UsageMoment.now
        worker.sync {
            collector.stop()
            persist(at: moment)
            reducer = nil
        }
    }

    private func initialConditions(paused: Bool) -> UsageConditions {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        let displayResult = CGGetOnlineDisplayList(32, &displays, &count)
        let screenOff = displayResult == .success && count > 0
            && displays.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
        return UsageConditions(paused: paused, switchedAway: !SessionActivity.shared.isActive,
                               locked: session?["CGSSessionScreenIsLocked"] as? Bool ?? false, screenOff: screenOff)
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping (Notification) -> Void) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: body)))
        }
        observe(center, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            // The workspace notification can precede frontmostApplication's
            // update. Its payload names the application being activated.
            self?.sample(forceMetadata: true,
                         activatedApp: note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        observe(center, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.sample(forceMetadata: true) }
        observe(center, NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let key = UsageApplicationSnapshot(app).processID
            self.worker.async { self.collector.forget(processID: key) }
            self.sample(forceMetadata: true)
        }
        let flags: [(NotificationCenter, Notification.Name, WritableKeyPath<UsageConditions, Bool>, Bool)] = [
            (center, NSWorkspace.willSleepNotification, \.sleeping, true),
            (center, NSWorkspace.didWakeNotification, \.sleeping, false),
            (center, NSWorkspace.screensDidSleepNotification, \.screenOff, true),
            (center, NSWorkspace.screensDidWakeNotification, \.screenOff, false),
            (center, NSWorkspace.sessionDidResignActiveNotification, \.switchedAway, true),
            (center, NSWorkspace.sessionDidBecomeActiveNotification, \.switchedAway, false),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), \.locked, true),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"), \.locked, false),
        ]
        for (center, name, key, value) in flags {
            observe(center, name) { [weak self] _ in
                guard let self else { return }
                self.conditions[keyPath: key] = value
                self.sample(forceMetadata: true)
            }
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.sample(forceMetadata: false) }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func removeObservers() {
        gate.invalidate()
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private func sample(forceMetadata: Bool, activatedApp: NSRunningApplication? = nil) {
        guard enabled, !hasError, let preferences else { return }
        let moment = UsageMoment.now
        var flags = conditions
        flags.paused = paused
        let idleAge = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        flags.idle = preferences.idleMinutes > 0 && idleAge >= Double(preferences.idleMinutes * 60)
        let runningApp = activatedApp ?? NSWorkspace.shared.frontmostApplication
        let app = runningApp.flatMap { $0.isTerminated ? nil : UsageApplicationSnapshot($0) }
        flags.excluded = app?.bundleID.map { preferences.excluded.contains($0) } ?? false
        let handoff = app?.pid == ProcessInfo.processInfo.processIdentifier && ActivationHandoff.isHandingOff
        if forceMetadata { gate.invalidate() }
        let token = gate.current
        let currentFlags = flags
        appOnly = !Permissions.shared.accessibility
        worker.async {
            guard !self.failed, self.reducer != nil else { return }
            let oldState = self.reducer?.conditions.presence
            self.reducer?.setConditions(currentFlags, at: moment, idleAge: idleAge)
            self.publishState(currentFlags.presence)
            if !currentFlags.canReadMetadata {
                self.collector.stop()
            } else if !handoff && (forceMetadata || oldState != .active || moment.uptime - self.lastMetadata >= 5) {
                self.lastMetadata = moment.uptime
                self.collector.read(app: app, titles: preferences.titles, paths: preferences.paths, generation: token, at: moment)
            }
            if oldState != currentFlags.presence || moment.uptime - self.lastCheckpoint >= 15 { self.persist(at: .now) }
        }
    }

    private func receive(_ focus: UsageForeground?, at moment: UsageMoment) {
        guard !failed, reducer?.conditions.canReadMetadata == true else { return }
        let previous = reducer?.foreground?.foreground
        reducer?.observe(focus, at: moment)
        if previous != focus { persist(at: moment) }
    }

    private func openStore() throws {
        guard store == nil else { return }
        guard let root = PrivateFileStore.containerURL else { throw UsageTimelineStore.Failure.unavailable }
        store = try UsageTimelineStore(url: root.appendingPathComponent("UsageTimeline/history.sqlite"))
    }

    private func persist(at moment: UsageMoment) {
        guard !failed, var reducer else { return }
        let intervals = reducer.checkpoint(at: moment)
        self.reducer = reducer
        do {
            try openStore()
            try store!.save(intervals, session: reducer.sessionID, checkpoint: moment.date)
            lastCheckpoint = moment.uptime
            DispatchQueue.main.async { self.revision += 1 }
        } catch { fail() }
    }

    private func publishState(_ value: UsagePresence) {
        DispatchQueue.main.async { if self.state != value { self.state = value } }
    }

    private func fail() {
        failed = true
        collector.stop()
        reducer = nil
        DispatchQueue.main.async {
            self.hasError = true
            self.removeObservers()
        }
    }
}
