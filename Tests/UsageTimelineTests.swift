// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import SQLite3

enum UsageTimelineTests {
    static func run(_ suite: TestSuite) {
        func moment(_ seconds: Double) -> UsageMoment { UsageMoment(date: Date(timeIntervalSince1970: seconds), uptime: seconds) }
        let firstWindow = UUID(), secondWindow = UUID()
        let first = UsageForeground(appName: "Editor", bundleID: "tests.editor", processID: "1:launch",
                                    windowID: firstWindow, title: "A", documentPath: "/tmp/A")
        var second = first
        second.windowID = secondWindow
        second.title = "B"
        let range = DateInterval(start: moment(0).date, end: moment(1000).date)
        var reducer = UsageReducer(at: moment(0))
        var persisted: [UUID: UsageInterval] = [:]
        func persist(_ values: [UsageInterval]) { for value in values { persisted[value.id] = value } }
        reducer.observe(first, at: moment(0))
        persist(reducer.checkpoint(at: moment(30)))
        reducer.observe(second, at: moment(40))
        persist(reducer.checkpoint(at: moment(120)))
        var conditions = UsageConditions()
        conditions.idle = true
        reducer.setConditions(conditions, at: moment(400), idleAge: 300)
        persist(reducer.checkpoint(at: moment(400)))
        let day = UsageDay.build(intervals: Array(persisted.values), range: range, until: moment(400).date)
        suite.expect(day.active == 100 && day.away == 300, "confirmed idle rewrites an earlier checkpoint without counting idle foreground")
        suite.expect(day.entries.filter { $0.state == .active }.map { $0.foreground?.windowID } == [firstWindow, secondWindow], "same-app windows retain separate identities")
        suite.expect(day.totals.count == 1 && day.totals[0].duration == 100, "same-app totals sum only active window intersections")
        suite.expect(reducer.foreground == nil, "idle stops foreground collection")

        conditions.idle = false
        conditions.locked = true
        conditions.screenOff = true
        reducer.setConditions(conditions, at: moment(410))
        conditions.screenOff = false
        reducer.setConditions(conditions, at: moment(420))
        suite.expect(reducer.presence.presence == .locked && !conditions.canReadMetadata, "screen wake does not override lock")
        reducer.observe(first, at: moment(425))
        suite.expect(reducer.foreground == nil, "blocked states refuse metadata")
        conditions.locked = false
        conditions.paused = true
        reducer.setConditions(conditions, at: moment(430))
        conditions.paused = false
        reducer.setConditions(conditions, at: moment(500))
        reducer.observe(first, at: moment(500))
        conditions.idle = true
        reducer.setConditions(conditions, at: moment(800), idleAge: 1000)
        persist(reducer.checkpoint(at: moment(800)))
        let paused = UsageDay.build(intervals: Array(persisted.values), range: range, until: moment(800).date)
        suite.expect(paused.other[.paused] == 70, "late idle classification cannot erase a pause before resume")

        var titleReducer = UsageReducer(at: moment(0))
        titleReducer.observe(first, at: moment(0))
        var renamed = first
        renamed.title = "Renamed"
        titleReducer.observe(renamed, at: moment(10))
        let renamedSpans = titleReducer.checkpoint(at: moment(20)).filter { $0.stream == .foreground }
        suite.expect(renamedSpans.count == 2 && renamedSpans.allSatisfy { $0.foreground?.windowID == firstWindow }, "title changes split visits without changing window identity")
        titleReducer.observe(renamed, at: moment(20))
        suite.expect(titleReducer.checkpoint(at: moment(25)).filter { $0.stream == .foreground }.count == 1, "duplicate metadata does not split visits")
        let jump = UsageMoment(date: Date(timeIntervalSince1970: 3600), uptime: 26)
        let clockSpans = titleReducer.checkpoint(at: jump)
        suite.expect(clockSpans.allSatisfy { $0.duration >= 0 && $0.end >= $0.start } && titleReducer.foreground?.start == jump.date, "clock discontinuities split streams without negative durations")

        suite.expect(UsageForeground.documentPath(from: "file:///tmp/Project%20budget.xlsx") == "/tmp/Project budget.xlsx", "document URLs preserve decoded local paths")
        suite.expect(UsageForeground.documentPath(from: "https://example.com/file") == nil && UsageForeground.documentPath(from: "budget.xlsx") == nil, "browser URLs and guessed paths are not stored")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let spring = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let autumn = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        suite.expect(UsageDay.range(for: spring, calendar: calendar).duration == 23 * 3600 && UsageDay.range(for: autumn, calendar: calendar).duration == 25 * 3600, "day boundaries honor both DST transitions")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("usage-timeline-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let url = temporary.appendingPathComponent("history.sqlite")
            let store = try UsageTimelineStore(url: url)
            let session = UUID()
            let interval = UsageInterval(sessionID: session, stream: .presence, start: moment(0).date,
                                         end: moment(100).date, duration: 100, presence: .active)
            try store.save([interval], session: session, checkpoint: moment(100).date)
            let reopened = try UsageTimelineStore(url: url)
            suite.expect(try reopened.intervals(in: range) == [interval], "checkpointed history survives opening another connection")
            let recovered = UsageDay.build(intervals: try reopened.intervals(in: range), range: range, until: moment(200).date)
            suite.expect(recovered.active == 0 && recovered.other[.unrecorded] == 200, "a checkpoint never fabricates foreground or extends through downtime")
            try store.delete(in: DateInterval(start: moment(30).date, end: moment(70).date))
            let remaining = try store.intervals(in: range)
            suite.expect(remaining.count == 2 && remaining.map(\.duration).reduce(0, +) == 60, "range deletion preserves intervals on both sides")
            suite.expect(remaining.allSatisfy { $0.end <= moment(30).date || $0.start >= moment(70).date }, "deleted time cannot remain in crossing spans")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let directory = try FileManager.default.attributesOfItem(atPath: temporary.path)
            suite.expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 && (directory[.posixPermissions] as? NSNumber)?.intValue == 0o700, "database and directory are owner-only")
            try store.delete(in: nil)
            suite.expect(try store.intervals(in: range).isEmpty, "delete all removes persisted intervals")
            var handle: OpaquePointer?
            sqlite3_open(url.path, &handle)
            sqlite3_exec(handle, "PRAGMA user_version=999", nil, nil, nil)
            sqlite3_close(handle)
            do {
                _ = try UsageTimelineStore(url: url)
                suite.expect(false, "unsupported schemas must be rejected")
            } catch UsageTimelineStore.Failure.unsupportedVersion {
                suite.expect(FileManager.default.fileExists(atPath: url.path), "unsupported databases remain intact")
            }
        } catch {
            suite.expect(false, "usage timeline storage fixture failed: \(error)")
        }
    }
}
