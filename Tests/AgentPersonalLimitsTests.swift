// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Claude's status line cache and the personal Codex session budget.
enum AgentPersonalLimitsTests {
    static func run(_ suite: TestSuite) {
        statusLine(suite)
        codexBudget(suite)
    }

    private static func statusLine(_ suite: TestSuite) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func cache(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        let fetched = now.timeIntervalSince1970 - 120
        let full = cache(["fetched_at": fetched, "has_limits": true,
                          "five_hour": ["used_percentage": 95.0, "resets_at": fetched + 3600],
                          "seven_day": ["used_percentage": 32, "resets_at": fetched + 86_400]])
        let limits = AgentClaudeStatusLineUsage.limits(from: full, now: now)
        suite.expect(limits?.windows.map(\.kind) == [.session, .weekly] && limits?.windows.map(\.id) == ["claude.fh", "claude.sd"],
                     "status line cache reads Claude's session and week with the Claude app's window IDs")
        suite.expect(limits?.windows.first?.usedPercent == 95 && limits?.windows.last?.usedPercent == 32
                     && limits?.windows.first?.resetsAt == Date(timeIntervalSince1970: fetched + 3600),
                     "status line percentages and exact renewal times are kept")
        suite.expect(limits?.observedAt == Date(timeIntervalSince1970: fetched) && limits?.source == .claudeApp,
                     "status line readings keep their own time and an archive-known source")
        let later = now.addingTimeInterval(3600)
        suite.expect(AgentClaudeStatusLineUsage.limits(from: full, now: later)?.windows.map(\.kind) == [.weekly],
                     "a renewed session is left out rather than shown empty")
        let afterWeek = AgentClaudeStatusLineUsage.limits(from: full, now: now.addingTimeInterval(2 * 86_400))
        suite.expect(afterWeek?.windows == [] && afterWeek?.observedAt == Date(timeIntervalSince1970: fetched),
                     "once every window renewed, the reading keeps its time and no windows, so the card keeps their rows")
        suite.expect(AgentClaudeStatusLineUsage.limits(from: cache(["fetched_at": fetched, "has_limits": false,
                                                                    "five_hour": NSNull(), "seven_day": NSNull()]),
                                                       now: now) == nil,
                     "a hook run without limits reports none")
        suite.expect(AgentClaudeStatusLineUsage.limits(from: cache(["fetched_at": now.timeIntervalSince1970 + 3600,
                                                                    "five_hour": ["used_percentage": 5]]), now: now) == nil,
                     "a future-dated cache is rejected")
        suite.expect(AgentClaudeStatusLineUsage.limits(from: cache(["fetched_at": fetched,
                                                                    "five_hour": ["used_percentage": true]]), now: now) == nil
                     && AgentClaudeStatusLineUsage.limits(from: Data("{".utf8), now: now) == nil,
                     "malformed caches invent no percentage")
        suite.expect(AgentClaudeStatusLineUsage.limits(from: cache(["fetched_at": fetched,
                                                                    "five_hour": ["used_percentage": 140, "resets_at": fetched + 600]]),
                                                       now: now)?.windows.first?.usedPercent == 100,
                     "overage is clamped to a full window")

        let retained = AgentClaudeStatusLineUsage.latest(app: nil, statusLine: nil, previous: limits, now: now)
        suite.expect(retained == limits, "a hook render without limits preserves the last known Claude quota")
        suite.expect(AgentClaudeStatusLineUsage.latest(app: nil, statusLine: nil, previous: limits,
                                                     now: later)?.windows.map(\.kind) == [.weekly],
                     "retained Claude readings remove a session that has renewed")
        suite.expect(AgentClaudeStatusLineUsage.latest(app: nil, statusLine: nil, previous: limits,
                                                     now: now.addingTimeInterval(2 * 86_400))?.windows.isEmpty == true,
                     "retained Claude readings keep pending rows after both windows renew")
        suite.expect(AgentClaudeStatusLineUsage.latest(app: nil, statusLine: nil, previous: limits,
                                                     now: now.addingTimeInterval(7 * 86_400)) == nil,
                     "retained Claude readings expire after a week")
        let fresh = AgentClaudeStatusLineUsage.limits(from: cache(["fetched_at": fetched + 60,
            "five_hour": ["used_percentage": 98, "resets_at": fetched + 3600]]), now: now)
        suite.expect(AgentClaudeStatusLineUsage.latest(app: limits, statusLine: fresh, previous: retained, now: now) == fresh,
                     "a newer Claude reading replaces the retained quota")
    }

