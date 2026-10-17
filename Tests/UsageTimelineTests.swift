// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import SQLite3
import CoreGraphics

enum UsageTimelineTests {
    static func run(_ suite: TestSuite) {
        suite.expect(AppLanguage.allCases.allSatisfy { UsageTimelineStrings($0).isComplete }, "usage timeline has complete labels in every supported locale")
        let inputEvent = CGEventType(rawValue: UInt32.max)
        let idleAge = inputEvent.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
        suite.expect(idleAge.map { $0.isFinite && $0 >= 0 } ?? false, "macOS exposes a valid all-input idle age for the collector")
        suite.expect(!AppFeature.usageTimeline.installedByDefault, "timeline stays opt-in on updates")
        suite.expect(SettingsBackupSupport.machineStateKeys.contains(DefaultsKey.usageTimelinePaused)
                     && SettingsBackupSupport.exportKeys().contains(DefaultsKey.usageTimelineExcludedApps),
                     "portable exclusions are backed up while runtime pause state stays local")
        let gate = UsageObservationGate()
        let inFlight = gate.current
        gate.invalidate()
        suite.expect(!gate.accepts(inFlight) && gate.accepts(gate.current), "pause/deletion invalidation rejects in-flight observation generations")
        let formerlyLocked = UsageConditions(paused: true, locked: true, screenOff: true)
        let resumed = UsageConditions.configured(previous: formerlyLocked, current: UsageConditions(),
                                                wasEnabled: true, wasPaused: true)
        suite.expect(resumed.canReadMetadata, "resume uses a fresh unlocked snapshot after missing notifications while paused")
        let stillLocked = UsageConditions.configured(previous: UsageConditions(locked: true), current: UsageConditions(),
                                                    wasEnabled: true, wasPaused: false)
        suite.expect(stillLocked.presence == .locked, "changing recording preferences preserves a lock already observed by the running collector")
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
        var delayed = UsageReducer(at: moment(0))
        delayed.observe(first, at: moment(0))
        _ = delayed.checkpoint(at: moment(20))
        delayed.observe(second, at: moment(10))
        let delayedSpans = delayed.checkpoint(at: moment(30))
        suite.expect(delayedSpans.filter { $0.stream == .presence }.count == 1
                     && delayedSpans.filter { $0.stream == .foreground }.map(\.duration).reduce(0, +) == 30,
                     "a delayed observation timestamp is not mistaken for a system clock change")

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
        let measuredSession = UUID()
        let measuredFocus = UsageInterval(sessionID: measuredSession, stream: .foreground,
                                         start: moment(0).date, end: moment(10).date, duration: 9.5, foreground: first)
        let measuredPresence = UsageInterval(sessionID: measuredSession, stream: .presence,
                                            start: moment(0).date, end: moment(10).date, duration: 9.5, presence: .active)
        let measuredDay = UsageDay.build(intervals: [measuredFocus, measuredPresence], range: range, until: moment(10).date)
        suite.expect(measuredDay.active == 9.5, "summaries use measured duration rather than a drifting wall clock")
        let jump = UsageMoment(date: Date(timeIntervalSince1970: 3600), uptime: 26)
        let clockSpans = titleReducer.checkpoint(at: jump)
        suite.expect(clockSpans.allSatisfy { $0.duration >= 0 && $0.end >= $0.start } && titleReducer.foreground?.start == jump.date, "clock discontinuities split streams without negative durations")

        var sleeping = UsageReducer(at: moment(0))
        sleeping.observe(first, at: moment(0))
        sleeping.setConditions(UsageConditions(sleeping: true), at: moment(30))
        // The production continuous clock advances through the one-hour sleep.
        let woke = moment(3630)
        sleeping.setConditions(UsageConditions(), at: woke)
        sleeping.observe(first, at: woke)
        let sleepSpans = sleeping.checkpoint(at: moment(3660))
        let sleepDay = UsageDay.build(intervals: sleepSpans,
                                     range: DateInterval(start: moment(0).date, end: moment(3660).date), until: moment(3660).date)
        suite.expect(sleepDay.away == 3600 && sleepDay.active == 60
                        && sleepDay.entries.filter { $0.state == .sleeping }.count == 1,
                     "a one-hour sleep is recorded as away time without stretching foreground visits across it")
        let sleepClockJump = UsageMoment(date: moment(7200).date, uptime: 3661)
        let adjusted = sleeping.checkpoint(at: sleepClockJump)
        suite.expect(adjusted.filter { $0.stream == .foreground }.map(\.duration).reduce(0, +) == 30,
                     "continuous time still excludes a wall-clock correction after wake")

        suite.expect(UsageForeground.documentPath(from: "file:///tmp/Project%20budget.xlsx") == "/tmp/Project budget.xlsx", "document URLs preserve decoded local paths")
        suite.expect(UsageForeground.documentPath(from: "https://example.com/file") == nil && UsageForeground.documentPath(from: "budget.xlsx") == nil, "browser URLs and guessed paths are not stored")
        suite.expect(UsageForeground.documentPath(from: "file://remote-server/doc.xlsx") == nil, "remote document URLs are not misrepresented as local paths")
        documentMetadata(suite)
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
            let visit = UsageInterval(sessionID: session, stream: .foreground, start: moment(0).date,
                                      end: moment(100).date, duration: 100, foreground: first)
            try store.save([interval, visit], session: session, checkpoint: moment(100).date)
            let reopened = try UsageTimelineStore(url: url)
            suite.expect(try Set(reopened.intervals(in: range).map(\.id)) == Set([interval.id, visit.id]), "checkpointed history survives opening another connection")
            let recovered = UsageDay.build(intervals: try reopened.intervals(in: range), range: range, until: moment(200).date)
            suite.expect(recovered.active == 100 && recovered.other[.unrecorded] == 100, "a checkpoint preserves the visit without extending it through downtime")
            try store.delete(in: DateInterval(start: moment(30).date, end: moment(70).date))
            let remaining = try store.intervals(in: range)
            suite.expect(remaining.count == 4 && remaining.map(\.duration).reduce(0, +) == 120, "range deletion preserves both streams on both sides")
            suite.expect(remaining.allSatisfy { $0.end <= moment(30).date || $0.start >= moment(70).date }, "deleted time cannot remain in crossing spans")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let directory = try FileManager.default.attributesOfItem(atPath: temporary.path)
            suite.expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 && (directory[.posixPermissions] as? NSNumber)?.intValue == 0o700, "database and directory are owner-only")
            try store.delete(in: nil)
            suite.expect(try store.intervals(in: range).isEmpty, "delete all removes persisted intervals")
            try store.save([interval, visit], session: session, checkpoint: moment(100).date)
            var handle: OpaquePointer?
            sqlite3_open(url.path, &handle)
            sqlite3_exec(handle, "PRAGMA user_version=999", nil, nil, nil)
            sqlite3_close(handle)
            do {
                _ = try UsageTimelineStore(url: url)
                suite.expect(false, "unsupported schemas must be rejected")
            } catch UsageTimelineStore.Failure.unsupportedVersion {
                suite.expect(FileManager.default.fileExists(atPath: url.path), "unsupported databases remain intact")
                suite.expect(try reopened.intervals(in: range).count == 2, "unsupported schemas preserve existing activity records")
            }
        } catch {
            suite.expect(false, "usage timeline storage fixture failed: \(error)")
        }
    }

    private static func documentMetadata(_ suite: TestSuite) {
        let presentation = URL(fileURLWithPath: "/Users/test/Downloads/Quarterly review (1).pptx")
        suite.expect(UsageForeground.documentPath(from: presentation) == presentation.path,
                     "URL-valued Office accessibility attributes preserve the actual document path")
        suite.expect(UsageForeground.documentPath(from: presentation as NSURL) == presentation.path,
                     "NSURL-valued document metadata bridges to a local path")
        suite.expect(UsageForeground.documentPath(from: "/tmp/Revenue 100%20.xlsx") == "/tmp/Revenue 100%20.xlsx",
                     "explicit absolute paths retain literal percent characters instead of decoding them as URLs")
        suite.expect(UsageForeground.documentPath(from: URL(string: "https://example.com/report.pptx")!) == nil
                     && UsageForeground.documentPath(from: "file:report.pptx") == nil
                     && UsageForeground.documentPath(from: 42) == nil,
                     "web URLs, relative file URLs and malformed AX values cannot become local document paths")
        var urlReads = 0
        let primary = UsageFocusSupport.documentPath(document: { presentation.absoluteString }, url: {
            urlReads += 1
            return URL(fileURLWithPath: "/tmp/other.pptx")
        })
        suite.expect(primary == presentation.path && urlReads == 0,
                     "an explicit AXDocument path takes priority without reading another attribute")
        suite.expect(UsageFocusSupport.documentPath(document: { nil }, url: { presentation }) == presentation.path,
                     "PowerPoint paths are recovered from AXURL when AXDocument is unavailable")
        suite.expect(UsageFocusSupport.documentPath(document: { "https://example.com" }, url: { presentation }) == presentation.path,
                     "an unusable AXDocument value does not suppress a valid local AXURL")
        suite.expect(UsageFocusSupport.documentPath(document: { nil }, url: { nil }) == nil,
                     "unsaved documents remain pathless instead of inventing a filename")

        func resolve(focused: Int? = nil, main: Int? = nil, windows: [Int] = [],
                     focusedFlags: Set<Int> = [], mainFlags: Set<Int> = [], minimized: Set<Int> = []) -> Int? {
            UsageFocusSupport.window(focused: { focused }, main: { main }, windows: { windows },
                                     isFocused: { focusedFlags.contains($0) }, isMain: { mainFlags.contains($0) },
                                     isMinimized: { minimized.contains($0) })
        }
        suite.expect(resolve(focused: 1, main: 2, windows: [2, 3]) == 1,
                     "the focused document wins even when another Office document is the main window")
        suite.expect(resolve(main: 2, windows: [1, 2]) == 2,
                     "Office can record its main document when AXFocusedWindow is unanswered")
        suite.expect(resolve(windows: [1, 2], focusedFlags: [2], mainFlags: [1]) == 2,
                     "window-list focus flags recover the active document without choosing a different main document")
        suite.expect(resolve(windows: [1, 2], mainFlags: [2]) == 2,
                     "the window-list main flag supplies the document when direct window attributes are missing")
        suite.expect(resolve(windows: [1]) == 1 && resolve(windows: [1, 2]) == nil && resolve() == nil,
                     "a sole visible window is safe to use, while an ambiguous set of documents remains unresolved")
        suite.expect(resolve(main: 1, windows: [1, 2], minimized: [1]) == 2
                     && resolve(windows: [1], minimized: [1]) == nil,
                     "minimized documents are not mistaken for active work")
        var otherReads = 0
        let focused = UsageFocusSupport.window(focused: { 1 }, main: { otherReads += 1; return 2 },
                                               windows: { otherReads += 1; return [3] },
                                               isFocused: { _ in false }, isMain: { _ in false }, isMinimized: { _ in false })
        suite.expect(focused == 1 && otherReads == 0,
                     "a successful focused-window read avoids extra cross-process fallback calls")
    }
}
