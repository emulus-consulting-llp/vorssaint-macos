// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import SQLite3

enum ActivityFeedTests {
    static func run(_ suite: TestSuite) {
        transientTitles(suite)
        builderRows(suite)
        storage(suite)
        publishing(suite)
    }

    private static func moment(_ seconds: Double) -> UsageMoment {
        UsageMoment(date: Date(timeIntervalSince1970: seconds), uptime: seconds)
    }

    private static let window = UUID()
    private static let terminal = UsageForeground(appName: "Terminal", bundleID: "tests.terminal", processID: "1:launch",
                                                  windowID: window, title: "zsh", documentPath: nil)

    private static func retitled(_ title: String) -> UsageForeground {
        var value = terminal
        value.title = title
        return value
    }

    private static func transientTitles(_ suite: TestSuite) {
        var reducer = UsageReducer(at: moment(0))
        reducer.observe(terminal, at: moment(0))
        reducer.observe(retitled("✳ Working"), at: moment(5))
        reducer.observe(retitled("✶ Working"), at: moment(5.4))
        reducer.observe(retitled("✻ Working"), at: moment(5.8))
        let spans = reducer.checkpoint(at: moment(20)).filter { $0.stream == .foreground }
        suite.expect(spans.count == 2 && spans.last?.foreground?.title == "✻ Working",
                     "titles redrawn within three seconds replace the open visit instead of splitting it")
        suite.expect(spans.map(\.duration).reduce(0, +) == 20, "absorbed title changes keep the visit's full duration")

        var steady = UsageReducer(at: moment(0))
        steady.observe(terminal, at: moment(0))
        steady.observe(retitled("Build"), at: moment(4))
        steady.observe(retitled("Deploy"), at: moment(8))
        suite.expect(steady.checkpoint(at: moment(10)).filter { $0.stream == .foreground }.count == 3,
                     "titles held at least three seconds still start separate visits")

        var document = UsageReducer(at: moment(0))
        document.observe(terminal, at: moment(0))
        document.observe(retitled("A"), at: moment(4))
        var moved = retitled("B")
        moved.documentPath = "/tmp/B.txt"
        document.observe(moved, at: moment(4.5))
        suite.expect(document.checkpoint(at: moment(6)).filter { $0.stream == .foreground }.count == 3,
                     "a document change splits even within the transient title window")

        var switching = UsageReducer(at: moment(0))
        switching.observe(bare, at: moment(0))
        switching.observe(terminal, at: moment(0.4))
        let switched = switching.checkpoint(at: moment(10)).filter { $0.stream == .foreground }
        suite.expect(switched.count == 1 && switched.first?.foreground == terminal,
                     "window details arriving just after an app switch complete the visit instead of splitting it")
        var windowless = UsageReducer(at: moment(0))
        windowless.observe(bare, at: moment(0))
        windowless.observe(terminal, at: moment(5))
        suite.expect(windowless.checkpoint(at: moment(10)).filter { $0.stream == .foreground }.count == 2,
                     "an app that stayed windowless is a visit of its own")
    }

    private static var bare: UsageForeground {
        var value = terminal
        value.windowID = nil
        value.title = nil
        return value
    }