    private static func codexBudget(_ suite: TestSuite) {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let weekEnd = start.addingTimeInterval(5 * 86_400)
        func reading(_ used: Double, at offset: TimeInterval, resets: Date? = nil,
                     session: Bool = false) -> AgentLimits {
            var windows = [AgentLimitWindow(id: "codex.10080", kind: .weekly, minutes: 10_080, scope: nil,
                                            usedPercent: used, resetsAt: resets ?? weekEnd)]
            if session {
                windows.insert(AgentLimitWindow(id: "codex.300", kind: .session, minutes: 300, scope: nil,
                                                usedPercent: 40, resetsAt: start.addingTimeInterval(3600)), at: 0)
            }
            return AgentLimits(provider: .codex, windows: windows, observedAt: start.addingTimeInterval(offset),
                               source: .sessionLog)
        }

        var budget = AgentCodexSessionBudget()
        budget.observe(reading(9, at: 0))
        suite.expect(budget.startedAt == nil && budget.window(now: start).usedPercent == 0,
                     "the first reading sets a baseline without starting a session")
        budget.observe(reading(11, at: 600))
        budget.observe(reading(12, at: 1200))
        let window = budget.window(now: start.addingTimeInterval(1200))
        suite.expect(budget.startedAt == start.addingTimeInterval(600) && abs(window.usedPercent - 30) < 0.0001,
                     "a session starts at the first increase and spends ten weekly points per session")
        suite.expect(window.resetsAt == start.addingTimeInterval(600 + 5 * 3600) && window.kind == .session
                     && window.minutes == 300,
                     "the budget renews five hours after it began")
        let before = budget
        budget.observe(reading(20, at: 300))
        suite.expect(budget == before, "an older reading read later changes nothing")
        budget.observe(reading(30, at: 1800))
        suite.expect(budget.window(now: start.addingTimeInterval(1800)).usedPercent == 100,
                     "spending past the budget fills the session")

        budget.observe(reading(31, at: 600 + 5 * 3600 + 60))
        suite.expect(budget.startedAt == start.addingTimeInterval(600 + 5 * 3600 + 60)
                     && abs(budget.window(now: start.addingTimeInterval(600 + 5 * 3600 + 60)).usedPercent - 10) < 0.0001,
                     "after five hours the next increase starts a new session")
        suite.expect(budget.window(now: start.addingTimeInterval(30 * 3600)).usedPercent == 0
                     && budget.window(now: start.addingTimeInterval(30 * 3600)).resetsAt == nil,
                     "an elapsed session shows nothing spent")

        var banked = AgentCodexSessionBudget()
        banked.observe(reading(50, at: 0))
        banked.observe(reading(55, at: 60))
        banked.observe(reading(0, at: 120, resets: weekEnd.addingTimeInterval(86_400)))
        suite.expect(banked.startedAt == nil && banked.spentPercent == 0,
                     "a reset moved before its time starts counting again")

        var rollover = AgentCodexSessionBudget()
        rollover.observe(reading(80, at: 0, resets: start.addingTimeInterval(60)))
        rollover.observe(reading(4, at: 120, resets: start.addingTimeInterval(7 * 86_400)))
        suite.expect(rollover.startedAt == start.addingTimeInterval(120) && rollover.spentPercent == 4,
                     "a new week counts what it already shows")

        let shown = budget.adding(to: reading(31, at: 0), now: start)
        suite.expect(shown?.windows.map(\.id) == [AgentCodexSessionBudget.windowID, "codex.10080"],
                     "a week-only plan gains the budget as its session")
        suite.expect(budget.adding(to: reading(31, at: 0, session: true), now: start)?.windows.count == 2
                     && AgentCodexSessionBudget().adding(to: reading(31, at: 0), now: start)?.windows.count == 2,
                     "a week-only Codex plan always shows its personal session, while a native session is left alone")
        let weekOnly = reading(31, at: 0)
        let account = AgentLimits(provider: .codex, windows: weekOnly.windows, observedAt: start, source: .account)
        let idleBudget = AgentCodexSessionBudget().adding(to: account, now: start)
        suite.expect(AgentLimitSupport.displayWindows(idleBudget, now: start).map(\.kind) == [.session, .weekly]
                        && AgentLimitSupport.displayWindows(idleBudget, now: start).first?.usedPercent == 0,
                     "an account refresh cannot hide an idle personal session that has no reset time")
        let activeBudget = budget.adding(to: account, now: start.addingTimeInterval(6 * 3600))
        suite.expect(AgentLimitSupport.displayWindows(activeBudget, now: start.addingTimeInterval(12 * 3600)).map(\.kind)
                        == [.session, .weekly],
                     "the personal session row stays visible after its five-hour reset")

        let encoded = try? JSONEncoder().encode(budget)
        suite.expect(encoded.flatMap { try? JSONDecoder().decode(AgentCodexSessionBudget.self, from: $0) } == budget,
                     "the budget survives a relaunch")

        let history = [reading(0, at: 0), reading(2, at: 60), reading(4, at: 5 * 3600 + 120), reading(7, at: 5 * 3600 + 180)]
        var ordered = AgentCodexSessionBudget()
        ordered.observeHistory(history)
        for shuffled in [Array(history.reversed()), [history[0], history[3], history[1], history[2]]] {
            var replay = AgentCodexSessionBudget()
            replay.observeHistory(shuffled)
            suite.expect(replay == ordered && replay.window(now: start.addingTimeInterval(5 * 3600 + 180)).usedPercent == 50,
                         "overlapping Codex histories produce the same budget and reset regardless of file order")
        }
        let savedReplay = ordered
        ordered.observeHistory(history)
        suite.expect(ordered == savedReplay, "initial replay does not count observations already in the saved budget twice")
    }
}
