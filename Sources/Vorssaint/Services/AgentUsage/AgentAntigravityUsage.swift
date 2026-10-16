// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreFoundation
import Foundation

/// The two allowance pools in Antigravity, not Gemini web subscriptions or usage analytics.
enum AgentAntigravityUsage {
    static let freshness: TimeInterval = 45 * 60
    static let maximumBytes = 1_048_576

    enum State: Equatable { case unavailable, loading, live, cached }

    struct Reading {
        let limits: [AgentProvider: AgentLimits]
        let state: State
    }

    /// A failed refresh must not replace a newer archived observation with an old disk cache.
    /// Select one complete source group, not a mixture of pools from separate observations.
    static func resolved(_ reading: Reading, previous: [AgentProvider: AgentLimits]) -> Reading {
        guard reading.state != .live else { return reading }
        let previous = previous.filter { $0.key == .gemini || $0.key == .agy }
        let oldTime = previous.values.map(\.observedAt).max() ?? .distantPast
        let newTime = reading.limits.values.map(\.observedAt).max() ?? .distantPast
        let selected = oldTime > newTime ? previous : reading.limits
        return Reading(limits: selected, state: selected.isEmpty ? .unavailable : .cached)
    }

    /// Unsupported or incomplete buckets carry no implied allowance. Each pool is independent.
    static func decode(_ data: Data, observedAt: Date) -> [AgentProvider: AgentLimits] {
        guard data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = object["response"] as? [String: Any],
              let groups = response["groups"] as? [[String: Any]] else { return [:] }
        let known: [String: (AgentProvider, AgentLimitWindow.Kind, Int, String)] = [
            "gemini-5h": (.gemini, .session, 300, "5h"),
            "gemini-weekly": (.gemini, .weekly, 10080, "weekly"),
            "3p-5h": (.agy, .session, 300, "5h"),
            "3p-weekly": (.agy, .weekly, 10080, "weekly")
        ]
        var windows: [AgentProvider: [AgentLimitWindow]] = [:]
        var encountered = Set<String>()
        var duplicates = Set<String>()
        let date = ISO8601DateFormatter()
        let fractionalDate = ISO8601DateFormatter()
        fractionalDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for group in groups {
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let id = bucket["bucketId"] as? String, let (provider, kind, minutes, window) = known[id] else { continue }
                guard encountered.insert(id).inserted else { duplicates.insert(id); continue }
                guard bucket["window"] as? String == window,
                      let number = bucket["remainingFraction"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, (0...1).contains(number.doubleValue),
                      let reset = bucket["resetTime"] as? String,
                      let resetsAt = fractionalDate.date(from: reset) ?? date.date(from: reset) else { continue }
                windows[provider, default: []].append(AgentLimitWindow(
                    id: id, kind: kind, minutes: minutes, scope: nil,
                    usedPercent: (1 - number.doubleValue) * 100, resetsAt: resetsAt))
            }
        }
        return windows.reduce(into: [:]) { result, entry in
            let valid = entry.value.filter { !duplicates.contains($0.id) }.sorted { $0.minutes! < $1.minutes! }
            if !valid.isEmpty {
                result[entry.key] = AgentLimits(provider: entry.key, windows: valid,
                                                observedAt: observedAt, source: .account)
            }
        }
    }

    static func cached(_ data: Data, now: Date) -> [AgentProvider: AgentLimits] {
        guard data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stamp = object["fetched_at"] as? NSNumber,
              CFGetTypeID(stamp) != CFBooleanGetTypeID(), stamp.doubleValue.isFinite,
              stamp.doubleValue > 0, stamp.doubleValue <= now.timeIntervalSince1970 + 60,
              let payload = object["raw_response"] as? [String: Any],
              let raw = try? JSONSerialization.data(withJSONObject: payload) else { return [:] }
        return decode(raw, observedAt: Date(timeIntervalSince1970: stamp.doubleValue))
    }

    struct Server: Equatable {
        let pid: Int32
        let executable: String
        let token: String
    }

    /// The executable may contain spaces. Match its terminal basename before parsing flags.
    static func servers(_ output: String) -> [Server] {
        let executable = try! NSRegularExpression(pattern: #"^\s*(\d+)\s+(.*/language_server(?:_macos_arm|_macos)?)\s+(.*)$"#)
        let token = try! NSRegularExpression(pattern: #"(?:^|\s)--csrf_token(?:=|\s+)([A-Za-z0-9_-]{8,256})(?:\s|$)"#)
        return output.split(separator: "\n").compactMap { line in
            let line = String(line)
            guard let match = executable.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let pidRange = Range(match.range(at: 1), in: line), let pid = Int32(line[pidRange]), pid > 0,
                  let pathRange = Range(match.range(at: 2), in: line),
                  let argsRange = Range(match.range(at: 3), in: line) else { return nil }
            let path = String(line[pathRange]), args = String(line[argsRange])
            // Distinguish Antigravity from other products that use the same server name.
            guard path.lowercased().contains("antigravity"),
                  let credential = token.firstMatch(in: args, range: NSRange(args.startIndex..., in: args)),
                  let tokenRange = Range(credential.range(at: 1), in: args) else { return nil }
            return Server(pid: pid, executable: path, token: String(args[tokenRange]))
        }.sorted { $0.pid > $1.pid }
    }

    struct Listener: Equatable {
        let host: String
        let port: Int
    }

    /// Only loopback listeners owned by the selected PID are candidates. Wildcards are excluded.
    static func listeners(_ output: String) -> [Listener] {
        var result: [Listener] = []
        for line in output.split(separator: "\n") {
            let text = String(line)
            let host: String, number: String
            if text.hasPrefix("n127.0.0.1:") { host = "127.0.0.1"; number = String(text.dropFirst(11)) }
            else if text.hasPrefix("n[::1]:") { host = "[::1]"; number = String(text.dropFirst(7)) }
            else { continue }
            guard let port = Int(number), (1...65535).contains(port) else { continue }
            let listener = Listener(host: host, port: port)
            if !result.contains(listener) { result.append(listener) }
        }
        return result.sorted { $0.port == $1.port ? $0.host < $1.host : $0.port < $1.port }
    }
}
