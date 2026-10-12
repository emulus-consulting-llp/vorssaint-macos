import Foundation

/// `AIUsageBar --dump` prints the state the menu would render, as text.
///
/// The menu bar can't be inspected from a script, so this is how the data path
/// gets verified against the sources without a screenshot.
enum Diagnostics {
    static func dump() {
        var state = UsageState()
        state.claude = ClaudeSource().read()

        let source = GeminiSource()
        print("discovered language servers:")
        for endpoint in source.discoverEndpoints() {
            print("  pid \(endpoint.pid)  port \(endpoint.port)  token \(endpoint.csrfToken.prefix(8))…")
        }

        let semaphore = DispatchSemaphore(value: 0)
        source.fetch { snapshot in
            state.gemini = snapshot
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 20)

        print("")
        if let used = state.headlineUsed {
            print("menu bar:  \(Format.textBar(used)) \(Format.percent(used))"
                  + (state.headlineIsPartial ? "   (incomplete or stale)" : ""))
        } else {
            print("menu bar:  \(Format.textBar(0)) --   (no data)")
        }

        for window in [LimitWindow.fiveHour, .weekly] {
            print("\n\(window.sectionTitle)")
            for provider in [Provider.claude, .gemini, .antigravity3P] {
                let snapshot = provider == .claude ? state.claude : state.gemini
                let name = provider.displayName.padding(toLength: 24, withPad: " ", startingAt: 0)
                guard let bucket = snapshot.bucket(provider, window) else {
                    print("  \(name)— \(snapshot.error ?? "unavailable")")
                    continue
                }
                let bar = Format.textBar(bucket.usedFraction)
                let percent = Format.percentColumn(bucket.usedFraction)
                let stale = snapshot.error != nil ? "   [stale: \(snapshot.error!)]" : ""
                print("  \(name)\(bar) \(percent)   \(Format.reset(bucket.resetTime, window: bucket.window))\(stale)")
            }
        }

        print("\nClaude \(state.claude.hasData ? Format.age(state.claude.fetchedAt) : "no data")"
              + " · Gemini \(state.gemini.hasData ? Format.age(state.gemini.fetchedAt) : "no data")")
    }
}
