import Foundation

/// Reads the cache written by `Scripts/claude-statusline.py`.
///
/// Claude's subscription limits are only observable through Claude Code's
/// statusLine payload, so this file is as fresh as your last Claude Code render.
/// That's why every reading carries `fetchedAt` and the UI shows its age: an
/// overnight-stale number must never be presented as live.
final class ClaudeSource {
    static let cacheURL = URL(fileURLWithPath: NSString(string: "~/.aiusage/claude.json").expandingTildeInPath)

    /// A reading older than this is reported as stale rather than current.
    static let stalenessThreshold: TimeInterval = 45 * 60

    private struct Window: Decodable {
        let used_percentage: Double
        let resets_at: Double?
    }

    private struct Payload: Decodable {
        let fetched_at: Double
        let five_hour: Window?
        let seven_day: Window?
        let has_limits: Bool
    }

    func read() -> Snapshot {
        var snapshot = Snapshot()

        guard let data = try? Data(contentsOf: Self.cacheURL) else {
            snapshot.error = "Claude Code hasn't reported yet"
            return snapshot
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            snapshot.error = "Unreadable cache file"
            return snapshot
        }

        snapshot.fetchedAt = Date(timeIntervalSince1970: payload.fetched_at)

        guard payload.has_limits else {
            // The hook ran but Claude reported no windows — an API-key user, or
            // no API response yet this session. Distinct from "never ran".
            snapshot.error = "No subscription limits reported"
            return snapshot
        }

        var buckets: [Bucket] = []
        if let w = payload.five_hour { buckets.append(bucket(w, .fiveHour)) }
        if let w = payload.seven_day { buckets.append(bucket(w, .weekly)) }
        snapshot.buckets = buckets

        // Marked here rather than by each caller: the cache only advances while
        // Claude Code renders, so every consumer needs this and any that forgot
        // would quietly present an old number as current.
        if Date().timeIntervalSince(snapshot.fetchedAt!) > Self.stalenessThreshold {
            snapshot.error = "stale — Claude Code idle"
        }

        return snapshot
    }

    private func bucket(_ w: Window, _ window: LimitWindow) -> Bucket {
        // The payload already reports percent used. Clamp so an over-100%
        // overage doesn't overflow the gauge.
        let used = max(0, min(1, w.used_percentage / 100))
        return Bucket(
            provider: .claude,
            window: window,
            usedFraction: used,
            resetTime: w.resets_at.map { Date(timeIntervalSince1970: $0) }
        )
    }
}