    private static func builderRows(_ suite: TestSuite) {
        let session = UUID()
        func visit(_ focus: UsageForeground, _ start: Double, _ end: Double) -> UsageInterval {
            UsageInterval(sessionID: session, stream: .foreground, start: moment(start).date, end: moment(end).date,
                          duration: end - start, foreground: focus)
        }
        func state(_ value: UsagePresence, _ start: Double, _ end: Double) -> UsageInterval {
            UsageInterval(sessionID: session, stream: .presence, start: moment(start).date, end: moment(end).date,
                          duration: end - start, presence: value)
        }
        var other = terminal
        other.windowID = UUID()
        other.title = "notes"
        var report = terminal
        report.documentPath = "/tmp/report.txt"
        let live = visit(other, 100, 160)
        let intervals = [
            state(.active, 0, 100), state(.active, 100, 160), state(.locked, 160, 200),
            visit(terminal, 0, 10), visit(retitled("✳"), 10, 10.4), visit(retitled("long"), 10.4, 60),
            visit(report, 60, 100), live,
        ]
        let range = DateInterval(start: moment(0).date, end: moment(1000).date)
        let day = UsageDay.build(intervals: intervals, range: range, until: moment(200).date)
        let rows = ActivityFeedBuilder.rows(for: day, open: [live.id])
        suite.expect(rows.activity.count == 3, "title flicker inside one window and document becomes one segment")
        suite.expect(rows.activity.first?.title == "long" && rows.activity.first?.endMs == 60_000,
                     "a merged segment keeps the title shown longest and spans its visits")
        suite.expect(rows.activity.count == 3 && rows.activity[1].documentPath == "/tmp/report.txt"
                     && rows.activity[1].startMs == 60_000, "a different document stays a separate segment")
        let active = rows.activity.map { Double($0.endMs - $0.startMs) / 1000 }.reduce(0, +)
        suite.expect(abs(active - day.active) < 0.01, "published active time equals the timeline's own active total")
        suite.expect(rows.activity.last?.open == true && rows.activity.first?.open == false,
                     "only rows cut from live intervals are marked open")
        suite.expect(rows.presence.map(\.state) == [.locked] && rows.presence.first?.startMs == 160_000,
                     "away states are published as presence rows; active time is not duplicated there")
        suite.expect(rows.activity.allSatisfy { $0.startMs < $0.endMs }, "segments are non-empty Unix-millisecond spans")

        let legacy = [state(.active, 0, 100), visit(bare, 0, 0.4), visit(report, 0.4, 30),
                      visit(bare, 30, 40), visit(terminal, 40, 100)]
        let legacyRows = ActivityFeedBuilder.rows(for: UsageDay.build(intervals: legacy, range: range, until: moment(100).date), open: [])
        suite.expect(legacyRows.activity.map(\.startMs) == [0, 30_000, 40_000]
                     && legacyRows.activity.first?.documentPath == "/tmp/report.txt",
                     "older history's detail-less switch fragments join the visit they introduce, but long ones stay")
    }

    private static func storage(_ suite: TestSuite) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("activity-feed-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("feed.sqlite")
        do {
            let store = try ActivityFeedStore(url: url)
            suite.expect(store.isEmpty, "a new feed reports that it needs a rebuild")
            let day = DateInterval(start: moment(0).date, end: moment(86_400).date)
            let next = DateInterval(start: moment(86_400).date, end: moment(172_800).date)
            func segment(_ id: String, _ start: Int64) -> ActivityFeedSegment {
                ActivityFeedSegment(id: id, startMs: start, endMs: start + 1000, bundleID: "tests.app", appName: "App",
                                    title: nil, documentPath: nil, open: false)
            }
            try store.write([(day, ActivityFeedDay(activity: [segment("a", 1000), segment("b", 5000)])),
                             (next, ActivityFeedDay(activity: [segment("c", 90_000_000)]))],
                            replacingAll: false, meta: ["state": "active"])
            try store.write([(day, ActivityFeedDay(activity: [segment("a2", 2000)]))], replacingAll: false, meta: ["state": "idle"])
            suite.expect(try store.activity().map(\.id) == ["a2", "c"], "rewriting a day replaces only that day's rows")
            suite.expect(try store.meta()["state"] == "idle", "meta values are replaced in place")
            try store.write([], replacingAll: true, meta: [:])
            suite.expect(try store.activity().isEmpty, "a full rebuild clears rows from deleted history")

            var mode = ""
            var handle: OpaquePointer?
            sqlite3_open(url.path, &handle)
            var statement: OpaquePointer?
            sqlite3_prepare_v2(handle, "PRAGMA journal_mode", -1, &statement, nil)
            if sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) { mode = String(cString: text) }
            sqlite3_finalize(statement)
            sqlite3_exec(handle, "PRAGMA user_version=999", nil, nil, nil)
            sqlite3_close(handle)
            suite.expect(mode == "wal", "the feed uses WAL so readers never block the writer")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
            suite.expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
                         && (folder[.posixPermissions] as? NSNumber)?.intValue == 0o700, "feed files are owner-only")

