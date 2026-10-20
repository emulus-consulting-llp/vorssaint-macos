// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// One `activity` row of the public feed: active use of one window and
/// document. Times are Unix epoch milliseconds; see docs/ACTIVITY-FEED.md.
struct ActivityFeedSegment: Equatable {
    var id: String
    var startMs: Int64
    var endMs: Int64
    var bundleID: String?
    var appName: String
    var title: String?
    var documentPath: String?
    var open: Bool
}

/// One `presence` row: a span that was not active use (idle, locked, paused…).
struct ActivityFeedPresence: Equatable {
    var id: String
    var startMs: Int64
    var endMs: Int64
    var state: UsagePresence
    var open: Bool
}

struct ActivityFeedDay: Equatable {
    var activity: [ActivityFeedSegment] = []
    var presence: [ActivityFeedPresence] = []
}

/// Pure mapping from one built day to feed rows. Active time is exactly what
/// `UsageDay.build` counts as active, so the feed never disagrees with the
/// Usage Timeline window.
enum ActivityFeedBuilder {
    /// Visits to the same window separated by no more than this are one
    /// segment: AX re-reads and title redraws leave hairline gaps.
    static let joinGap: TimeInterval = 1

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// `open` names stored intervals that are still growing.
    static func rows(for day: UsageDay, open: Set<UUID>) -> ActivityFeedDay {
        var result = ActivityFeedDay()
        var titles: [(title: String?, duration: TimeInterval)] = []
        var lastActive: (focus: UsageForeground, end: Date)?
        var lastPresence: (state: UsagePresence, end: Date)?
        for entry in day.entries {
            let isOpen = entry.source.map(open.contains) ?? false
            if entry.state == .active, let focus = entry.foreground {
                if let previous = lastActive, let last = result.activity.indices.last,
                   entry.start.timeIntervalSince(previous.end) <= joinGap,
                   sameVisit(previous.focus, focus) || introduces(previous.focus, focus, result.activity[last]) {
                    result.activity[last].endMs = milliseconds(entry.end)
                    result.activity[last].open = result.activity[last].open || isOpen
                    result.activity[last].documentPath = result.activity[last].documentPath ?? focus.documentPath
                    titles.append((focus.title, entry.duration))
                } else {
                    closeTitles(&result, titles)
                    titles = [(focus.title, entry.duration)]
                    result.activity.append(ActivityFeedSegment(
                        id: entry.id, startMs: milliseconds(entry.start), endMs: milliseconds(entry.end),
                        bundleID: focus.bundleID, appName: focus.appName, title: focus.title,
                        documentPath: focus.documentPath, open: isOpen))
                }
                lastActive = (focus, entry.end)
            } else if entry.state != .active, entry.state != .unrecorded {
                if let previous = lastPresence, previous.state == entry.state,
                   entry.start.timeIntervalSince(previous.end) <= joinGap {
                    result.presence[result.presence.count - 1].endMs = milliseconds(entry.end)
                    result.presence[result.presence.count - 1].open = result.presence[result.presence.count - 1].open || isOpen
                } else {
                    result.presence.append(ActivityFeedPresence(
                        id: entry.id, startMs: milliseconds(entry.start), endMs: milliseconds(entry.end),
                        state: entry.state, open: isOpen))
                }
                lastPresence = (entry.state, entry.end)
            }
        }
        closeTitles(&result, titles)
        return result
    }

    private static func sameVisit(_ a: UsageForeground, _ b: UsageForeground) -> Bool {
        a == b || a.differsOnlyByTitle(from: b)
    }

    /// A short detail-less fragment right after an app switch belongs to the
    /// visit its window read completed. The reducer merges these itself now;
    /// this keeps older history consistent.
    private static func introduces(_ pending: UsageForeground, _ next: UsageForeground,
                                   _ segment: ActivityFeedSegment) -> Bool {
        pending.awaitsDetails(of: next)
            && Double(segment.endMs - segment.startMs) < UsageReducer.transientTitle * 1000
    }

    /// A merged segment keeps the title it showed for the longest time.
    private static func closeTitles(_ result: inout ActivityFeedDay, _ titles: [(title: String?, duration: TimeInterval)]) {
        guard !result.activity.isEmpty, titles.count > 1 else { return }
        var totals: [String?: TimeInterval] = [:]
        for (title, duration) in titles { totals[title, default: 0] += duration }
        var best = titles[0].title
        for (title, _) in titles where totals[title, default: 0] > totals[best, default: 0] { best = title }
        result.activity[result.activity.count - 1].title = best
    }
}
