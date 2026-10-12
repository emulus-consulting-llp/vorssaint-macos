import Foundation

/// Which limit pool a bucket belongs to.
enum Provider: String {
    /// Anthropic subscription limits, account-wide: Claude Code *and* claude.ai
    /// draw on this same pool, which is why one reading covers both.
    case claude
    /// Google's Gemini models, as metered by Antigravity. One account-level
    /// pool: the Antigravity IDE and CLI share it.
    case gemini
    /// Antigravity's non-Google models — Claude Opus/Sonnet and GPT-OSS, which
    /// Antigravity itself groups as "Claude and GPT models". Provided and billed
    /// by Google: using Claude *inside Antigravity* spends this, not the
    /// Anthropic subscription the `.claude` case tracks.
    case antigravity3P

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .antigravity3P: return "Antigravity"
        }
    }

    /// Only these count toward the menu bar headline; the Antigravity Claude/GPT
    /// pool is shown but excluded, since it isn't one of the two providers being
    /// tracked.
    var countsTowardHeadline: Bool { self != .antigravity3P }
}

enum LimitWindow: String {
    case fiveHour
    case weekly

    var sectionTitle: String {
        switch self {
        case .fiveHour: return "Next 5 hours"
        case .weekly: return "This week"
        }
    }
}

struct Bucket {
    let provider: Provider
    let window: LimitWindow
    /// 0.0 = untouched, 1.0 = exhausted.
    let usedFraction: Double
    let resetTime: Date?
}

/// One source's most recent result. `buckets` holds the last good reading even
/// once `error` is set, so the UI can show a stale value with its age rather
/// than dropping to a blank row.
struct Snapshot {
    var buckets: [Bucket] = []
    var fetchedAt: Date?
    var error: String?

    var hasData: Bool { fetchedAt != nil && !buckets.isEmpty }
    var isLive: Bool { hasData && error == nil }

    func bucket(_ provider: Provider, _ window: LimitWindow) -> Bucket? {
        buckets.first { $0.provider == provider && $0.window == window }
    }
}

/// Everything the menu renders.
struct UsageState {
    var claude = Snapshot()
    var gemini = Snapshot()

    var allBuckets: [Bucket] { claude.buckets + gemini.buckets }

    /// The menu bar headline: mean 5-hour consumption across the tracked
    /// providers. Averages over whatever has data; nil when nothing does.
    var headlineUsed: Double? {
        let values = [claude, gemini]
            .filter(\.hasData)
            .flatMap(\.buckets)
            .filter { $0.window == .fiveHour && $0.provider.countsTowardHeadline }
            .map(\.usedFraction)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// True when the headline is worth less than full confidence: either a
    /// provider is missing entirely, or one of the readings behind it is stale.
    /// A stale reading still counts toward the average -- usage barely moves
    /// while a tool is idle, and dropping it would make the number lurch -- but
    /// the average must not present itself as fully current when it isn't.
    var headlineIsPartial: Bool {
        let contributing = [claude, gemini].filter(\.hasData)
        return contributing.count < 2 || contributing.contains { $0.error != nil }
    }
}
