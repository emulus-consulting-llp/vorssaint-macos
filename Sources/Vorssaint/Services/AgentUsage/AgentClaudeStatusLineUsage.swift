// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreFoundation
import Foundation

/// Claude Code hands its status line command the plan's limits on every
/// render: each window's percentage used and when it renews. A personal
/// status line hook keeps the latest of them in `~/.aiusage/claude.json`,
/// which is all this reads. Nothing is written or sent, and the file holds no
/// sign-in. It is as fresh as Claude Code's last render, so every reading
/// keeps its own time.
enum AgentClaudeStatusLineUsage {
    static let maximumSize = 64 << 10

    static func cacheURL(home: URL) -> URL {
        home.appending(path: ".aiusage/claude.json", directoryHint: .notDirectory)
    }

    private static let windows: [(key: String, id: String, kind: AgentLimitWindow.Kind, minutes: Int)] = [
        ("five_hour", "claude.fh", .session, 300), ("seven_day", "claude.sd", .weekly, 10_080)]

    /// The windows still running at `now`. A window that renewed after the
    /// reading has spent an unknown amount since, so it is left out rather
    /// than shown empty, as with the Claude app's readings. Once every window
    /// has, the reading comes back with none: the plan still has limits, and
    /// the card keeps their rows until the next reading.
    static func limits(from data: Data, now: Date) -> AgentLimits? {
        guard data.count <= maximumSize,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stamp = number(json["fetched_at"]), stamp > 0 else { return nil }
        let observed = Date(timeIntervalSince1970: stamp)
        guard observed <= now.addingTimeInterval(300), now.timeIntervalSince(observed) < 7 * 86_400 else { return nil }
        var result: [AgentLimitWindow] = []
        var known = false
        for window in windows {
            guard let values = json[window.key] as? [String: Any],
                  let used = number(values["used_percentage"]) else { continue }
            known = true
            let resets = number(values["resets_at"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            if let resets, resets <= now { continue }
            if resets == nil, now.timeIntervalSince(observed) >= 86_400 { continue }
            result.append(AgentLimitWindow(id: window.id, kind: window.kind, minutes: window.minutes, scope: nil,
                                           usedPercent: min(100, max(0, used)), resetsAt: resets))
        }
        guard known else { return nil }
        // Kept with the Claude app's readings: both are saved on this Mac and
        // read again on every tick, and the archive already knows the source.
        return AgentLimits(provider: .claude, windows: result, observedAt: observed, source: .claudeApp)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
