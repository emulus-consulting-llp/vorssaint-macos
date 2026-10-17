// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

typealias AgentUsageProductionLogReader = AgentLogReader
typealias AgentUsageReadProductionArchive = AgentUsageArchive

/// Runs the service's production startup/read methods, parser, cursor and store. The
/// reader wrapper only observes when a complete line is handed to the service.
enum AgentUsageReadTests {
    enum AgentLogReader {
        static var beforeLine: (() -> Void)?
        static func isLog(_ path: String) -> Bool { AgentUsageProductionLogReader.isLog(path) }
        static func discover(_ roots: [AgentLogRoot], since horizon: Date) -> [(path: String, provider: AgentProvider)] {
            AgentUsageProductionLogReader.discover(roots, since: horizon)
        }
        static func copilotHistoryLine(_ buffer: Data, range: Range<Int>) -> Bool {
            AgentUsageProductionLogReader.copilotHistoryLine(buffer, range: range)
        }
        static func readCopilotHistory(_ cursor: AgentLogCursor, shouldContinue: () -> Bool,
                                       line: (Data) -> Void) {
            AgentUsageProductionLogReader.readCopilotHistory(cursor, shouldContinue: shouldContinue) {
                beforeLine?()
                line($0)
            }
        }
        static func readAppended(_ cursor: AgentLogCursor, since horizon: Date = .distantPast, shouldContinue: () -> Bool,
                                 including: ((Data, Range<Int>) -> Bool)? = nil,
                                 line: (Data) -> Void) {
            AgentUsageProductionLogReader.readAppended(cursor, since: horizon, shouldContinue: shouldContinue,
                                                        including: including) {
                beforeLine?()
                line($0)
            }
        }
    }

    enum AgentUsageArchive {
        static func load() -> AgentUsageReadProductionArchive.Contents? { nil }
        static func resume(_ contents: AgentUsageReadProductionArchive.Contents, logs: Set<String>, since horizon: Date)
            -> (store: AgentUsageStore, cursors: [String: AgentLogCursor], unchanged: Bool) {
            AgentUsageReadProductionArchive.resume(contents, logs: logs, since: horizon)
        }
    }

    final class Cancellation {
        var isCancelled = false
    }

    /// Run startup's serial work inline so every delivered line can inspect
    /// publication state, without timers, file watchers or main-queue races.
    struct Queue {
        func async(execute work: () -> Void) { work() }
    }

    enum NotchAgentSupport {
        static let idleTurn: TimeInterval = 120
        static func dailyBudget() -> Double? { nil }
    }

    class Fixture {
        static let horizon = TimeInterval(AgentUsageSnapshot.dayCount) * 86_400
        let queue = Queue()
        var home = FileManager.default.temporaryDirectory
        var readerSession = 1
        var watchedRoots: [AgentLogRoot] = []
        var readerCancellation: Cancellation? = Cancellation()
        var cursors: [String: AgentLogCursor] = [:]
        var store = AgentUsageStore()
        var enabled: Set<AgentProvider> = []
        var previousLimits: [AgentProvider: AgentLimits] = [:]
        var budgetDay: Date?
        var snapshot = AgentUsageSnapshot()
        var publications: [AgentUsageSnapshot] = []
        var events: [AgentUsageEvent] = []
        var savedMark: Int?
        var codexBudget = AgentCodexSessionBudget()
        var savedCodexBudget: AgentCodexSessionBudget?
        var initialCodexReadings: [AgentLimits]?
        var progressMark: Int { 0 }
        func saveProgress() {}
        func startTimer() {}
        func loadPrices() {}
        func closeEndedTurns(_ roots: [AgentLogRoot], atLaunch: Bool) {}
        func readClaudePlan() {}
        func readClaudeApp(now: Date) {}
        func watch(_ roots: [AgentLogRoot]) { watchedRoots = roots }
        func startPolling() {}
        func syncPolling() {}
        func watchNetwork() {}
        func publish() {
            snapshot = store.snapshot(plans: [:], providers: enabled, now: Date())
            publications.append(snapshot)
        }
        func report(_ event: AgentUsageEvent) { events.append(event) }
        func checkLimits() {}
        func schedulePublish() {}
    }

