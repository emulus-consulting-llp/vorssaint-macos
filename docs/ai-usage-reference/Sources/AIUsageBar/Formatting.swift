import Foundation

enum Format {
    /// "88%"
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// A text stand-in for the drawn capsule, for `--dump`.
    static func textBar(_ fraction: Double, width: Int = 10) -> String {
        let filled = Int((max(0, min(1, fraction)) * Double(width)).rounded())
        return String(repeating: "\u{2588}", count: filled)
            + String(repeating: "\u{2591}", count: width - filled)
    }

    /// Right-aligned to a fixed column so "58%", "70%" and "100%" stack cleanly.
    /// Still used by `--dump`, which has no layout engine to lean on.
    static func percentColumn(_ fraction: Double) -> String {
        let text = percent(fraction)
        return String(repeating: " ", count: max(0, 4 - text.count)) + text
    }

    /// Relative while the reset is close enough to act on, absolute once it
    /// isn't. The weekly window turns into a countdown only inside half a day;
    /// past that a weekday reads better than "in 3 days".
    ///
    /// The 5-hour window names the wall-clock moment it comes back -- "resets at
    /// 8:30 PM" -- because that is the thing you plan around, and "in 4 hr"
    /// threw away the minutes that decide it. Inside the last hour it flips to a
    /// countdown, where "soon" is the answer and a clock time would make you do
    /// the subtraction yourself.
    static func reset(_ date: Date?, window: LimitWindow, now: Date = Date()) -> String {
        guard let date else { return "" }

        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "resetting now" }

        if window == .fiveHour {
            // Under the hour the countdown is the useful form: "resets at
            // 5:12 PM" makes you do the subtraction yourself when the answer is
            // just "soon". Floor, but never "0 min" -- that reads as done.
            if seconds < 3600 { return "resets in \(max(1, Int(seconds / 60))) min" }
            return "resets at \(clock(date))"
        }

        if seconds < 3600 {
            // Floor, but never "in 0 min" -- that reads as already done.
            return "resets in \(max(1, Int(seconds / 60))) min"
        }
        if seconds < 12 * 3600 {
            return "resets in \(Int(seconds / 3600)) hr"
        }

        // Composed from two templates rather than one "EEE j:mm", so the comma
        // is ours and doesn't depend on what the locale's combined template
        // happens to insert.
        let weekday = DateFormatter()
        weekday.locale = .current
        weekday.setLocalizedDateFormatFromTemplate("EEE")
        return "resets \(weekday.string(from: date)), \(clock(date))"
    }

    /// Wall-clock time, localized: "3:51 PM" where the locale uses one, "15:51"
    /// where it doesn't.
    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: date)
    }

    /// How long ago a reading was taken: "live", "2m ago", "3h ago".
    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }

        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 90 { return "live" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}