            let reset = try ActivityFeedStore(url: url)
            suite.expect(try reset.activity().isEmpty && reset.isEmpty, "an unknown feed layout is replaced, not migrated")
        } catch {
            suite.expect(false, "activity feed storage fixture failed: \(error)")
        }
    }

    private static func publishing(_ suite: TestSuite) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("activity-feed-publish-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let history = try UsageTimelineStore(url: directory.appendingPathComponent("history.sqlite"))
            let start = UsageDay.range(for: Date()).start.addingTimeInterval(-86_400 + 3600)
            func at(_ offset: Double) -> UsageMoment { UsageMoment(date: start.addingTimeInterval(offset), uptime: offset) }
            let incrementalURL = directory.appendingPathComponent("incremental.sqlite")
            let incremental = ActivityFeedPublisher(url: incrementalURL)
            var reducer = UsageReducer(at: at(0))
            func checkpoint(_ offset: Double) -> ActivityFeedPublisher.Outcome {
                let moment = at(offset)
                try? history.save(reducer.checkpoint(at: moment), session: reducer.sessionID, checkpoint: moment.date)
                var open: Set<UUID> = [reducer.presence.id]
                if let foreground = reducer.foreground { open.insert(foreground.id) }
                return incremental.publish(history: history, open: open, state: "active", at: moment)
            }
            reducer.observe(terminal, at: at(0))
            let first = checkpoint(30)
            let throttled = checkpoint(35)
            suite.expect(first == .published && throttled == .skipped, "ordinary checkpoints publish at most every fifteen seconds")
            suite.expect(!incremental.isDue(at: at(40)) && incremental.isDue(at: at(45)),
                         "the feed is due again fifteen seconds after its last write")
            reducer.observe(retitled("other"), at: at(40))
            _ = checkpoint(60)
            var idle = UsageConditions()
            idle.idle = true
            reducer.setConditions(idle, at: at(400), idleAge: 300)
            _ = checkpoint(400)
            reducer.setConditions(UsageConditions(), at: at(86_400))
            reducer.observe(terminal, at: at(86_400))
            _ = checkpoint(86_500)

            let rebuiltURL = directory.appendingPathComponent("rebuilt.sqlite")
            let final = at(86_500)
            let rebuilt = ActivityFeedPublisher(url: rebuiltURL).publish(history: history, open: [], state: "off", at: final, force: true)
            suite.expect(rebuilt == .published, "a fresh publisher rebuilds the feed from history")
            let incrementalRows = try ActivityFeedStore(url: incrementalURL).activity()
            let rebuiltRows = try ActivityFeedStore(url: rebuiltURL).activity()
            let closed = { (rows: [ActivityFeedSegment]) in rows.map { row -> ActivityFeedSegment in var copy = row; copy.open = false; return copy } }
            suite.expect(!incrementalRows.isEmpty && closed(incrementalRows) == closed(rebuiltRows),
                         "incremental publishing across midnight matches a full rebuild")
            let idleStart = start.addingTimeInterval(100).timeIntervalSince1970 * 1000
            let wake = start.addingTimeInterval(86_400).timeIntervalSince1970 * 1000
            suite.expect(incrementalRows.allSatisfy { Double($0.endMs) <= idleStart || Double($0.startMs) >= wake },
                         "backdated idle is withdrawn from previously published activity")

            let yesterday = UsageDay.range(for: start)
            try history.delete(in: yesterday)
            incremental.invalidate(yesterday)
            _ = incremental.publish(history: history, open: [], state: "active", at: at(86_501))
            let afterDelete = try ActivityFeedStore(url: incrementalURL).activity()
            suite.expect(afterDelete.allSatisfy { Double($0.startMs) >= yesterday.end.timeIntervalSince1970 * 1000 },
                         "deleting a history day removes its feed rows")

            let blocked = directory.appendingPathComponent("blocked")
            try Data().write(to: blocked)
            let outcome = ActivityFeedPublisher(url: blocked.appendingPathComponent("feed.sqlite"))
                .publish(history: history, open: [], state: "active", at: final, force: true)
            suite.expect(try outcome == .failed && history.earliestStart() != nil,
                         "an unwritable feed reports failure without touching history")
        } catch {
            suite.expect(false, "activity feed publishing fixture failed: \(error)")
        }
    }
}
