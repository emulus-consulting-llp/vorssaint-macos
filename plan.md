# Integration Plan: Gemini & Antigravity (AGY) AI Usage Tracking in Vorssaint

> **Status:** reviewed, supersedes the earlier `ai-usage-bar` integration brief.
> **Target repo:** `vorssaint-macos` (macOS 14, non-sandboxed, hardened runtime)
> **Reference:** `temp-ai-usage-bar/` (quota-only; it has no analytics path)

This plan was produced by reading both codebases in full and probing the live
Antigravity language server. It corrects three assumptions in the original
brief. See [Corrections to the original brief](#corrections-to-the-original-brief).

---

## 1. Research findings

These were verified on this machine, not inferred.

### 1.1 The cache holds quota only

`~/.aiusage/gemini.json` is exactly the `RetrieveUserQuotaSummary` response:

```json
{ "fetched_at": 1790573561.8,
  "raw_response": { "response": { "groups": [
    { "displayName": "Gemini Models", "buckets": [
        { "bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.25274295,
          "resetTime": "2026-10-01T04:35:45Z" },
        { "bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.9370475,
          "resetTime": "2026-09-28T08:52:57Z" } ] },
    { "displayName": "Claude and GPT models", "buckets": [
        { "bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.12458453,
          "resetTime": "2026-10-03T14:55:01Z" },
        { "bucketId": "3p-5h", "window": "5h", "remainingFraction": 1,
          "resetTime": "2026-09-28T09:10:40Z" } ] } ] } } }
```

No tokens, no cost, no model, no project. The 5h bucket resets sooner than it
was fetched, which is normal for a rolling window.

### 1.2 Process arguments do carry the CSRF token

The original brief (and an early reading of this repo) assumed neither
`--csrf_token` nor `--https_server_port` was present. The real command line:

```
language_server_macos_arm --enable_lsp --csrf_token <uuid>
  --extension_server_port 50289 --extension_server_csrf_token <uuid>
  --workspace_id file_Users_..._vorssaint-macos
  --cloud_code_endpoint https://daily-cloudcode-pa.googleapis.com
  --subclient_type ide --app_data_dir antigravity-ide
  --parent_pipe_path /var/folders/.../server_08ed1ca0a3f03d86
```

- `--csrf_token` **is** available from `ps`. No need to read it from the cache.
- `--https_server_port` **is not** a flag. The HTTPS listener is bound
  dynamically (`50291`, `50292`, `50300` for that pid). `lsof` probing is
  unavoidable; `--extension_server_port` and its neighbours are not a reliable
  predictor.
- The cache file is **stale by design risk**: it recorded `pid 2161,
  port 49547`, and pid 2161 no longer exists. Cache entries are hints, never
  trusted without validation.

### 1.3 Analytics do exist, but over RPC rather than files

`AgentAntigravityUsage`'s analytics source is not a log file. The language
server binary embeds the full Connect service surface (~300
`LanguageServerService` methods). The read-only ones that matter:

| Method | Provides |
| --- | --- |
| `GetAllCascadeTrajectories` | trajectory list (mirrored into the `antigravityUnifiedStateSync.trajectorySummaries` vscdb key, 80 KB, protobuf-framed) |
| `GetCascadeTrajectoryGeneratorMetadata` | per-step model + usage |
| `GetCascadeTrajectoryExecutorMetadatas` | executor-side per-step metadata |
| `GetCascadeTrajectorySteps` | full step content |
| `GetUserTrajectory`, `GetConversationMetadata` | trajectory detail |
| `GetAvailableModels`, `GetModelStatuses` | model catalogue |

The binary also contains the Gemini usage field names: `usageMetadata`,
`promptTokenCount`, `candidatesTokenCount`, `cachedContentTokenCount`,
`totalTokenCount`, `modelVersion`, `finishReason`, plus `modelName`,
`modelDisplayName`, `trajectoryId`, `stepIndex`, `createdTime`, `agentName`.

That is the same shape `AgentLogParser` already consumes for Claude and Codex,
so it can feed the existing store without a new accounting model.

### 1.4 What is *not* available on disk

- `~/Library/Application Support/Antigravity/User/{globalStorage,workspaceStorage}/*/state.vscdb`
  holds trajectory **summaries** only: title, trajectory id, created/updated
  timestamps, workspace folder URI. No model, no tokens.
- `~/.antigravity/extensions/` is just extensions.
- No cascade directory, no conversation store, no session logs equivalent to
  `~/.claude/projects/` or `~/.codex/sessions/`.

### 1.5 TLS

The extension ships `dist/languageServer/cert.pem`. The server uses a
self-signed certificate, so the reference app's blanket loopback trust works,
but the cert can be pinned instead (see Phase 2).

---

## 2. Decisions locked

1. **Analytics: research-first, gated.** Phase 0 is a spike against
   `GetAllCascadeTrajectories` + `GetCascadeTrajectoryGeneratorMetadata`. Quota
   ships regardless. Gemini/AGY enter Spend/Models/Projects/Live/Trend/Heatmap
   **only** if the spike proves per-step tokens + model + timestamp + workspace.
2. **Availability: the card is always present.** An enabled provider gets a card
   with an explicit state, never a silently missing card.
3. **Discovery: `ps` → `lsof` → fast probe → adopt.** The cache file is a
   shortcut hint only.

---

## 3. Product target

Provider order is a display contract, not alphabetical:

```
claude → gemini → agy → codex
```

| Provider | Enum | Display name | Tint | Mark | Quota source | Analytics source |
| --- | --- | --- | --- | --- | --- | --- |
| Claude | `.claude` | Claude | `0.85, 0.47, 0.34` | `sparkle` | `plan-usage-history.json` | `~/.claude/projects/` |
| Gemini | `.gemini` | Gemini | `0.48, 0.66, 0.97` | `sparkles` | LS RPC | trajectory generator metadata |
| Antigravity | `.agy` | Antigravity | `0.60, 0.63, 0.65` | `triangle` | LS RPC | trajectory generator metadata |
| Codex | `.codex` | Codex | `0.49, 0.60, 1.0` | `chevron.left.forwardslash.chevron.right` | session log | `~/.codex/sessions/` |

AI page: 2×2 grid of provider limit cards (5h + weekly bars, remaining/used,
reset countdown, urgency colour, explicit unavailable state), then the existing
Spend, Live, Models, Projects, Trend and 13-week activity cards, all of which
must keep working.

All six existing cards stay accurate. Where Gemini/AGY have no data, they are
absent from those cards rather than estimated into them.

---

## 4. Phase 0 — Analytics spike (gate)

Runs before Phase 5. Read-only RPC calls only.

1. Discover the endpoint per Phase 2.
2. `GetAllCascadeTrajectories` → confirm trajectory ids, titles, timestamps,
   workspace URIs.
3. `GetCascadeTrajectoryGeneratorMetadata` for one finished trajectory →
   confirm `modelName`, `promptTokenCount`, `candidatesTokenCount`,
   `cachedContentTokenCount`, `createdTime` per step, and whether the
   workspace/project is attributable.
4. Confirm the model names map onto `AgentPriceList` rows (or must be added).

**Gate outcome:**

- **Pass** → Phase 5 proceeds; Gemini/AGY join all six analytics cards.
- **Fail** → Phase 5 is dropped. Quota ships alone. Spend/Trend/Models/Projects/
  Live/Heatmap keep Claude + Codex and stay 100% accurate. The four limit cards
  still show Gemini/AGY. This is the correct outcome, not a failure: the
  numbers would otherwise be inferred rather than measured, and the brief's
  requirement to "retain all financial metrics" means *accurate*, not *present*.

Nothing else in this plan depends on the outcome.

---

## 5. Phase 1 — Models and provider enum

`Sources/Vorssaint/Services/AgentUsage/AgentUsageModels.swift`

- `AgentProvider`: add `case gemini, agy` at positions 2 and 3.
- `displayName`: `.gemini` → `"Gemini"`, `.agy` → `"Antigravity"`.
- `symbol`: `.gemini` → `"sparkles"`, `.agy` → `"triangle"`.
- `AgentLimits.Source`: add `case antigravity`.
- `AgentLimits`: add `var reach: Reach = .live` with
  `enum Reach { case live, cached, unavailable }`.

`reach` plus `windows.isEmpty` is what the card reads to choose between bars,
stale dimming, and the "isn't running" state. This keeps `seen` working
unchanged: an empty-windows entry still puts the key in `store.limits`, and
`AgentUsageSummary` already derives `seen` from `Set(limits.keys)`.

Sweep the exhaustive switches that adding enum cases breaks:

- `AgentUsageSummary.swift`
- `NotchAgentComponents.swift`
- `NotchAgentSupport.swift`
- `AgentUsageService.read()`

`AgentLogParser.swift` needs no change. It hardcodes `.claude` (line 104) and
`.codex` (lines 193, 253) and has no provider switch.

---

## 6. Phase 2 — Antigravity quota source

New file: `Sources/Vorssaint/Services/AgentUsage/AgentAntigravityUsage.swift`

Named to match the existing `AgentClaudeAppUsage`. The brief's
`AgentGeminiSource` breaks repo convention, and one source serves both
providers.

**`discover()`**

1. `/bin/ps -axo pid=,args=` through `BoundedProcessRunner` (never a raw
   `Process`); keep lines matching `language_server_macos_arm`; extract pid and
   `--csrf_token`.
2. `/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>` → candidate loopback
   ports.
3. `probe(port)`: POST Connect-JSON to
   `https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`
   with header `x-codeium-csrf-token`, 1.5s timeout. Non-200 fails fast
   (measured ~0.5ms), so probing 3–7 candidates is cheap.
4. Cache the winning `(pid, port, token, certFingerprint)` in memory;
   re-validate when the pid dies.
5. `~/.aiusage/antigravity.json` is consulted as a hint before step 1, and
   always validated the same way.

**TLS** — `URLSessionDelegate` accepting a self-signed certificate *only* for
`127.0.0.1`, `::1`, `localhost`. Preferred: pin the public key from
`dist/languageServer/cert.pem`, falling back to loopback-scoped trust.
Non-loopback always uses default validation.

**`parse(groups:)`** — mapping is fixed by the payload:

- `gemini-*` → `.gemini`; `3p-*` → `.agy`
- `5h` → `AgentLimitWindow.Kind.session` / 300 minutes
- `weekly` → `.weekly` / 10,080 minutes
- `usedFraction = 1.0 - remainingFraction`
- `resetTime` parsed as ISO8601
- unknown bucket ids are dropped, never guessed

**Failure states**

| Condition | Result |
| --- | --- |
| RPC ok | windows populated, `reach: .live` |
| RPC failed, cache fresh | windows from cache, `reach: .cached` |
| RPC failed, cache stale (>45 min) | windows from cache, `reach: .cached`, dimmed |
| nothing running, no cache | `windows: []`, `reach: .unavailable` |
| Antigravity never launched | `windows: []`, `reach: .unavailable` |

**Cadence** — discovery every 60s, RPC every 30s aligned with the service tick.
Never blocks `AgentUsageService.queue`.

---

## 7. Phase 3 — Service wiring

`Sources/Vorssaint/Services/AgentUsage/AgentUsageService.swift`

- `private let antigravity = AgentAntigravityUsage()`, injected so tests can
  substitute.
- In `tickTimer()`, after `readClaudeApp(now:)`, call `readAntigravity(now:)`.
- Hop back onto `queue` before `store.setLimits`. The store is queue-confined
  and not thread-safe.
- On provider disable, mirror the existing `store.clearLimits(.claude)` path
  for `.gemini` and `.agy`.
- `checkLimits()` and `reportRenewals()` are already provider-generic, so
  threshold alerts and renewal notices work unchanged. `NotchService` line 2410
  already renders `provider.displayName`, so no new notification copy is needed.

---

## 8. Phase 4 — UI

- `NotchAgentComponents.swift` — tints and `AgentMarks.lookUp` entries for
  gemini/agy; port the reference marks from `temp-ai-usage-bar/Resources/`.
- `NotchAgentsView.swift` — add both `@AppStorage` toggles and extend the
  `providers` list. **Remove `.filter(usage.snapshot.seen.contains)`**: enabled
  providers always render, and the card picks its own state. Keeping the filter
  makes the "isn't running" state unreachable, contradicting the brief's
  acceptance criterion 5.
- `NotchAgentSupport.rows` already pairs at `width >= 390` (`pairWidth`), so
  four cards give 2×2 with no layout change. Verify instead that a leftover odd
  count (toggle one provider off) still pairs cleanly, and that the closed
  strip still fits — `stripWingRange` is `44...80` and a 3-provider strip is
  wider than a 2-provider one.
- Reset formatters must render absolute (`resets at 8:30 PM`) *and* relative
  (`resets in 18 min`): Gemini/AGY supply absolute reset times, Codex relative.

---

## 9. Phase 5 — Analytics (gated on Phase 0)

Only if the spike passes.

- `AgentAntigravityUsage.trajectories()` → `[AntigravityStep]` (trajectoryId,
  stepIndex, createdTime, modelName, promptTokenCount, candidatesTokenCount,
  cachedContentTokenCount, workspace path).
- Feed through the existing `AgentLogEntry.usage` path so `AgentUsageStore`,
  `AgentPricing`, `AgentUsageSummary`, the 13-week heatmap and `fullyPriced`
  work unchanged.
- Add Gemini 2.5/3, Claude Sonnet/Opus and GPT-OSS rows to `AgentPriceList`.
- Poll less often than quota — trajectories are immutable once finished — and
  cache by `trajectoryId` to avoid re-walking history.

---

## 10. Phase 6 — Settings and persistence

- `Defaults.swift` — `notchAgentsGemini` and `notchAgentsAgy`, both default
  `true`, in the `DefaultsKey` block and in `registeredDefaults`.
- Both are automatically covered by `SettingsBackupSupport.exportKeys()`, which
  unions `registeredDefaults`. No change needed there;
  `PreferenceCleanupTests.sh` should pass untouched.
- `NotchAgentsSettings.swift` — toggle rows. The "find the Claude app / get
  Claude" block stays Claude-only.

---

## 11. Phase 7 — Localization

- New `NotchAgentStrings` fields: `antigravityNotRunning`, `quotaStale`,
  `fiveHour`, plus per-provider display names.
- **All 14 locales.** `LocalizationTests.check` validates argument identity, so
  any positional `%1$@` reuse must stay correct across every locale.

---

## 12. Validation and quality control

| Gate | Command |
| --- | --- |
| Compile | `./build.sh --dev` |
| Full suite | `./build.sh --test` |
| Targeted | `./build.sh --test-suite=agents` |
| Lint | `Tests/mutation_checks.py` (no agent coverage today — extend it) |

`build.sh` keeps an explicit `TEST_SOURCES` list (line 252 block). A new test
file that is not added there silently never compiles.

### New tests — `Tests/AgentAntigravityTests.swift`

Fixtures in `Tests/Fixtures/antigravity/`.

- **`ps` parsing** — three pid shapes, missing token, killed pid, no
  `--https_server_port`.
- **`lsof` parsing** — seven sockets for one pid, non-TCP rows, permission
  denied.
- **Port probe** — first candidate dead, second alive, all dead, 1.5s timeout
  honoured.
- **Quota parse** — the real payload in §1.1: `.gemini` gets 0.937 / 0.253,
  `.agy` gets 1.0 / 0.875. Plus empty groups, missing `resetTime`, unknown
  bucket ids, `remainingFraction` out of range.
- **TLS** — loopback self-signed accepted; a self-signed cert for a non-loopback
  host rejected.
- **State machine** — live → cached at 45 min → unavailable → back to live.
- **Service** — limits set on the queue, cleared on toggle-off, no cross-thread
  store access.
- **Store/summary** — an empty-windows entry still lands in `seen`.
- **UI** — four cards pair into two rows at 420pt; three cards; one card; strip
  wing width with four providers.
- **Analytics (gated)** — one trajectory fixture → correct tokens, model, cost,
  and heatmap day.

---

## 13. Risks and open items

- **Tier badges** (Pro / 1.5 / 3P / Plus in the brief's mockup) would need
  `FetchUserInfo` or `GetDeploymentConfig`. Unverified. Ship without badges; do
  not block on them.
- **Multiple language servers.** Three were running during research. Only the
  one whose `--workspace_id` matches a tracked root should feed the project
  dimension, and quota must be read once, not summed across pids.
- **Antigravity pricing.** Quota is consumed "proportionally to the cost of the
  tokens", so free 3P models such as GPT-OSS have a materially lower effective
  price. Pricing rows must be researched, not guessed.
- **Cache staleness.** `~/.aiusage/antigravity.json` recorded a dead pid. Any
  cache read must be validated against a live process.
- **Sandboxing.** The app is non-sandboxed with hardened runtime and has no ATS
  local-network exception. Loopback HTTPS needs none, but `build.sh` in a
  sandboxed shell must redirect the Clang module cache and `TMPDIR` into
  `build/`, per the brief.

---

## 14. Corrections to the original brief

| Brief said | Reality | Consequence |
| --- | --- | --- |
| Gemini/AGY appear in Spend, Models, Live cards | Quota sources carry no tokens; the reference app has no analytics path at all | Phase 0 gate decides; failing it means limits-only, which is correct rather than a shortfall |
| Provider hidden unless in `snapshot.seen` | An empty entry is invisible, so "isn't running" can never render | Filter removed; `AgentLimits.reach` drives explicit states |
| `ps` supplies `--https_server_port` and `--csrf_token` | Only `--csrf_token` is a flag; the port must come from `lsof`, and the cache is only a hint | Phase 2 discovery is `ps` → `lsof` → probe → adopt |
| Loopback self-signed trust is sufficient | The extension ships its own `cert.pem` | Pin the cert; keep loopback-scoped trust as fallback |
| New file `AgentGeminiSource.swift` | Convention is `AgentClaudeAppUsage` | `AgentAntigravityUsage.swift`, one source for both providers |

---

## 15. Definition of done

- Four limit cards render in the order Claude, Gemini, Antigravity, Codex, with
  5h and weekly bars, correct percentages, reset countdowns and urgency colour.
- An enabled but unavailable provider shows its explicit state, not a blank
  card and not a missing one.
- Disabling a provider removes its card without breaking row pairing.
- Claude and Codex quota, Spend, Trend, Live, Models, Projects and the 13-week
  heatmap are byte-for-byte unchanged in behaviour; all existing tests pass.
- Gemini/AGY analytics either work from measured data or are absent — never
  estimated.
- All 14 locales complete and `LocalizationTests` passes.
- Zero network traffic leaves the machine.
