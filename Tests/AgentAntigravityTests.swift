// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum AgentAntigravityTests {
    static func run(_ suite: TestSuite) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        func bucket(_ id: String, _ window: String, _ fraction: Any) -> [String: Any] {
            ["bucketId": id, "window": window, "remainingFraction": fraction, "resetTime": reset]
        }
        func payload(_ buckets: [[String: Any]]) -> Data {
            try! JSONSerialization.data(withJSONObject: ["response": ["groups": [["buckets": buckets]]]])
        }
        let data = payload([bucket("gemini-5h", "5h", 0.75), bucket("gemini-weekly", "weekly", 0.25),
                            bucket("3p-5h", "5h", 0), bucket("3p-weekly", "weekly", 1)])
        let reading = AgentAntigravityUsage.decode(data, observedAt: now)
        suite.expect(reading.count == 2 && reading[.gemini]?.windows.count == 2 && reading[.agy]?.windows.count == 2,
                     "both independent quota pools decode from one response")
        suite.expect(reading[.gemini]?.windows.first?.usedPercent == 25 && reading[.agy]?.windows.first?.usedPercent == 100,
                     "remaining fractions convert to usage without mixing provider pools")
        suite.expect(reading[.agy]?.windows.last?.usedPercent == 0 && reading[.gemini]?.source == .account,
                     "a real full allowance and archive-compatible source are preserved")
        suite.expect(reading[.gemini]?.observedAt == now && reading[.gemini]?.windows.first?.minutes == 300,
                     "observation time and five-hour duration are preserved")
        for invalid: Any in [-0.1, 1.1, true, "0.75", NSNull()] {
            suite.expect(AgentAntigravityUsage.decode(payload([bucket("gemini-5h", "5h", invalid)]), observedAt: now).isEmpty,
                         "invalid fraction has no invented percentage: \(invalid)")
        }
        var missing = bucket("gemini-5h", "5h", 0.5)
        missing.removeValue(forKey: "remainingFraction")
        missing["remainingAmount"] = 10
        suite.expect(AgentAntigravityUsage.decode(payload([missing]), observedAt: now).isEmpty,
                     "an absolute amount or absent fraction does not imply a quota")
        suite.expect(AgentAntigravityUsage.decode(payload([bucket("unknown", "5h", 0.5), bucket("gemini-5h", "weekly", 0.5)]), observedAt: now).isEmpty,
                     "unknown buckets and mismatched windows are ignored")
        suite.expect(AgentAntigravityUsage.decode(payload([bucket("gemini-5h", "5h", 0.5), bucket("gemini-5h", "5h", 0.9)]), observedAt: now).isEmpty,
                     "conflicting duplicate IDs never silently select an allowance")
        let object = try! JSONSerialization.jsonObject(with: data)
        let cache = try! JSONSerialization.data(withJSONObject: ["fetched_at": now.timeIntervalSince1970 - 3600, "raw_response": object])
        let cached = AgentAntigravityUsage.cached(cache, now: now)
        suite.expect(cached[.gemini]?.observedAt == now.addingTimeInterval(-3600),
                     "cache reads do not refresh the observation timestamp")
        let fallback = AgentAntigravityUsage.resolved(.init(limits: cached, state: .cached), previous: reading)
        suite.expect(fallback.limits == reading && fallback.state == .cached,
                     "an older disk cache cannot replace newer archived account readings")
        suite.expect(AgentAntigravityUsage.resolved(.init(limits: [:], state: .unavailable), previous: reading).limits == reading,
                     "an unreachable server and missing disk cache retain archived quotas")
        let partialLive = AgentAntigravityUsage.resolved(.init(limits: [.gemini: reading[.gemini]!], state: .live), previous: reading)
        suite.expect(partialLive.limits[.agy] == nil, "live readings never mix a missing pool with an older account observation")
        let future = try! JSONSerialization.data(withJSONObject: ["fetched_at": now.timeIntervalSince1970 + 3600, "raw_response": object])
        suite.expect(AgentAntigravityUsage.cached(future, now: now).isEmpty, "future-dated cache is rejected")

        let expired = now.addingTimeInterval(3601)
        suite.expect(AgentLimitSupport.displayWindows(reading[.gemini], now: expired).isEmpty
                     && AgentLimitSupport.binding(reading[.agy], now: expired) == nil,
                     "expired quotas never become a fabricated full allowance")
        var snapshot = AgentUsageSnapshot()
        snapshot.limits = reading
        for focus in NotchAgentLimitFocus.allCases {
            suite.expect(NotchAgentSupport.restingLimit(snapshot, focus: focus, now: expired) == nil,
                         "closed island also waits for a confirmed renewal")
        }
        let old = reading[.gemini]!
        let codex = AgentLimits(provider: .codex, windows: old.windows, observedAt: now, source: .sessionLog)
        suite.expect(AgentLimitSupport.displayWindows(codex, now: expired).first?.usedPercent == 0,
                     "existing log-provider reset behavior is unchanged")

        let executable = "/Applications/Antigravity Preview.app/Contents/Resources/language_server"
        let processText = "42 \(executable) --csrf_token fixture-token-123 --other value\n"
        let servers = AgentAntigravityUsage.servers(processText + "43 /Applications/Other.app/language_server --csrf_token fixture-token-123\n")
        suite.expect(servers.count == 1 && servers.first?.executable == executable && servers.first?.pid == 42,
                     "discovery preserves paths containing spaces and excludes unrelated servers")
        suite.expect(AgentAntigravityUsage.servers("42 \(executable) --csrf_token=fixture-token-123").count == 1,
                     "equals-form token flag is supported")
        let listeners = AgentAntigravityUsage.listeners("p42\nn127.0.0.1:12345\nn[::1]:23456\nn*:34567\nn192.0.2.1:12345\nn127.0.0.1:99999")
        suite.expect(listeners.map(\.port) == [12345, 23456], "only valid numeric loopback listeners are probed")

        let domain = "com.vorssaint.tests.antigravity"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        suite.expect(NotchAgentSupport.providers(in: defaults) == [.claude, .codex, .opencode, .copilot],
                     "missing preference keys leave new providers off")
        defaults.set(true, forKey: DefaultsKey.notchAgentsGemini)
        suite.expect(NotchAgentSupport.providers(in: defaults).contains(.gemini), "Gemini can be explicitly enabled")
        suite.expect(Defaults.registeredDefaults[DefaultsKey.notchAgentsGemini] as? Bool == false
                     && Defaults.registeredDefaults[DefaultsKey.notchAgentsAgy] as? Bool == false,
                     "registered defaults also leave new providers off")
        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.notchAgentsGemini)
                     && SettingsBackupSupport.exportKeys().contains(DefaultsKey.notchAgentsAgy),
                     "the new toggles participate in settings backups")
        let visible = NotchAgentSupport.visibleProviders(enabled: [.claude, .gemini, .agy, .codex], seen: [.codex])
        suite.expect(visible == [.gemini, .agy, .codex], "quota cards stay visible without changing existing agent visibility")
        suite.expect(visible.filter(\.supportsAnalytics) == [.gemini, .codex], "Gemini supports analytics while AGY remains quota-only")
        suite.expect(NotchAgentSupport.tiles(cards: [.limits, .live, .spend, .resets], providers: [.agy]).map(\.card) == [.limits],
                     "a quota-only page has no fabricated spend/live/reset-credit cards")
        let quotaTiles = NotchAgentSupport.tiles(cards: [.limits], providers:
            NotchAgentSupport.visibleProviders(enabled: [.gemini, .agy], seen: []))
        suite.expect(NotchAgentSupport.contentHeight(NotchAgentSupport.rows(quotaTiles, width: 400)) == NotchAgentSupport.cardHeight,
                     "unavailable quota cards receive a full row in page sizing")
        let mixedTiles = NotchAgentSupport.tiles(cards: [.limits], providers: visible)
        suite.expect(NotchAgentSupport.contentHeight(NotchAgentSupport.rows(mixedTiles, width: 400))
                     == 2 * NotchAgentSupport.cardHeight + NotchAgentSupport.spacing,
                     "mixed unavailable quotas and a known provider receive both rows")
        let summary = AgentUsageSummary.snapshot(records: [], limits: reading, live: [], plans: [:], providers: [.gemini, .agy], now: now)
        suite.expect(summary.usage(.today).total.tokens.total == 0 && summary.usage(.today).total.cost == 0 && summary.live.isEmpty,
                     "quota readings create no tokens, cost or live sessions")
        for language in AppLanguage.allCases {
            let text = NotchAgentQuotaStrings(language: language)
            suite.expect([text.geminiPool, text.agyPool, text.waiting, text.unavailable, text.cached].allSatisfy { !$0.isEmpty },
                         "quota states have text in \(language.rawValue)")
        }
        testGeminiParser(suite, now: now)
        lifecycle(suite, executable: executable, processText: processText, data: data)
    }

    private static func lifecycle(_ suite: TestSuite, executable: String, processText: String, data: Data) {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        let reader = AgentAntigravityReader(systemCommand: { path, args in
            if path.hasSuffix("lsof") { return "p42\nn127.0.0.1:12345\n" }
            return args.contains("comm=") ? executable : processText
        }, fetch: { _, _, _, _ in
            started.signal()
            _ = release.wait(timeout: .now() + 2)
            return data
        })
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        reader.read(home: home) { _ in delivered.signal() }
        suite.expect(started.wait(timeout: .now() + 2) == .success, "quota fetch begins off the caller thread")
        reader.cancel()
        release.signal()
        suite.expect(delivered.wait(timeout: .now() + 0.2) == .timedOut, "cancelling drops an in-flight response")
        release.signal()
        reader.read(home: home) { result in
            if result.state == .live && result.limits.count == 2 { delivered.signal() }
        }
        suite.expect(delivered.wait(timeout: .now() + 2) == .success, "a new request can run after cancellation")
        reader.cancel()
    }

    private static func testGeminiParser(_ suite: TestSuite, now: Date) {
        var state = AgentLogState()
        state.session = "test-session-123"

        // 1. User input starts a turn and detects workspace
        let userInput = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-15T09:31:59Z","content":"Command Working Directory: /Users/test/Code/my-app\\n<USER_SETTINGS_CHANGE>\\nThe user changed setting `Model Selection` from None to Gemini 3.8 Flash (High).\\n</USER_SETTINGS_CHANGE>"}
        """.data(using: .utf8)!
        let userEntries = AgentLogParser.parseGemini(userInput, state: &state, now: now)
        suite.expect(state.turnOpen, "user input opens turn")
        suite.expect(state.project == "my-app", "project is extracted from workspace")
        suite.expect(state.model == "gemini-3.8-flash", "model selection is parsed")
        suite.expect(userEntries.contains(where: { if case .turnBegan = $0 { return true }; return false }), "turn began is emitted")

        // 2. Planner response with tool calls keeps turn active and records usage
        let toolCallStep = """
        {"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-15T09:32:00Z","input_tokens":1000,"cache_read_tokens":500,"output_tokens":200,"tool_calls":[{"name":"run_command","args":{"Cwd":"/Users/test/Code/my-app"}}]}
        """.data(using: .utf8)!
        let toolEntries = AgentLogParser.parseGemini(toolCallStep, state: &state, now: now)
        suite.expect(state.turnOpen, "turn stays open during tool calls")
        suite.expect(toolEntries.contains(where: { if case .turnActive = $0 { return true }; return false }), "turn active is emitted")
        let usage = toolEntries.compactMap { entry -> AgentUsageRecord? in
            if case .usage(_, let record, _) = entry { return record }
            return nil
        }.first
        suite.expect(usage != nil && usage?.tokens.input == 1000 && usage?.tokens.cacheRead == 500 && usage?.tokens.output == 200,
                     "tokens are captured in usage record")
        suite.expect((usage?.cost ?? 0) > 0, "Gemini token cost is priced")

        // 2b. Planner response with ask_question tool call emits turnWaitingInput and updates live session
        let askQuestionStep = """
        {"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-15T09:32:02Z","input_tokens":500,"output_tokens":100,"tool_calls":[{"name":"ask_question","args":{"questions":[{"question":"Which database mode?","options":["A","B"]}]}}]}
        """.data(using: .utf8)!
        let askEntries = AgentLogParser.parseGemini(askQuestionStep, state: &state, now: now)
        let waiting = askEntries.compactMap { entry -> String? in
            if case .turnWaitingInput(_, let prompt) = entry { return prompt }
            return nil
        }.first
        suite.expect(waiting == "Which database mode?", "ask_question emits turnWaitingInput with the question prompt")

        let store = AgentUsageStore()
        store.reportsTransitions = true
        var events = store.apply(userEntries, file: "/brain/s1/transcript.jsonl", provider: .gemini, tracksTurns: true, modified: now)
        suite.expect(store.turns["/brain/s1/transcript.jsonl"]?.isWaitingForInput == false, "turn starts not waiting")
        events = store.apply(askEntries, file: "/brain/s1/transcript.jsonl", provider: .gemini, tracksTurns: true, modified: now)
        suite.expect(store.turns["/brain/s1/transcript.jsonl"]?.isWaitingForInput == true, "turn enters waiting for input state")
        suite.expect(store.turns["/brain/s1/transcript.jsonl"]?.inputPrompt == "Which database mode?", "input prompt is recorded")
        suite.expect(events == [.inputRequired(provider: .gemini, project: "my-app", prompt: "Which database mode?")],
                     "store reports inputRequired event on question")

        for type in ["EPHEMERAL_MESSAGE", "GENERIC"] {
            let heartbeat = "{\"type\":\"\(type)\",\"created_at\":\"2026-10-15T09:32:03Z\"}".data(using: .utf8)!
            let entries = AgentLogParser.parseGemini(heartbeat, state: &state, now: now)
            let events = store.apply(entries, file: "/brain/s1/transcript.jsonl", provider: .gemini,
                                     tracksTurns: true, modified: now)
            suite.expect(store.turns["/brain/s1/transcript.jsonl"]?.isWaitingForInput == true
                            && store.turns["/brain/s1/transcript.jsonl"]?.inputPrompt == waiting && events.isEmpty,
                         "\(type) preserves the unanswered question without repeating the alert")
            suite.expect(store.turns["/brain/s1/transcript.jsonl"]?.lastActivity == AgentLogParser.timestamp("2026-10-15T09:32:03Z"),
                         "\(type) still refreshes the turn's activity")
        }

        for questions: Any in [
            [["question": "Which database mode?"], ["question": "Keep the backup?"]],
            #"[{"question":"Which database mode?"},{"question":"Keep the backup?"}]"#
        ] {
            let step = try! JSONSerialization.data(withJSONObject: ["type": "PLANNER_RESPONSE", "tool_calls": [
                ["name": "ask_question", "args": ["questions": questions]]
            ]])
            let entries = AgentLogParser.parseGemini(step, state: &state, now: now)
            suite.expect(entries.contains(.turnWaitingInput(now, prompt: "Which database mode?\nKeep the backup?")),
                         "Gemini decodes every question from arrays and serialized JSON")
        }
        let malformed = #"{"type":"PLANNER_RESPONSE","tool_calls":[{"name":"ask_question","args":{"questions":"invalid JSON"}}]}"#.data(using: .utf8)!
        suite.expect(AgentLogParser.parseGemini(malformed, state: &state, now: now)
                        .contains(.turnWaitingInput(now, prompt: "Question")),
                     "an unreadable Gemini question still marks the turn as needing input")

        let questionTime = store.turns["/brain/s1/transcript.jsonl"]!.lastActivity
        store.closeIdleTurns(now: questionTime.addingTimeInterval(NotchAgentSupport.idleTurn + 1),
                             after: NotchAgentSupport.idleTurn)
        suite.expect(store.live.first?.isWaitingForInput == true,
                     "an unanswered question remains visible past the ordinary idle timeout")

        // Responding with user input clears the waiting state
        let nextUserInput = """
        {"step_index":4,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-15T09:32:04Z","content":"Option A"}
        """.data(using: .utf8)!
        let resumeEntries = AgentLogParser.parseGemini(nextUserInput, state: &state, now: now)
        _ = store.apply(resumeEntries, file: "/brain/s1/transcript.jsonl", provider: .gemini, tracksTurns: true, modified: now)
        suite.expect(store.turns["/brain/s1/transcript.jsonl"]?.isWaitingForInput == false, "answering clears waiting for input")
        suite.expect(store.turns["/brain/s1/transcript.jsonl"]?.inputPrompt == nil, "answering clears input prompt")

        let abandoned = AgentUsageStore()
        abandoned.apply([.turnWaitingInput(now, prompt: "Continue?")], file: "abandoned", provider: .gemini,
                        tracksTurns: true, modified: now)
        abandoned.closeIdleTurns(now: now.addingTimeInterval(AgentUsageStore.resumeWindow(for: .gemini)),
                                 after: NotchAgentSupport.idleTurn)
        suite.expect(abandoned.live.isEmpty && abandoned.waiting.isEmpty,
                     "abandoned questions still age out after the provider's resume window")

        // 3. Final response without tool calls ends turn
        let finalStep = """
        {"step_index":5,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-15T09:32:05Z","input_tokens":1200,"cache_read_tokens":600,"output_tokens":400,"tool_calls":[]}
        """.data(using: .utf8)!
        let finalEntries = AgentLogParser.parseGemini(finalStep, state: &state, now: now)
        suite.expect(!state.turnOpen, "final response closes turn")
        suite.expect(finalEntries.contains(where: { if case .turnEnded(_, let completed, _) = $0 { return completed }; return false }),
                     "turn ended is emitted as completed")

        // 4. Log root and cursor init
        let roots = AgentLogRoot.all(home: URL(fileURLWithPath: "/Users/test"))
        let geminiRoot = roots.first { $0.provider == .gemini }
        suite.expect(geminiRoot != nil, "Gemini log root is registered")
        suite.expect(geminiRoot?.accepts("/Users/test/.gemini/antigravity-cli/brain/uuid-1/transcript.jsonl") == true,
                     "Gemini root accepts transcript.jsonl")
        suite.expect(geminiRoot?.accepts("/Users/test/.gemini/antigravity-cli/brain/uuid-1/transcript_full.jsonl") == false,
                     "Gemini root ignores transcript_full.jsonl")

        let cursor = AgentLogCursor(path: "/Users/test/.gemini/antigravity-cli/brain/session-xyz/.system_generated/logs/transcript.jsonl", provider: .gemini)
        suite.expect(cursor.state.session == "session-xyz", "session ID is extracted from path")

        // 5. Pricing and display names
        suite.expect(AgentPricing.displayName("gemini-3.8-flash") == "Gemini 3.8 Flash", "displayName formats 3.8 Flash")
        suite.expect(AgentPricing.displayName("gemini-2.5-pro") == "Gemini 2.5 Pro", "displayName formats 2.5 Pro")
        suite.expect(AgentPricing.price(for: "gemini-2.5-pro") != nil, "pricing known for gemini-2.5-pro")
        suite.expect(AgentPricing.price(for: "gemini-3.8-flash") != nil, "pricing known for gemini-3.8-flash")
    }
}
