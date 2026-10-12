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
        suite.expect(visible.filter(\.supportsAnalytics) == [.codex], "quota providers cannot become idle analytics rows")
        suite.expect(NotchAgentSupport.tiles(cards: [.limits, .live, .spend, .resets], providers: [.gemini, .agy]).map(\.card) == [.limits, .limits],
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
}
