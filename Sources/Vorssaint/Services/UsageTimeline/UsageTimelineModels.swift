// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct UsageMoment {
    var date: Date
    var uptime: TimeInterval
    static var now: UsageMoment { UsageMoment(date: Date(), uptime: ProcessInfo.processInfo.systemUptime) }
}

enum UsagePresence: String, Codable, CaseIterable {
    case active, idle, screenOff, locked, sleeping, switchedAway, paused, excluded, unrecorded
    var isAway: Bool { [.idle, .screenOff, .locked, .sleeping, .switchedAway].contains(self) }
}

struct UsageConditions: Equatable {
    var paused = false
    var switchedAway = false
    var sleeping = false
    var locked = false
    var screenOff = false
    var idle = false
    var excluded = false

    var presence: UsagePresence {
        if paused { return .paused }
        if switchedAway { return .switchedAway }
        if sleeping { return .sleeping }
        if locked { return .locked }
        if screenOff { return .screenOff }
        if idle { return .idle }
        if excluded { return .excluded }
        return .active
    }
    var canReadMetadata: Bool { presence == .active }
}

struct UsageForeground: Codable, Equatable {
    var appName: String
    var bundleID: String?
    var processID: String
    var windowID: UUID?
    var title: String?
    var documentPath: String?

    static func documentPath(from value: String?) -> String? {
        guard let value, let url = URL(string: value), url.isFileURL else { return nil }
        return url.standardizedFileURL.path
    }
}

struct UsageInterval: Codable, Identifiable, Equatable {
    enum Stream: String, Codable { case foreground, presence }
    var id = UUID()
    var sessionID: UUID
    var stream: Stream
    var start: Date
    var end: Date
    var duration: TimeInterval
    var foreground: UsageForeground?
    var presence: UsagePresence?

    func clipped(to range: DateInterval) -> UsageInterval? {
        let lower = max(start, range.start), upper = min(end, range.end)
        guard upper > lower else { return nil }
        var result = self
        let fraction = upper.timeIntervalSince(lower) / max(end.timeIntervalSince(start), 0.001)
        result.start = lower
        result.end = upper
        result.duration = max(0, duration * min(1, fraction))
        return result
    }
}

/// Two independent streams keep late idle classification from rewriting every
/// window visited during the idle detection horizon. Only the active presence
/// interval is shortened; all foreground observations remain factual.
struct UsageReducer {
    let sessionID: UUID
    private(set) var conditions: UsageConditions
    private(set) var foreground: UsageInterval?
    private(set) var presence: UsageInterval
    private var foregroundUptime: TimeInterval?
    private var presenceUptime: TimeInterval
    private var previous: UsageMoment
    private var pending: [UsageInterval] = []

    init(at moment: UsageMoment, conditions: UsageConditions = UsageConditions(), sessionID: UUID = UUID()) {
        self.sessionID = sessionID
        self.conditions = conditions
        previous = moment
        presenceUptime = moment.uptime
        presence = UsageInterval(sessionID: sessionID, stream: .presence,
                                 start: moment.date, end: moment.date, duration: 0,
                                 presence: conditions.presence)
    }

    mutating func observe(_ value: UsageForeground?, at moment: UsageMoment) {
        advance(to: moment)
        let allowed = conditions.canReadMetadata ? value : nil
        guard foreground?.foreground != allowed else { return }
        closeForeground(at: moment)
        if let allowed {
            foreground = UsageInterval(sessionID: sessionID, stream: .foreground,
                                       start: moment.date, end: moment.date, duration: 0, foreground: allowed)
            foregroundUptime = moment.uptime
        }
    }

    mutating func setConditions(_ value: UsageConditions, at moment: UsageMoment,
                                idleAge: TimeInterval? = nil) {
        advance(to: moment)
        let oldState = conditions.presence
        conditions = value
        guard oldState != value.presence else { return }
        var boundary = moment
        if value.presence == .idle, oldState == .active, let idleAge {
            let elapsed = max(0, moment.uptime - presenceUptime)
            let backdate = min(max(0, idleAge), elapsed)
            boundary = UsageMoment(date: moment.date.addingTimeInterval(-backdate), uptime: moment.uptime - backdate)
        }
        extendPresence(to: boundary)
        pending.append(presence)
        presence = UsageInterval(sessionID: sessionID, stream: .presence,
                                 start: boundary.date, end: moment.date,
                                 duration: max(0, moment.uptime - boundary.uptime), presence: value.presence)
        presenceUptime = boundary.uptime
        if !value.canReadMetadata { closeForeground(at: moment) }
    }

    mutating func checkpoint(at moment: UsageMoment) -> [UsageInterval] {
        advance(to: moment)
        var result = pending
        pending.removeAll()
        result.append(presence)
        if let foreground { result.append(foreground) }
        return result
    }

