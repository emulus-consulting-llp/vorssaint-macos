// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Keeps the public feed in step with private history. Confined to the Usage
/// Timeline worker. A feed error is reported and retried on the next publish;
/// it never stops collection.
final class ActivityFeedPublisher {
    enum Outcome: Equatable { case skipped, published, failed }
    /// Ordinary checkpoints refresh the feed at most this often.
    static let interval: TimeInterval = 15

    private let url: URL?
    private var feed: ActivityFeedStore?
    private var lastPublish: TimeInterval?
    private var publishedDay: Date?
    private var needsRebuild = true
    private var staleDays: [DateInterval] = []

    init(url: URL? = ActivityFeedStore.defaultURL) {
        self.url = url
    }

    /// True when an ordinary publish would write: something is invalidated or
    /// the interval has passed since the last write.
    func isDue(at moment: UsageMoment) -> Bool {
        needsRebuild || !staleDays.isEmpty || lastPublish.map { moment.uptime - $0 >= Self.interval } ?? true
    }

    /// The next publish rewrites the whole feed from history.
    func invalidateAll() { needsRebuild = true }

    /// The next publish rewrites these days, e.g. after history deletion.
    func invalidate(_ range: DateInterval) { staleDays.append(range) }

    /// Rewrites the days live history can still change: today, the previous
    /// published day once midnight passes (closing its open rows), and any
    /// invalidated days.
    @discardableResult
    func publish(history: UsageTimelineStore, open: Set<UUID>, state: String,
                 at moment: UsageMoment, force: Bool = false) -> Outcome {
        if !force, !isDue(at: moment) { return .skipped }
        do {
            let feed = try openFeed()
            let rebuild = needsRebuild || feed.isEmpty
            let today = UsageDay.range(for: moment.date)
            var days: [DateInterval] = []
            if rebuild, let earliest = try history.earliestStart() {
                days = Self.days(covering: DateInterval(start: min(earliest, today.start), end: today.end))
            } else if !rebuild {
                days = staleDays.flatMap(Self.days(covering:))
                if let published = publishedDay, published < today.start { days.append(UsageDay.range(for: published)) }
                days.append(today)
            }
            var seen = Set<Date>()
            let rows = try days.filter { seen.insert($0.start).inserted }.map { day in
                let built = UsageDay.build(intervals: try history.intervals(in: day), range: day, until: moment.date)
                return (range: day, rows: ActivityFeedBuilder.rows(for: built, open: open))
            }
            var meta = Self.meta(state: state, at: moment.date)
            if rebuild { meta["history_from_ms"] = String(days.first.map { ActivityFeedBuilder.milliseconds($0.start) } ?? 0) }
            try feed.write(rows, replacingAll: rebuild, meta: meta)
            needsRebuild = false
            staleDays.removeAll()
            lastPublish = moment.uptime
            publishedDay = today.start
            return .published
        } catch {
            // Reopen next time: the file may have been removed or replaced.
            feed = nil
            return .failed
        }
    }

    /// Records a state without touching rows, e.g. "off" when tracking stops.
    @discardableResult
    func mark(state: String, at date: Date = Date()) -> Bool {
        do {
            try openFeed().writeMeta(Self.meta(state: state, at: date))
            return true
        } catch {
            feed = nil
            return false
        }
    }

    private func openFeed() throws -> ActivityFeedStore {
        if let feed { return feed }
        guard let url else { throw ActivityFeedStore.Failure.unavailable }
        let opened = try ActivityFeedStore(url: url)
        feed = opened
        return opened
    }

    private static func days(covering range: DateInterval) -> [DateInterval] {
        var result: [DateInterval] = []
        var day = UsageDay.range(for: range.start)
        while day.start < range.end {
            result.append(day)
            day = UsageDay.range(for: day.end)
        }
        return result
    }

    private static func meta(state: String, at date: Date) -> [String: String] {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return [
            "schema_version": String(ActivityFeedStore.schemaVersion),
            "writer": "\(bundle.bundleIdentifier ?? "vorssaint") \(version)",
            "timezone": TimeZone.current.identifier,
            "state": state,
            "updated_ms": String(ActivityFeedBuilder.milliseconds(date)),
        ]
    }
}
