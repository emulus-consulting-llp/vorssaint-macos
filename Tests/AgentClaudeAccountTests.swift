// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Execute the production account and quota readers against synthetic files.
enum AgentClaudeAccountTests {
    class Fixture {
        var home = FileManager.default.temporaryDirectory
        var enabled: Set<AgentProvider> = [.claude]
        var store = AgentUsageStore()
        var claudeOrganization: String?
        var claudePlan: AgentPlan?
        var claudeProfileModified: Date?
        var claudeAppModified: Date?
        var claudeAppSamples: [AgentClaudeAppUsage.Sample] = []
        var claudeAccountLimits: AgentLimits?
        var claudeStatusLineModified: Date?
        var claudeStatusLineData: Data?
        var claudeStatusLineNotBefore: Date?
        var previousLimits: [AgentProvider: AgentLimits] = [:]
        var warned: [String: (provider: AgentProvider, window: AgentLimitWindow)] = [:]
    }

    static func run(_ suite: TestSuite) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "vorss-account-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = folder.appending(path: ".claude.json")
        let hook = AgentClaudeStatusLineUsage.cacheURL(home: folder)
        let app = AgentClaudeAppUsage.historyURL(home: folder)
        func write(_ json: [String: Any], to url: URL, at offset: Double) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(offset)], ofItemAtPath: url.path)
        }
        func account(_ organization: String) -> [String: Any] {
            ["oauthAccount": ["organizationUuid": organization, "organizationType": "claude_pro"]]
        }
        func quota(_ used: Double, fetched: Double) -> [String: Any] {
            ["fetched_at": now.addingTimeInterval(fetched).timeIntervalSince1970,
             "five_hour": ["used_percentage": used, "resets_at": now.addingTimeInterval(3600).timeIntervalSince1970]]
        }
        do {
            try write(account("old"), to: profile, at: -100)
            try write(quota(93, fetched: -90), to: hook, at: -90)
            try write(["version": 2, "samples": [
                ["t": now.addingTimeInterval(-90).timeIntervalSince1970 * 1000, "org": "old", "u": ["fh": 93]]
            ]], to: app, at: -90)
            let host = Host()
            host.home = folder
            host.readClaudeApp(now: now)
            suite.expect(host.store.limits[.claude]?.windows.first?.usedPercent == 93,
                         "the current account can use its recent Claude hook quota")
            host.previousLimits[.claude] = host.store.limits[.claude]
            host.warned["old-warning"] = (.claude, host.store.limits[.claude]!.windows[0])

            try write(account("new"), to: profile, at: -10)
            host.readClaudeApp(now: now)
            suite.expect(host.claudeOrganization == "new" && host.store.limits[.claude] == nil
                            && host.previousLimits[.claude] == nil && host.warned.isEmpty,
                         "page refresh invalidates retained quotas and alerts immediately on an organization switch")
            suite.expect(host.claudeStatusLineNotBefore == now.addingTimeInterval(-10),
                         "unowned hook readings must be newer than the account change")

            try write(["version": 2, "samples": [
                ["t": now.addingTimeInterval(-50).timeIntervalSince1970 * 1000, "org": "new", "u": ["fh": 20]],
                ["t": now.addingTimeInterval(-20).timeIntervalSince1970 * 1000, "org": "old", "u": ["fh": 99]]
            ]], to: app, at: -5)
            host.readClaudeApp(now: now)
            suite.expect(host.store.limits[.claude]?.windows.first?.usedPercent == 20,
                         "new-account app history is accepted while old-account samples and the pre-switch hook are excluded")
            try write(quota(45, fetched: -5), to: hook, at: -4)
            host.readClaudeApp(now: now)
            suite.expect(host.store.limits[.claude]?.windows.first?.usedPercent == 45,
                         "a newly fetched hook reading becomes eligible after the account switch")
            try write(["fetched_at": now.timeIntervalSince1970, "has_limits": false], to: hook, at: -3)
            try write(account("new"), to: profile, at: -2)
            host.readClaudeApp(now: now)
            suite.expect(host.store.limits[.claude]?.windows.first?.usedPercent == 45,
                         "same-account profile changes and an empty hook render preserve a valid retained quota")
            try write(["oauthAccount": [:]], to: profile, at: -1)
            host.readClaudeApp(now: now)
            suite.expect(host.store.limits[.claude] == nil, "signing out cannot reinstate the previous account's history")

            let fresh = Host()
            fresh.home = folder
            fresh.store.setLimits(AgentLimits(provider: .claude, windows: [
                AgentLimitWindow(id: "archived", kind: .session, minutes: 300, scope: nil, usedPercent: 99,
                                 resetsAt: now.addingTimeInterval(3600))], observedAt: now, source: .claudeApp))
            try write(account("third"), to: profile, at: 0)
            fresh.readClaudeApp(now: now)
            suite.expect(fresh.store.limits[.claude] == nil,
                         "startup cannot attribute archived quotas or a pre-switch hook to a different organization")
        } catch { suite.expect(false, "the Claude account fixture runs: \(error)") }
    }
}