    private mutating func advance(to moment: UsageMoment) {
        let elapsed = max(0, moment.uptime - previous.uptime)
        // Keep clock discontinuities out of measured durations and split both
        // streams rather than stretching a visit across an adjusted clock.
        if abs(moment.date.timeIntervalSince(previous.date) - elapsed) > 2 {
            let oldFocus = foreground?.foreground
            closeForeground(at: previous)
            extendPresence(to: previous)
            pending.append(presence)
            presence = UsageInterval(sessionID: sessionID, stream: .presence,
                                     start: moment.date, end: moment.date, duration: 0,
                                     presence: conditions.presence)
            presenceUptime = moment.uptime
            if let oldFocus, conditions.canReadMetadata {
                foreground = UsageInterval(sessionID: sessionID, stream: .foreground,
                                           start: moment.date, end: moment.date, duration: 0, foreground: oldFocus)
                foregroundUptime = moment.uptime
            }
        }
        extendPresence(to: moment)
        if var interval = foreground, let uptime = foregroundUptime {
            interval.end = max(interval.start, moment.date)
            interval.duration = max(0, moment.uptime - uptime)
            foreground = interval
        }
        previous = moment
    }

    private mutating func extendPresence(to moment: UsageMoment) {
        presence.end = max(presence.start, moment.date)
        presence.duration = max(0, moment.uptime - presenceUptime)
    }

    private mutating func closeForeground(at moment: UsageMoment) {
        if var interval = foreground {
            interval.end = max(interval.start, moment.date)
            interval.duration = max(0, moment.uptime - (foregroundUptime ?? moment.uptime))
            pending.append(interval)
        }
        foreground = nil
        foregroundUptime = nil
    }
}

struct UsageTimelineEntry: Identifiable, Equatable {
    var id: String
    var start: Date
    var end: Date
    var duration: TimeInterval
    var state: UsagePresence
    var foreground: UsageForeground?
    var appKey: String? { foreground.map { $0.bundleID ?? $0.processID } }
}

struct UsageAppTotal: Identifiable {
    var id: String
    var name: String
    var duration: TimeInterval
    var bundleID: String?
}

struct UsageDay {
    var range: DateInterval
    var entries: [UsageTimelineEntry]
    var totals: [UsageAppTotal]
    var active: TimeInterval
    var away: TimeInterval
    var other: [UsagePresence: TimeInterval]

    /// DateInterval follows the user's calendar, including 23/25-hour DST days.
    static func range(for date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .day, for: date)!
    }

    static func build(intervals: [UsageInterval], range: DateInterval, until: Date) -> UsageDay {
        let limit = min(range.end, until)
        guard limit > range.start else {
            return UsageDay(range: range, entries: [], totals: [], active: 0, away: 0, other: [:])
        }
        let bounded = DateInterval(start: range.start, end: limit)
        let spans = intervals.compactMap { $0.clipped(to: bounded) }
        let foreground = spans.filter { $0.stream == .foreground }.sorted { $0.start < $1.start }
        let presence = spans.filter { $0.stream == .presence }.sorted { $0.start < $1.start }
        var entries: [UsageTimelineEntry] = []
        var cursor = bounded.start
        func append(_ start: Date, _ end: Date, _ state: UsagePresence, _ focus: UsageForeground?, _ key: String) {
            guard end > start else { return }
            let entry = UsageTimelineEntry(id: key + ":" + String(start.timeIntervalSince1970), start: start,
                                           end: end, duration: end.timeIntervalSince(start), state: state, foreground: focus)
            entries.append(entry)
        }
        for span in presence {
            let start = max(cursor, span.start), end = span.end
            guard end > start else { continue }
            append(cursor, start, .unrecorded, nil, "gap")
            let state = span.presence ?? .unrecorded
            if state == .active {
                var focusedCursor = start
                for focus in foreground where focus.sessionID == span.sessionID && focus.end > start && focus.start < end {
                    let lower = max(focusedCursor, focus.start), upper = min(end, focus.end)
                    guard upper > lower else { continue }
                    append(focusedCursor, lower, .unrecorded, nil, "unknown")
                    append(lower, upper, .active, focus.foreground, focus.id.uuidString)
                    focusedCursor = upper
                }
                append(focusedCursor, end, .unrecorded, nil, "unknown")
            } else {
                append(start, end, state, nil, span.id.uuidString)
            }
            cursor = end
        }
        append(cursor, limit, .unrecorded, nil, "gap")
        var byApp: [String: UsageAppTotal] = [:]
        var active: TimeInterval = 0, away: TimeInterval = 0
        var other: [UsagePresence: TimeInterval] = [:]
        for entry in entries {
            if entry.state == .active, let focus = entry.foreground, let key = entry.appKey {
                active += entry.duration
                var total = byApp[key] ?? UsageAppTotal(id: key, name: focus.appName, duration: 0, bundleID: focus.bundleID)
                total.duration += entry.duration
                byApp[key] = total
            } else if entry.state.isAway { away += entry.duration }
            else { other[entry.state, default: 0] += entry.duration }
        }
        return UsageDay(range: range, entries: entries, totals: byApp.values.sorted {
            $0.duration == $1.duration ? $0.name < $1.name : $0.duration > $1.duration
        }, active: active, away: away, other: other)
    }
}