    static func run(_ suite: TestSuite) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "vorss-streaming-\(UUID().uuidString)")
        defer {
            AgentLogReader.beforeLine = nil
            try? FileManager.default.removeItem(at: folder)
        }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { suite.expect(false, "the streaming fixture creates its folder: \(error)"); return }
        let now = Date()
        let timestamp = now.timeIntervalSince1970
        let geminiHost = Host()
        var geminiFiles: [URL] = []
        for (session, input) in [("one", 10), ("two", 20)] {
            let file = folder.appending(path: "brain/\(session)/transcript.jsonl")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let step = #"{"type":"PLANNER_RESPONSE","step_index":2,"input_tokens":\#(input),"tool_calls":[]}"#
            try? Data((step + "\n").utf8).write(to: file)
            geminiFiles.append(file)
            geminiHost.read(file.path, provider: .gemini)
        }
        suite.expect(geminiHost.store.records.count == 2 && geminiHost.store.records.reduce(0) { $0 + $1.tokens.input } == 30
                        && Set(geminiHost.store.records.map(\.session)) == ["one", "two"],
                     "first Gemini reads retain path-derived session IDs and never merge unrelated steps")
        for file in geminiFiles {
            let cursor = geminiHost.cursors[file.path]!
            cursor.startOver(identity: 0)
            geminiHost.read(file.path, provider: .gemini)
        }
        suite.expect(geminiHost.store.records.count == 2 && geminiHost.store.records.reduce(0) { $0 + $1.tokens.input } == 30,
                     "Gemini cursor resets keep usage keys stable without duplicate or cross-session accounting")
        let cases: [(AgentProvider, [String])] = [
            (.claude, [
                #"{"type":"user","timestamp":\#(timestamp),"sessionId":"s","message":{"content":"work"}}"#,
                #"{"type":"assistant","timestamp":\#(timestamp),"sessionId":"s","requestId":"r","message":{"id":"m","model":"claude-opus-5-5","stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":2}}}"#,
                #"{"type":"assistant","timestamp":\#(timestamp),"sessionId":"s","requestId":"r","message":{"id":"m","model":"claude-opus-5-5","stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5}}}"#,
                #"{"type":"assistant","timestamp":\#(timestamp),"sessionId":"s","requestId":"r2","message":{"id":"m2","model":"claude-opus-5-5","stop_reason":"end_turn","usage":{"input_tokens":3,"output_tokens":7}}}"#
            ]),
            (.codex, [
                #"{"type":"session_meta","timestamp":\#(timestamp),"payload":{"id":"s","cwd":"/tmp/example"}}"#,
                #"{"type":"turn_context","timestamp":\#(timestamp),"payload":{"model":"gpt-5.2-codex"}}"#,
                #"{"type":"event_msg","timestamp":\#(timestamp),"payload":{"type":"task_started"}}"#,
                #"{"type":"token_usage_record","timestamp":\#(timestamp),"payload":{"response_id":"r","usage":{"input_tokens":10,"output_tokens":2}}}"#,
                #"{"type":"token_usage_record","timestamp":\#(timestamp),"payload":{"response_id":"r","usage":{"input_tokens":10,"output_tokens":5}}}"#,
                #"{"type":"event_msg","timestamp":\#(timestamp),"payload":{"type":"token_count","rate_limits":{"plan_type":"pro","primary":{"used_percent":42,"window_minutes":300}}}}"#,
                #"{"type":"event_msg","timestamp":\#(timestamp),"payload":{"type":"task_complete","duration_ms":20000}}"#
            ]),
            (.copilot, [
                #"{"id":"start","timestamp":\#(timestamp),"type":"session.start","data":{"sessionId":"s","selectedModel":"gpt-6-sol","context":{"cwd":"/tmp/example"}}}"#,
                #"{"id":"turn","timestamp":\#(timestamp),"type":"user.message","data":{"turnId":"0","content":"private"}}"#,
                #"{"id":"message","timestamp":\#(timestamp),"type":"assistant.message","data":{"model":"gpt-6-sol","content":"private"}}"#,
                #"{"id":"checkpoint","timestamp":\#(timestamp),"type":"session.usage_checkpoint","data":{"totalPremiumRequests":1}}"#,
                #"{"id":"end","timestamp":\#(timestamp),"type":"assistant.turn_end","data":{"turnId":"0"}}"#,
                #"{"id":"usage","timestamp":\#(timestamp),"type":"session.shutdown","data":{"modelMetrics":{"gpt-6-sol":{"requests":{"count":1},"tokenDetails":{"input":{"tokenCount":10},"cache_read":{"tokenCount":20},"cache_write":{"tokenCount":0},"output":{"tokenCount":5}},"usage":{"reasoningTokens":2}}}}}"#,
                #"{"id":"final-checkpoint","timestamp":\#(timestamp),"type":"session.usage_checkpoint","data":{}}"#
            ])
        ]
        for (provider, lines) in cases {
            // A canonical filename, not a Codex side-thread filename.
            let file = folder.appending(path: "\(provider.rawValue).jsonl")
            do { try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file) }
            catch { suite.expect(false, "the streaming fixture writes its log: \(error)"); continue }

            let cursor = AgentLogCursor(path: file.path, provider: provider)
            var entries: [AgentLogEntry] = []
            let consume: (Data) -> Void = { line in
                switch provider {
                case .claude: entries += AgentLogParser.parseClaude(line, state: &cursor.state, now: now)
                case .codex: entries += AgentLogParser.parseCodex(line, state: &cursor.state, now: now)
                case .opencode: entries += AgentLogParser.parseOpenCode(line, state: &cursor.state, now: now)
                case .copilot: entries += AgentLogParser.parseCopilot(line, state: &cursor.state, now: now)
                case .gemini, .agy: break
                }
            }
            if provider == .copilot {
                AgentUsageProductionLogReader.readCopilotHistory(cursor, line: consume)
            } else {
                AgentUsageProductionLogReader.readAppended(cursor, line: consume)
            }
            let reference = AgentUsageStore()
            reference.reportsTransitions = true
            let expectedEvents = reference.apply(entries, file: file.path, provider: provider,
                                                 tracksTurns: cursor.tracksTurns, parent: cursor.parent,
                                                 modified: cursor.modified, now: now)
            let host = Host()
            host.store.reportsTransitions = true
            var counts: [Int] = []
            AgentLogReader.beforeLine = { counts.append(host.store.records.count) }
            suite.expect(host.read(file.path, provider: provider), "a \(provider.rawValue) log reports parsed entries")
            AgentLogReader.beforeLine = nil
            suite.expect(counts.contains(where: { $0 > 0 }),
                         "\(provider.rawValue) records are applied before the rest of the log is read")
            suite.expect(host.store.records == reference.records && host.store.turns == reference.turns
                            && host.store.waiting == reference.waiting && host.store.limits == reference.limits
                            && host.store.codexPlan == reference.codexPlan && host.events == expectedEvents,
                         "streaming \(provider.rawValue) preserves duplicate merging, usage, turns, limits, plans and event order")
            suite.expect((provider == .copilot || !expectedEvents.isEmpty)
                            && host.cursors[file.path]?.state == cursor.state,
                         "\(provider.rawValue) retains the same parser context without replaying historical finishes")
            suite.expect(!host.read(file.path, provider: provider) && host.events == expectedEvents,
                         "an unchanged \(provider.rawValue) file neither changes the store nor replays events")
            host.readerCancellation?.isCancelled = true
            suite.expect(!host.read(file.path, provider: provider), "a cancelled reading consumes no more entries")
        }
        startup(suite, folder: folder.appending(path: "home"), cases: cases)
        budgetStartup(suite, folder: folder.appending(path: "budget-home"))

        let openFile = folder.appending(path: "copilot-open.jsonl")
        let openLines = [
            #"{"id":"start","timestamp":"2026-09-27T15:00:00.000Z","type":"session.start","data":{"sessionId":"open","selectedModel":"gpt-6-sol","context":{"cwd":"/tmp/open-project"}}}"#,
            #"{"id":"turn","timestamp":"2026-09-27T15:01:00.000Z","type":"user.message","data":{"content":"still working"}}"#,
            #"{"id":"iteration","timestamp":"2026-09-27T15:01:01.000Z","type":"assistant.turn_start","data":{"turnId":"0"}}"#,
            #"{"id":"reply","timestamp":"2026-09-27T15:01:30.000Z","type":"assistant.message","data":{"model":"gpt-6-sol","content":"in progress","toolRequests":[{"name":"read_file","toolCallId":"tool"}]}}"#,
            #"{"id":"checkpoint","timestamp":"2026-09-27T15:01:45.000Z","type":"session.usage_checkpoint","data":{"totalPremiumRequests":0}}"#,
            #"{"id":"intermediate-end","timestamp":"2026-09-27T15:01:46.000Z","type":"assistant.turn_end","data":{"turnId":"0"}}"#,
            #"{"id":"next-iteration","timestamp":"2026-09-27T15:01:47.000Z","type":"assistant.turn_start","data":{"turnId":"1"}}"#
        ]
        try? Data((openLines.joined(separator: "\n") + "\n").utf8).write(to: openFile)
        let openHost = Host()
        suite.expect(openHost.read(openFile.path, provider: .copilot)
                        && openHost.store.turns[openFile.path]?.project == "open-project"
                        && openHost.store.turns[openFile.path]?.model == "gpt-6-sol"
                        && openHost.cursors[openFile.path]?.state.turnOpen == true
                        && openHost.store.records.count == 1,
                     "startup restores ongoing Copilot work after a checkpoint and an intermediate tool turn-end")
        if let handle = try? FileHandle(forWritingTo: openFile) {
            _ = try? handle.seekToEnd()
            let end = [
                #"{"id":"final","timestamp":"2026-09-27T15:01:59.000Z","type":"assistant.message","data":{"content":"done"}}"#,
                #"{"id":"end","timestamp":"2026-09-27T15:02:00.000Z","type":"assistant.turn_end","data":{"turnId":"1"}}"#
            ]
            try? handle.write(contentsOf: Data((end.joined(separator: "\n") + "\n").utf8))
            try? handle.close()
        }
        openHost.store.reportsTransitions = true
        suite.expect(openHost.read(openFile.path, provider: .copilot)
                        && openHost.cursors[openFile.path]?.state.turnOpen == false
                        && openHost.store.turns[openFile.path] == nil,
                     "the restored Copilot turn finishes when its root assistant turn-end arrives")

        // Exercise the production watcher callback, not only discovery.
        let root = folder.appending(path: "session-state")
        let session = root.appending(path: "demo")
        let workspace = session.appending(path: "workspace/nested")
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let real = session.appending(path: "events.jsonl")
        let nested = workspace.appending(path: "events.jsonl")
        let arbitrary = session.appending(path: "data.jsonl")
        let bytes = Data((openLines.joined(separator: "\n") + "\n").utf8)
        for file in [real, nested, arbitrary] { try? bytes.write(to: file) }
        let watcher = Host()
        watcher.watchedRoots = [AgentLogRoot(provider: .copilot, url: root)]
        watcher.filesChanged([nested.path, arbitrary.path, real.path], rescan: false)
        suite.expect(Set(watcher.cursors.keys) == [real.path] && watcher.store.records.count == 1,
                     "Copilot file watching admits only each session's event log and never its workspace JSONL")
        watcher.filesChanged([], rescan: true)
        suite.expect(Set(watcher.cursors.keys) == [real.path] && watcher.store.records.count == 1,
                     "Copilot rescans use the same path boundary and do not duplicate live activity")
    }

    private static func budgetStartup(_ suite: TestSuite, folder: URL) {
        let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 6 * 3600)
        let root = folder.appending(path: ".codex/sessions")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func reading(_ used: Int, _ seconds: Double) -> String {
            #"{"type":"event_msg","timestamp":\#(start.addingTimeInterval(seconds).timeIntervalSince1970),"payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(used),"window_minutes":10080,"resets_at":\#(start.addingTimeInterval(7 * 86400).timeIntervalSince1970)}}}}"#
        }
        let a = root.appending(path: "a.jsonl"), b = root.appending(path: "b.jsonl")
        try? Data(([reading(0, 0), reading(7, 5 * 3600 + 180)].joined(separator: "\n") + "\n").utf8).write(to: a)
        try? Data(([reading(2, 60), reading(4, 5 * 3600 + 120)].joined(separator: "\n") + "\n").utf8).write(to: b)
        var budgets: [AgentCodexSessionBudget] = []
        for reverse in [false, true] {
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(reverse ? 0 : -10)], ofItemAtPath: a.path)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(reverse ? -10 : 0)], ofItemAtPath: b.path)
            let host = Host()
            host.home = folder
            host.start(session: 1, providers: [.codex], cancellation: Cancellation())
            budgets.append(host.codexBudget)
            suite.expect(host.initialCodexReadings == nil && host.codexBudget.window(now: Date()).usedPercent == 50
                            && host.codexBudget.startedAt == start.addingTimeInterval(5 * 3600 + 120),
                         "production startup replays quotas globally before showing the five-hour budget")
        }
        suite.expect(budgets.first == budgets.last, "swapping Codex file modification order cannot change the initial budget")
    }

    private static func startup(_ suite: TestSuite, folder: URL, cases: [(AgentProvider, [String])]) {
        defer { AgentLogReader.beforeLine = nil }
        for (provider, lines) in cases {
            guard let root = AgentLogRoot.all(home: folder).first(where: { $0.provider == provider }) else {
                suite.expect(false, "the startup fixture has a root for \(provider)")
                return
            }
            let file = root.url.appending(path: "session/events.jsonl")
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
            } catch { suite.expect(false, "the startup fixture writes its log: \(error)"); return }
        }
        let host = Host()
        host.home = folder
        // A changed provider selection resets the displayed snapshot before
        // starting a fresh pass, just as stop()/syncWithPreferences() do.
        for (index, item) in cases.enumerated() {
            let provider = item.0
            host.snapshot = AgentUsageSnapshot()
            host.publications.removeAll()
            var readings: [(loaded: Bool, publications: Int, records: Int)] = []
            AgentLogReader.beforeLine = {
                readings.append((host.snapshot.loaded, host.publications.count, host.store.records.count))
            }
            host.start(session: index + 1, providers: [provider], cancellation: Cancellation())
            suite.expect(!readings.isEmpty && readings.allSatisfy { !$0.loaded && $0.publications == 0 },
                         "\(provider) startup stays in Reading usage until the entire history pass finishes")
            suite.expect(readings.contains { $0.records > 0 },
                         "\(provider) startup still streams records into the store while the page is loading")
            suite.expect(host.publications.count == 1 && host.snapshot.loaded
                            && host.snapshot.seen == [provider] && !host.store.records.isEmpty,
                         "\(provider) startup publishes populated history once, without an empty summary-cache baseline")
        }

        let cancelled = Host()
        cancelled.home = folder
        let cancellation = Cancellation()
        var cancelledDuringRead = false
        AgentLogReader.beforeLine = {
            if !cancelled.store.records.isEmpty {
                cancellation.isCancelled = true
                cancelledDuringRead = true
            }
        }
        cancelled.start(session: 1, providers: [.copilot], cancellation: cancellation)
        suite.expect(cancelledDuringRead && !cancelled.snapshot.loaded && cancelled.publications.isEmpty,
                     "cancelling during the initial pass never publishes partial history as loaded")
        AgentLogReader.beforeLine = nil
        let stopped = Host()
        stopped.home = folder
        stopped.start(session: 2, providers: [.copilot], cancellation: cancellation)
        suite.expect(!stopped.snapshot.loaded && stopped.publications.isEmpty && stopped.store.records.isEmpty,
                     "an already cancelled startup cannot publish an empty loaded snapshot")

        let empty = Host()
        empty.home = folder.appending(path: "empty-home")
        empty.start(session: 1, providers: Set(AgentProvider.allCases), cancellation: Cancellation())
        suite.expect(empty.publications.count == 1 && empty.snapshot.loaded && empty.snapshot.seen.isEmpty,
                     "a completed pass with genuinely no history leaves the loading state")
    }
}
