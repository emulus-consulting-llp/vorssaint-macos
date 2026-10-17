// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// A personal session allowance for a Codex plan that reports only a weekly
/// window: ten percentage points of the week for every five hours. A session
/// begins with the first reading that shows the week went up, and lasts five
/// hours from then. Nothing here comes from OpenAI; it is a budget kept on
/// this Mac, from the weekly readings Codex writes to its session logs.
struct AgentCodexSessionBudget: Codable, Equatable {
    /// Percentage points of the weekly window one session may spend.
    static let weeklyShare = 10.0
    static let length: TimeInterval = 5 * 3600
    static let windowID = "codex.budget"

    private(set) var startedAt: Date?
    /// Percentage points of the week spent since the session began.
    private(set) var spentPercent: Double = 0
    private(set) var lastObserved: Date?
    private var lastWeeklyPercent: Double?
    private var lastWeeklyReset: Date?

    /// File modification order cannot establish five-hour session boundaries.
    /// Saved progress still wins over older history through observe's guard.
    mutating func observeHistory(_ readings: [AgentLimits]) {
        for reading in readings.sorted(by: {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            return ($0.windows.first { $0.kind == .weekly }?.usedPercent ?? 0)
                > ($1.windows.first { $0.kind == .weekly }?.usedPercent ?? 0)
        }) { observe(reading) }
    }

    /// Takes in a reading of the account, at the time it was made. Readings
    /// older than the last one taken add nothing: logs are not read in time
    /// order, and what an older reading spent is counted by the next newer one.
    mutating func observe(_ limits: AgentLimits) {
        guard limits.provider == .codex, let weekly = limits.windows.first(where: { $0.kind == .weekly }),
              lastObserved.map({ limits.observedAt > $0 }) ?? true else { return }
        let now = limits.observedAt
        if let start = startedAt, now >= start.addingTimeInterval(Self.length) || now < start {
            startedAt = nil
            spentPercent = 0
        }
        var increase = lastWeeklyPercent.map { max(0, weekly.usedPercent - $0) } ?? 0
        if let previous = lastWeeklyReset, let reset = weekly.resetsAt, abs(reset.timeIntervalSince(previous)) > 1 {
            if previous <= now {
                // A new week: everything it shows was spent after it began.
                increase = weekly.usedPercent
            } else {
                // A banked reset, another account or a changed allowance
                // starts counting again from here.
                startedAt = nil
                spentPercent = 0
                increase = 0
            }
        }
        if increase > 0 {
            if startedAt == nil { startedAt = now }
            spentPercent += increase
        }
        lastWeeklyPercent = weekly.usedPercent
        lastWeeklyReset = weekly.resetsAt
        lastObserved = now
    }

    /// The session as a limit window; nothing spent while none is running.
    func window(now: Date) -> AgentLimitWindow {
        let resets = startedAt?.addingTimeInterval(Self.length)
        let running = resets.map { $0 > now } ?? false
        return AgentLimitWindow(id: Self.windowID, kind: .session, minutes: Int(Self.length / 60), scope: nil,
                                usedPercent: running ? min(100, spentPercent / Self.weeklyShare * 100) : 0,
                                resetsAt: running ? resets : nil)
    }

    /// Codex's own limits with the session budget in front, when the plan
    /// reports a week and no session of its own.
    func adding(to limits: AgentLimits?, now: Date) -> AgentLimits? {
        guard var limits, limits.provider == .codex,
              limits.windows.contains(where: { $0.kind == .weekly }),
              !limits.windows.contains(where: { $0.kind == .session }) else { return limits }
        limits.windows.insert(window(now: now), at: 0)
        return limits
    }

    // MARK: Saved

    /// Beside the usage archive, and removed with it when the section is off.
    static var url: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return caches.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("AgentUsage", isDirectory: true)
            .appendingPathComponent("codex-session-budget.json", isDirectory: false)
    }

    static func load() -> AgentCodexSessionBudget? {
        guard let url, let data = try? Data(contentsOf: url), data.count <= 4_096 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    @discardableResult
    static func save(_ budget: AgentCodexSessionBudget) -> Bool {
        guard let url, let data = try? JSONEncoder().encode(budget) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func remove() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
