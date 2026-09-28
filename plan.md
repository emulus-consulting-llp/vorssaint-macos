# Integration Plan: Gemini & Antigravity (AGY) AI Usage Tracking in Vorssaint

> **Status:** reviewed and revised. Supersedes the earlier `ai-usage-bar` integration brief
> and the first revision of this document.
> **Target repo:** `vorssaint-macos` (macOS 14, non-sandboxed, hardened runtime)
> **Reference:** `temp-ai-usage-bar/` (quota-only; it has no analytics path)
> **Shape:** sprint-ready. Every phase has entry criteria, tasks, exit criteria and a test
> matrix. Nothing here is a suggestion; every claim about the current code carries a
> `file:line` you can check.

This plan was produced by reading both codebases in full, probing the live Antigravity
language server, and running the existing test suite. A code review against the actual
repository produced twenty-two findings; all twenty-two are folded in here, and the ones
that changed the design are listed in [§4](#4-corrected-facts-about-this-repo).

---

## Contents

1. [Sprint readiness](#1-sprint-readiness)
2. [Research findings](#2-research-findings)
3. [Decisions locked](#3-decisions-locked)
4. [Corrected facts about this repo](#4-corrected-facts-about-this-repo)
5. [Workstreams and sequencing](#5-workstreams-and-sequencing)
6. [Phase 0 — Analytics spike (gate)](#6-phase-0--analytics-spike-gate)
7. [Phase 1 — Provider enum, preference keys, sources](#7-phase-1--provider-enum-preference-keys-sources)
8. [Phase 2 — Antigravity quota source](#8-phase-2--antigravity-quota-source)
9. [Phase 3 — Service wiring](#9-phase-3--service-wiring)
10. [Phase 4 — UI](#10-phase-4--ui)
11. [Phase 5 — Pricing substrate](#11-phase-5--pricing-substrate)
12. [Phase 6 — Analytics (gated on Phase 0)](#12-phase-6--analytics-gated-on-phase-0)
13. [Phase 7 — Settings and persistence](#13-phase-7--settings-and-persistence)
14. [Phase 8 — Localization](#14-phase-8--localization)
15. [Phase 9 — Documentation, privacy, trademarks](#15-phase-9--documentation-privacy-trademarks)
16. [Validation and build wiring](#16-validation-and-build-wiring)
17. [Test matrix](#17-test-matrix)
18. [Risks and open items](#18-risks-and-open-items)
19. [Sprint board](#19-sprint-board)
20. [Definition of done](#20-definition-of-done)
21. [Corrections to the original brief](#21-corrections-to-the-original-brief)

---

## 1. Sprint readiness

The sprint opens when every row below is true. They are cheap; do them first.

| # | Pre-flight | Why it blocks |
| --- | --- | --- |
| R1 | `./build.sh --test` green on `main` before the first commit | Otherwise a pre-existing failure is attributed to this work |
| R2 | `./build.sh --test-suite=agents` recorded as the baseline (currently `agents: OK (251 checks)`) | The `NotchAgentTests.swift:950` provider-list expectation is a known tripwire (§4.1) |
| R3 | Confirm the price-list publication order: who can push `Resources/agent-prices.json` to `vorssaint/vorssaint-utils` | Phase 5's bundled rows are silently replaced by a newer published list that lacks them (`AgentUsageService.swift:521`) |
| R4 | A decision recorded on Antigravity marks: SF Symbols only, or licensed artwork | `NotchAgentComponents.swift:331-334` states no third-party artwork ships with Vorssaint; `TRADEMARKS.md` governs |
| R5 | An explicit go/no-go on shipping an undocumented third-party RPC call | §18 R-RPC. This is a product/legal decision, not an engineering one |
| R6 | A scratch script harness for Phase 0 exists, isolated from the app target | The spike must not be able to write to `AgentUsageStore` |
| R7 | `agent-guard` mode confirmed; work happens in `_temp_working_folder/` and is promoted deliberately | — |

**Definition of ready for each phase** is its own "Entry" line. **Definition of done** is
global and is [§20](#20-definition-of-done); a phase is not finished because its code
compiles.

---

## 2. Research findings

These were verified on this machine, not inferred.

### 2.1 The cache holds quota only

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

No tokens, no cost, no model, no project.

**Both 5h windows reset *after* the fetch, not before.** `fetched_at` is
`2026-09-28T05:32:41Z`; `gemini-5h` resets `08:52:57Z` and `3p-5h` resets `09:10:40Z`,
3.3 to 3.6 hours later. The earlier revision of this plan claimed the opposite. The
correction matters: it means a 5h window *will* expire while Vorssaint is running, and
`AgentLimitSupport.current` (`AgentUsageSummary.swift:409-421`) maps an expired `resetsAt`
to 0% used with a **nil** reset. A five-hour card is therefore in the expired state for a
large fraction of the day, and the card has to have a designed answer for it. See
[Phase 4](#10-phase-4--ui).

### 2.2 Process arguments carry the CSRF token, but not the port

The real command line:

```
language_server --enable_lsp --csrf_token <uuid>
  --extension_server_port 50289 --extension_server_csrf_token <uuid>
  --workspace_id file_Users_..._vorssaint-macos
  --cloud_code_endpoint https://daily-cloudcode-pa.googleapis.com
  --subclient_type ide --app_data_dir antigravity-ide
  --parent_pipe_path /var/folders/.../server_08ed1ca0a3f03d86
```

- `--csrf_token` **is** available from `ps`.
- `--https_server_port` **is not a flag.** The listener binds dynamically. `lsof` probing
  is unavoidable; `--extension_server_port` and its neighbours are not a reliable predictor.
- **The binary was renamed.** Antigravity 2.15 ships `language_server`; the plan used to
  filter `ps` for `language_server_macos_arm`, which matches nothing on a current install
  and would have made discovery silently return zero candidates. Match the `language_server`
  prefix and tolerate both names.
- **The protocol is not HTTPS-only.** The reference implementation
  (`temp-ai-usage-bar/Sources/AIUsageBar/GeminiSource.swift`) tries HTTP and HTTPS, and the
  hint file `~/.aiusage/antigravity.json` records `address: localhost:49547` with a bare
  port. Both must be supported.
- **The cache is a hint, never a truth.** It recorded `pid 2161`, which no longer exists.

### 2.3 Analytics exist, but over RPC rather than files

`AgentAntigravityUsage`'s analytics source is not a log file. The language server binary
embeds the full Connect service surface (~300 `LanguageServerService` methods). The
read-only ones that matter:

| Method | Provides |
| --- | --- |
| `GetAllCascadeTrajectories` | trajectory list (mirrored into `antigravityUnifiedStateSync.trajectorySummaries`, ~80 KB, protobuf-framed) |
| `GetCascadeTrajectoryGeneratorMetadata` | per-step model + usage |
| `GetCascadeTrajectoryExecutorMetadatas` | executor-side per-step metadata |
| `GetCascadeTrajectorySteps` | full step content |
| `GetUserTrajectory`, `GetConversationMetadata` | trajectory detail |
| `GetAvailableModels`, `GetModelStatuses` | model catalogue |

The binary also contains the Gemini usage field names: `usageMetadata`,
`promptTokenCount`, `candidatesTokenCount`, `cachedContentTokenCount`,
`totalTokenCount`, `modelVersion`, `finishReason`, plus `modelName`,
`modelDisplayName`, `trajectoryId`, `stepIndex`, `createdTime`, `agentName`.

That is the same shape `AgentLogParser` already consumes for Claude and Codex, so it can
feed the existing store without a new accounting model.

### 2.4 What is not available on disk

- `~/Library/Application Support/Antigravity/User/{globalStorage,workspaceStorage}/*/state.vscdb`
  holds trajectory **summaries** only: title, trajectory id, timestamps, workspace folder
  URI. No model, no tokens.
- `~/.antigravity/extensions/` is just extensions.
- No cascade directory, no conversation store, no session log equivalent to
  `~/.claude/projects/` or `~/.codex/sessions/`.

### 2.5 TLS

The extension ships `dist/languageServer/cert.pem`
(`/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/dist/languageServer/cert.pem`,
CN=localhost). The served certificate was **not** verified to be byte-identical to the
shipped file; that comparison needs a live loopback handshake. The reference app's
loopback-scoped trust works across versions; see [Phase 2](#8-phase-2--antigravity-quota-source)
for why pinning is not the default here.

---

## 3. Decisions locked

1. **Analytics: research-first, gated.** Phase 0 decides. Quota ships regardless.
   Gemini/AGY enter Spend/Models/Projects/Live/Trend/Heatmap **only** on a pass.
2. **Availability: the card is always present.** An enabled provider gets a card with an
   explicit state, never a silently missing card, and never a blank one.
3. **Discovery: hint file → `ps` → `lsof` → bounded probe → adopt.** The hint file is a
   shortcut only; every value from it is re-validated against a live process.
4. **No new liveness mechanism.** The existing `AgentLimits.Source` is widened rather than
   duplicated. The first revision of this plan added a parallel `reach` enum; that was
   rejected because the card's `stale` test hardcodes `source == .claudeApp` and would then
   need a second correction anyway. See [§4.1](#41-blocking-defects-in-the-first-revision).
5. **New providers default off.** `notchAgentsGemini` and `notchAgentsAgy` register
   `false`. With the `seen` filter removed (§4.1 item 3) a default-`true` provider that is
   never running is a permanent "isn't running" card for every user who has not installed
   Antigravity. The Settings rows and the plan's own availability states cover discovery.
6. **Marks: SF Symbols.** No third-party artwork ships. `gemini → sparkles`,
   `agy → triangle`, drawn in the provider tint, matching how `AgentMarks` already falls
   back to a symbol when an app is not installed. Gate R4 can overturn this with a recorded
   decision; it is not the default.
7. **Support posture: best-effort, unversioned.** The language server's RPC surface is
   private and can change without notice. Say so in the UI-adjacent docs rather than
   implying a supported integration.

---

## 4. Corrected facts about this repo

Twenty-two findings from the code review. Every one is now a task or a decision.

### 4.1 Blocking defects in the first revision

| # | Finding | Where | Resolution |
| --- | --- | --- | --- |
| 1 | `key(for:)` maps every non-Claude provider to the **Codex** preference | `NotchAgentSupport.swift:74` | Phase 1, T1.4 — exhaustive `switch` |
| 2 | "One agent stays on" hardcodes `!(claude && codex)`; with four providers all four can be switched off | `NotchAgentsSettings.swift:210` | Phase 7, T7.3 |
| 3 | Strip sample picks the provider with a two-way ternary | `NotchAgentsSettings.swift:82` | Phase 7, T7.3 |
| 4 | `findRoots()` derives captions from `AgentLogRoot.all()`, which is Claude + Codex only, so Gemini/AGY read "not found" forever | `NotchAgentsSettings.swift:215-218` | Phase 7, T7.4 |
| 5 | "Add Gemini rows to `AgentPriceList`" is a schema change, not a row addition | `AgentPricing.swift:47-88, 210-221` | Phase 5, whole phase |
| 6 | `resumeWindow(for:)` and `AgentLogCursor.init` silently classify new providers as Codex | `AgentUsageStore.swift:33, 249, 251` | Phase 1, T1.6 |
| 7 | `stale` hardcodes `source == .claudeApp`; the new `reach` enum was read by nothing | `NotchAgentsView.swift:130` | Decision 4; Phase 1, T1.3 |
| 8 | `fullyPriced` false flips Models/Projects to token order and prefixes Spend with `≥ ` — for every existing user | `NotchAgentsView.swift:92, 95, 330, 382, 507`; `AgentUsageSummary.swift:62` | Phase 5, T5.6; §20 states the behaviour |

### 4.2 Factual errors in the first revision

| # | Plan said | Reality | Resolution |
| --- | --- | --- | --- |
| 9 | "The 5h bucket resets sooner than it was fetched" | Both 5h resets are 3.3–3.6 h **after** the fetch | §2.1; Phase 4, T4.5 |
| 10 | "A new test file not in `TEST_SOURCES` silently never compiles" | `build.sh:520` globs `Tests/*.swift`; production sources are the list at `build.sh:252-283` | §16 |
| 11 | "All 14 locales" | **15** — `NotchAgentStrings.swift:129-143` | §14 |
| 12 | Match `--workspace_id` to a tracked root | Two of three live servers had hashed ids; unimplementable | §18 R-SERVERS |
| 13 | "Codex supplies relative reset times" | Codex is absolute too — `AgentLogParser.swift:289` | Phase 4, T4.5 |
| 14 | Filter `ps` for `language_server_macos_arm` | Renamed to `language_server` in AGY 2.15 | §2.2; Phase 2, T2.2 |
| 15 | HTTPS-only, pin the cert | Reference impl does HTTP too; the served cert is unverified | Phase 2, T2.6 |

### 4.3 Gaps in coverage

| # | Finding | Where | Resolution |
| --- | --- | --- | --- |
| 16 | `NotchAgentTests.swift:950` expects `providers(in:) == [.claude]`; `providers(in:)` filters `allCases` by default-true, so two new default-true cases break it | `NotchAgentSupport.swift:70-72` | Phase 1, T1.7 — a new `"agents"` mutation plus an updated expectation |
| 17 | New tests must be registered in the `"agents"` suite tuple or they never run | `Tests/MetricsTests.swift:75` | §16 |
| 18 | `Tests/Fixtures/` files are **not** compiled by the `Tests/*.swift` glob; the one file there is inlined by `generate_sources.py:1158-1163` | `Tests/generate_sources.py` | §16 — pick a fixture mechanism and state it |
| 19 | `declaration()` fails closed on zero or multiple prefix matches, so a new `private func read(` in `AgentUsageService` breaks generation of `AgentUsageRead.swift` | `Tests/generate_sources.py:19-35, 1149-1153` | §16 |
| 20 | `AgentUsageEventDeliveryTests.swift:32` fixture is `[.claude, .codex]`; whether Gemini/AGY produce turn events is undecided | `Tests/AgentUsageEventDeliveryTests.swift` | §18 R-LIVE |
| 21 | No privacy, README, doc-comment or trademark work anywhere in the plan | `docs/PRIVACY.md:42-80`; `AgentUsageService.swift` header; `TRADEMARKS.md` | Phase 9, whole phase |
| 22 | "Zero network traffic leaves the machine" is not a claim we can stand behind | §20 | §20 restates it; Phase 9, T9.1 |

---

## 5. Workstreams and sequencing

```
      R1..R7  (sprint readiness)
            │
            ▼
   ┌────────────────────┐
   │ Phase 0  SPIKE     │  isolated script, gate, no app code
   └────────┬───────────┘
            │ (runs in parallel with everything below)
   ┌────────▼───────────┐   ┌──────────────────┐
   │ Phase 1  MODEL     │──▶│ Phase 2  SOURCE  │
   │ enum/keys/Source   │   │ discovery + RPC  │
   └────────┬───────────┘   └────────┬─────────┘
            │                        │
            └───────────┬────────────┘
                        ▼
              ┌───────────────────┐
              │ Phase 3  SERVICE  │  queue hops, clear-on-disable
              └─────────┬─────────┘
                        ▼
              ┌───────────────────┐
              │ Phase 4  UI       │  cards, states, reset copy
              └─────────┬─────────┘
                        ▼
   ┌────────────────────┴────────────────────┐
   │                                         │
┌──▼──────────────┐              ┌───────────▼──────────┐
│ Phase 5 PRICING │              │ Phase 7 SETTINGS     │
│ substrate       │              │ toggles, roots       │
└──┬──────────────┘              └───────────┬──────────┘
   │                                         │
   └────────────┬────────────────────────────┘
                ▼
   ┌────────────────────┐   ┌──────────────────┐   ┌──────────────┐
   │ Phase 8 LOCALE     │   │ Phase 9 DOCS     │   │ Phase 6      │
   │ 15 locales        │   │ privacy/trademark │   │ ANALYTICS    │
   └────────────────────┘   └──────────────────┘   │ (gate-open)  │
                                                    └──────────────┘
```

Phases 1–5 and 7–9 are the **quota sprint**. Phase 6 is a **separate, gated sprint** that
starts only if Phase 0 passes and only after the quota sprint merges. Do not carry Phase 6
risk into the quota sprint.

---

## 6. Phase 0 — Analytics spike (gate)

**Entry:** R6. **Runs in parallel with Phase 1.** Read-only. Never imports app code.

**Out of scope:** anything that writes to `AgentUsageStore`, `AgentPricing`, or any
`Defaults` key. The spike is a throwaway script plus captured fixtures under
`_temp_working_folder/_scratch/`.

### Tasks

- **T0.1** Capture the discovery chain by hand: `ps` → `lsof` → HTTP probe → HTTPS probe
  against `RetrieveUserQuotaSummary`. Record which protocol and which port the *served*
  certificate belongs to, and whether it matches the shipped `cert.pem` (sha256
  `4cd998d691bed6aa5f49e03e71f2b03c7e99b266168f1ad8e9a113bfb6bf59ff`).
- **T0.2** `GetAllCascadeTrajectories`. Confirm trajectory ids, titles, timestamps and
  workspace URIs are present and populated.
- **T0.3** `GetCascadeTrajectoryGeneratorMetadata` for one finished trajectory. Confirm
  `modelName`, `promptTokenCount`, `candidatesTokenCount`, `cachedContentTokenCount`,
  `createdTime` per step, and whether the workspace is attributable **without** relying on
  `--workspace_id` (§18 R-SERVERS).
- **T0.4** Confirm the model names map onto `AgentPriceList` rows, or that Phase 5's new
  `agent` table can express them.
- **T0.5** Write the captured payloads to `Tests/Fixtures/antigravity/` in the mechanism
  chosen by §16, so Phase 6 never needs the live server again.

### Gate criteria — pass requires **all four**

| # | Criterion |
| --- | --- |
| G1 | Per-step `promptTokenCount` + `candidatesTokenCount` + `createdTime` present for at least 95% of steps in 3 sampled trajectories |
| G2 | `modelName` present for ≥ 95% of steps and resolvable to a price row or a Phase 5 table entry |
| G3 | A workspace/project is attributable per step, by a signal other than `--workspace_id` |
| G4 | Three consecutive calls, ≥ 10 minutes apart, return consistent schema (no field rot) |

Any criterion missed → **fail**. A fail is the correct outcome, not a shortfall: quota
still ships, the four limit cards still show Gemini/AGY, and Spend/Trend/Models/Projects/
Live/Heatmap keep Claude + Codex exactly as they are today.

### Exit

Write the outcome into this plan's status line and into `docs/AI-CONTRIBUTIONS.md`. Commit
the fixtures either way — they are the regression corpus for T2.7.

---

## 7. Phase 1 — Provider enum, preference keys, sources

**Entry:** R1, R2, R3. **Blocks:** everything except Phase 0.

### Tasks

- **T1.1** `AgentProvider`: add `case gemini, agy` at positions 2 and 3. **The declaration
  order is the display order** — `NotchAgentSupport.providers(in:)` iterates
  `AgentProvider.allCases` (`NotchAgentSupport.swift:70-72`), and §3.3 of the product
  target is that contract. Add a test that pins it.
- **T1.2** `displayName`: `.gemini` → `"Gemini"`, `.agy` → `"Antigravity"`. `symbol`:
  `.gemini` → `"sparkles"`, `.agy` → `"triangle"`. `tint` in
  `NotchAgentComponents.swift:7-15`.
- **T1.3** `AgentLimits.Source`: add `case antigravity`, and give `Source` a `freshness`
  so liveness has one home:
  ```swift
  enum Source {
      case claudeApp, sessionLog, antigravity
      /// How long a reading from this source stays trustworthy.
      var freshness: TimeInterval {
          self == .claudeApp ? AgentClaudeAppUsage.freshness : AgentAntigravityUsage.freshness
      }
  }
  ```
  Then `NotchAgentLimitsCard.stale` (`NotchAgentsView.swift:130`) becomes
  `now.timeIntervalSince(limits.observedAt) >= limits.source.freshness`, which is
  provider-agnostic and removes the hardcoded `.claudeApp`. Do **not** add a `reach` enum
  (Decision 4). Liveness is then fully derived: `windows.isEmpty` → unavailable;
  `observedAt` older than `source.freshness` → cached and dimmed; otherwise live.
- **T1.4** `NotchAgentSupport.key(for:)` becomes an exhaustive `switch` (§4.1 item 1). This
  compiles either way, which is exactly why the compiler will not catch it — the test will.
- **T1.5** `Defaults.swift`: `notchAgentsGemini`, `notchAgentsAgy`, both `false` in the
  `DefaultsKey` block (near `Defaults.swift:797-798`) and in `registeredDefaults` (near
  `Defaults.swift:1322-1323`). `SettingsBackupSupport.exportKeys()` unions
  `registeredDefaults`, so both travel in backups with no change there.
- **T1.6** Sweep every provider comparison. The first revision missed the store because the
  ternary compiles. Fix and test:
  - `AgentUsageSummary.swift`
  - `NotchAgentComponents.swift`
  - `NotchAgentSupport.swift`
  - `AgentUsageStore.swift:33` `resumeWindow(for:)`, `:249` and `:251` in
    `AgentLogCursor.init` — all three currently treat anything that is not Claude as Codex
  - `AgentUsageService.read()`
  - `NotchAgentsSettings.swift:82`, `:210` (Phase 7 does the last two; do not forget them)
  - `AgentLogParser.swift` needs no change: it hardcodes `.claude` (line 104) and `.codex`
    (lines 193, 253) and has no provider switch.

### Tests (T1)

- `key(for:)` returns four distinct keys, and no provider returns the Codex key except
  Codex.
- `providers(in:)` with all four on → `[.claude, .gemini, .agy, .codex]` in that order.
- `providers(in:)` with all four off → `[]`. **Update `NotchAgentTests.swift:950`**, whose
  current expectation of `[.claude]` encodes the old two-provider world; the test's stated
  intent ("an agent can be left out") is preserved by disabling all four and expecting `[]`.
- `registeredDefaults` contains both new keys as `false`, and `exportKeys()` is a superset
  of every `notchAgents*` key (`NotchAgentTests.swift:958` extended with the new pair).
- `stale` is true for a `.antigravity` reading older than its freshness, and false for a
  fresh one.
- A new `"agents"` mutation in `Tests/mutation_checks.py`: flip the freshness comparison in
  `NotchAgentsView.stale` and confirm the suite fails. The groups today are emoji, launcher,
  localization, notch, preferences, recording, screenshots, storage, switcher — there is no
  agents group yet.

### Exit

`./build.sh --dev` clean, `./build.sh --test-suite=agents` green with ≥ 8 new assertions,
`python3 Tests/mutation_checks.py` green including the new mutation.

---

## 8. Phase 2 — Antigravity quota source

**Entry:** Phase 1 landed. **Blocks:** Phase 3.

New file `Sources/Vorssaint/Services/AgentUsage/AgentAntigravityUsage.swift`, named to match
the existing `AgentClaudeAppUsage`. The original brief's `AgentGeminiSource` breaks repo
convention, and one source serves both providers.

### T2.1 Discovery

1. Read `~/.aiusage/antigravity.json` as a hint. Extract `address`/`port`, `csrf_token`,
   `pid`. Never trusted; re-validated at step 4 like any other candidate.
2. `/bin/ps -axo pid=,args=` through `BoundedProcessRunner` (never a raw `Process`). Keep
   lines whose executable basename starts with `language_server` — this matches both
   `language_server` (AGY ≥ 2.15) and `language_server_macos_arm` (older). Extract pid and
   `--csrf_token`.
3. `/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>` → candidate loopback ports.
4. `probe(port)`: POST Connect-JSON to
   `<http|https>://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`
   with header `x-codeium-csrf-token`, 1.5 s timeout, both schemes tried in the order the
   hint file suggests. Non-200 fails fast (measured ~0.5 ms).
5. Cache the winning `(pid, port, scheme, token)` **in memory only**. Re-validate when the
   pid disappears.

**Budget, stated so it can be tested:** at most **6 probes per discovery cycle**, at most
**2 discovery cycles per minute**, and at most **3 distinct pids** examined per cycle. When
more than three language servers are running, quota is read from the first that answers and
never summed across pids. Exceeding the budget is a test failure, not a runtime surprise.

**Threading:** discovery and RPC run on their own serial queue. `AgentUsageService.queue` is
never blocked. A cycle already in flight when the next tick arrives is dropped, not queued;
`URLSession` tasks are cancelled on provider disable and on service teardown, matching the
existing session/cancellation guards in `AgentUsageService`.

### T2.2 Pid liveness

Cheap re-validation, not `kill(0)` per candidate: a `kill(pid, 0)` probe only for the
cached winner, and a fresh `ps` cycle otherwise. A dead pid invalidates the cache
immediately; the hint file's own `updated_at` is only advisory.

### T2.3 Parse

Mapping is fixed by the payload:

- `gemini-*` → `.gemini`; `3p-*` → `.agy`
- `5h` → `AgentLimitWindow.Kind.session` / 300 minutes
- `weekly` → `.weekly` / 10,080 minutes
- `usedFraction = 1.0 - remainingFraction`
- `resetTime` parsed as ISO8601
- **A bucket with no `remainingFraction` is dropped, not guessed.** The reference
  implementation treats a missing fraction as 0; showing a fabricated 0% is worse than
  showing nothing, and the plan's own rule is "unknown bucket ids are dropped, never
  guessed". Extend the same rule to missing fields.
- Unknown bucket ids are dropped.

### T2.4 What the 3p buckets are called in the UI

`3p-*` is displayed by Google as "Claude and GPT models" (§2.1). It is Claude/GPT third-party
quota metered on a Google account — **not** Antigravity quota. `.agy` is the right *owner*,
but the card title must read honestly, e.g. "Claude & GPT (via Antigravity)". Add the
localized string in Phase 8 and record it as a product decision, not a copy detail.

### T2.5 Failure states

| Condition | Result |
| --- | --- |
| RPC ok | windows populated, `observedAt = now` |
| RPC failed, hint fresh (< 45 min) | windows from hint, `observedAt` = hint's `updated_at` |
| RPC failed, hint stale (> 45 min) | windows from hint, dimmed by `source.freshness` |
| Nothing running, no hint | `windows: []` → card shows unavailable |
| Antigravity never installed | `windows: []` → card shows unavailable |
| TLS trust failed / cert rotated | Same as "RPC failed" but **also** stop retrying that port for 10 minutes, so a rotated cert does not cost 6 probes every cycle |

`AgentAntigravityUsage.freshness` = 45 min, matching the table.

### T2.6 TLS

Default to **loopback-scoped trust**: a `URLSessionDelegate` that accepts a self-signed
certificate only for `127.0.0.1`, `::1` and `localhost`. Non-loopback always uses default
validation.

Cert pinning against
`/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/dist/languageServer/cert.pem`
is **not** the default. Reading another app's bundle on every probe and breaking when Google
moves the file costs more than it buys; the local-attacker-on-a-loopback-port threat it
appears to address is not meaningfully raised by this design, because such an attacker can
bind the port regardless. Pinning may be added behind a flag once T0.1 establishes that the
served certificate is stable across versions.

### T2.7 Cadence

Discovery every 60 s, quota RPC every 30 s aligned with `AgentUsageService.tick`. Neither
blocks `AgentUsageService.queue`. Responses are cached by `updated_at` so a repeat poll with
an unchanged payload does not churn `observedAt`.

### Tests (T2)

- `ps` parsing: three pid shapes, missing token, dead pid, no `--https_server_port`, both
  binary names, a path-prefixed argv[0] (`/…/Resources/language_server`).
- `lsof` parsing: seven sockets for one pid, non-TCP rows, permission denied, empty output.
- Port probe: first candidate dead, second alive, all dead, 1.5 s timeout honoured, HTTP
  before HTTPS, the 6-probe and 3-pid budgets enforced.
- Pid liveness: cached winner dies → cache invalidated, no re-probe of dead candidates.
- Quota parse: the real §2.1 payload — `.gemini` gets 0.937 / 0.253, `.agy` gets 1.0 / 0.875.
  Plus empty groups, missing `resetTime`, missing `remainingFraction`, unknown bucket ids,
  `remainingFraction` out of range, `resetTime` in the past.
- TLS: loopback self-signed accepted; self-signed for a non-loopback host rejected; cert
  failure enters the 10-minute port backoff.
- State machine: live → cached at 45 min → unavailable → back to live; unreachable
  `source.freshness` dims the card.
- Concurrency: no store access off the service queue; in-flight cycle dropped, not queued;
  tasks cancelled on disable.

Port probing needs an injectable transport and the TLS delegate a seam, or these become
integration tests that require Antigravity to be running. Seam them.

### Exit

`./build.sh --dev` clean; the `agents` suite green with ≥ 30 new assertions; the §2.1
payload is a committed fixture, not a live dependency.

---

## 9. Phase 3 — Service wiring

**Entry:** Phase 2 landed.

- **T3.1** `private let antigravity = AgentAntigravityUsage()`, injected so tests can
  substitute. Follow whatever seam `AgentClaudeAppUsage` already uses.
- **T3.2** In `tickTimer()`, after `readClaudeApp(now:)`, call `readAntigravity(now:)`.
- **T3.3** Hop back onto `queue` before `store.setLimits`. The store is queue-confined and
  not thread-safe (`AgentUsageStore.swift`).
- **T3.4** On provider disable, mirror the existing `store.clearLimits(.claude)` path
  (`AgentUsageService.swift:489, 510`) for `.gemini` and `.agy`.
- **T3.5** `checkLimits()` and `reportRenewals()` are already provider-generic, so threshold
  alerts and renewal notices work unchanged. `NotchService` (~2393-2410) already renders
  `provider.displayName`, so no new notification copy.
- **T3.6** Update the `AgentUsageService` header comment and the `AgentUsageModels` doc
  comments. They currently assert that the only outbound request is the price list; Phase 2
  adds a loopback request. Phase 9 finishes the user-facing half, but the code comment
  should not be left lying between the two.

### Tests (T3)

Limits set on the queue; cleared on toggle-off; no cross-thread store access; a failed RPC
leaves the previous `observedAt` intact rather than resetting it.

### Exit

`./build.sh --test` green. Toggling Gemini/AGY off in Settings removes their limits within
one tick, verified in a real run.

---

## 10. Phase 4 — UI

**Entry:** Phase 3 landed.

- **T4.1** `NotchAgentComponents.swift` — `tint` entries and `AgentMarks.lookUp` entries for
  `gemini` and `agy`. Symbols only (Decision 6). Do **not** port PNG artwork from
  `temp-ai-usage-bar/Resources/`: that is a git submodule owned by another project, from an
  app whose bundle id is `com.google.antigravity-ide`, and it contradicts the comment at
  `NotchAgentComponents.swift:331-334`. `AgentMarks` already falls back to a symbol when an
  app is not installed, which is the behaviour we want on a Mac without Antigravity.
- **T4.2** `NotchAgentsView.swift` — add both toggles and take `providers` from
  `NotchAgentSupport.providers()`. **Remove `.filter(usage.snapshot.seen.contains)`** (line
  24). Keeping the filter makes the "isn't running" state unreachable, which contradicts
  Decision 2. `seen` stays in the snapshot for the other cards.
- **T4.3** `NotchAgentSupport.rows` already pairs at `width >= 390` (`pairWidth`), so four
  cards give 2×2 with no layout change. Verify a leftover odd count (toggle one provider
  off) still pairs cleanly, and that the closed strip still fits — `stripWingRange` is
  `44...80` and a 3-provider strip is wider than a 2-provider one. Add a 4-provider strip
  case; the plan's original list had none.
- **T4.4** Card states, all four explicit and all reachable:
  - live, windows present, fresh → bars + countdown
  - cached, windows present, older than `source.freshness` → bars dimmed, copy says when it
    was read
  - unavailable, `windows.isEmpty` → "isn't running" with the provider's name
  - never blank, never missing
- **T4.5** Reset formatters. There is **one** absolute path, not two: `AgentLimitWindow`
  is absolute everywhere, including Codex (`AgentLogParser.swift:289`). Render both
  `resets at 8:30 PM` and `resets in 18 min`. The new requirement is the **expired** case
  (§2.1): when `resetsAt` is in the past, `AgentLimitSupport.current` returns 0% used with a
  nil reset, so the card must say the window is spent rather than showing an empty
  countdown. Add a test for an expired `gemini-5h`, because that is the normal state for
  hours every day.
- **T4.6** Leave the Claude-only blocks Claude-only: `claudeBlock`,
  `claudeLimitsStatus(now:)`, `claudeApp`, `claudeAppFileCheck`.

### Tests (T4)

Four cards pair into two rows at 420pt; three cards; two cards; one card; strip wing width
with four providers; each of the four card states renders; the expired 5h window shows the
spent copy; a Gemini card never shows Claude's "find the Claude app" text.

### Exit

`./build.sh --dev` clean; a real run with Antigravity closed shows four cards with Gemini and
AGY in the unavailable state, which is the state most users will see first.

---

## 11. Phase 5 — Pricing substrate

**Entry:** R3. Independent of Phase 2 and Phase 6, but **must** land before Phase 6.

This is a substrate change, not a row addition. `AgentPriceList` has exactly two model
tables, `claude` and `codex` (`AgentPricing.swift:66-72`); `decode` requires **both** keys
and `schema == 1` exactly (lines 80-85); `models(_:prefix:)` enforces the `claude-` prefix
rule; and `price(for:in:)` selects a table with a binary
(`id.hasPrefix("claude-") ? list.claude : list.codex`, line 212).

### Tasks

- **T5.1** Add a third table `agent: [Model]` to `AgentPriceList`, holding models reached
  through Antigravity that are not Claude-branded: `gemini-*`, `gpt-oss-*`.
- **T5.2** `decode` treats `agent` as **optional**, defaulting to `[]`. This keeps `schema`
  at 1, so every already-cached list still decodes and no user's prices are lost. Do not
  bump the schema: `decode` rejects anything but 1, and `AgentPriceList.newer(shipped,
  cached) ?? .empty` (`AgentUsageService.swift:521`) would install `.empty` until a fresh
  list downloaded — a visible "all models unpriced" regression for every user.
- **T5.3** `price(for:in:where:)` takes a table hint from the caller, who knows the provider.
  Default behaviour reproduces today's binary exactly, so existing callers and tests are
  untouched.
- **T5.4** `normalized()` keeps its `claude-` prefix rewrite. A `claude-*` step inside
  Antigravity's 3P usage prices from the Claude table. That is intended; say so in a
  comment, because it looks like a bug otherwise.
- **T5.5** `siblings` is unchanged. It already contains `pro` (line 205), so
  `gemini-3-pro-preview` matching only a `gemini-3` family row returns **nil**, not an
  approximation. That is the intended behaviour — better no figure than a wrong one — and
  the price rows must therefore name each variant explicitly.
- **T5.6** Document the `fullyPriced` consequence, which is a **user-visible degradation for
  existing Claude and Codex users**: any unpriced model sets `total.unpriced > 0`, so
  `fullyPriced` is false, so Models and Projects switch from cost to token ordering
  (`NotchAgentsView.swift:92, 95, 382, 507`) and Spend grows a `≥ ` prefix (line 330). The
  first revision's DoD claimed the six existing cards stay unchanged; they do not. Decide
  explicitly, per provider, whether an unpriced Gemini model may flip the ordering for
  Claude/Codex data — the safe answer is that `fullyPriced` is computed **per provider** so
  one unpriced Gemini model cannot re-sort a Claude user's Models card. Implement whichever
  you choose and state it in §20.
- **T5.7** Publish the same rows to
  `https://raw.githubusercontent.com/vorssaint/vorssaint-utils/main/Resources/agent-prices.json`
  in the same change. `AgentPriceList.newer` picks the later `updated` date, so a **newer
  published list without the `agent` table wins and silently empties it**. Keep the bundled
  `updated` date at least as new as any list we know about, and add a test for the
  regression: a newer cached list lacking the table must not delete bundled rows.
- **T5.8** Research the prices. Quota is consumed "proportionally to the cost of the
  tokens", so free 3P models such as GPT-OSS have a materially lower effective price. Do not
  guess; a wrong price is worse than a missing one and the code already agrees.

### Tests (T5)

- `price(for: "gemini-3-pro-preview")` resolves only if the list names that variant.
- `price(for: "gemini-3-pro-preview")` against a list naming only `gemini-3` → nil.
- `price(for: "gpt-oss-120b")` → nil until a row exists, then that row.
- `price(for:)` with a `claude-` model under a `.agy` record → the Claude table's price.
- `decode` accepts a `schema 1` list with no `agent` key, and one with it.
- `decode` still rejects `schema 2`.
- `newer` with a newer cached list lacking `agent` → bundled rows survive.
- `fullyPriced` is false when an unpriced model is present, and T5.6's chosen per-provider
  behaviour holds.

### Exit

`./build.sh --test` green; every existing pricing test unchanged; the published list and the
bundled list agree on `updated`.

---

## 12. Phase 6 — Analytics (gated on Phase 0)

**Entry:** Phase 0 passed with all four criteria, and Phases 1-5, 7-9 merged. A separate
sprint.

- **T6.1** `AgentAntigravityUsage.trajectories()` → `[AntigravityStep]` (trajectoryId,
  stepIndex, createdTime, modelName, promptTokenCount, candidatesTokenCount,
  cachedContentTokenCount, workspace path).
- **T6.2** Feed through the existing `AgentLogEntry.usage` path so `AgentUsageStore`,
  `AgentPricing`, `AgentUsageSummary`, the 13-week heatmap and `fullyPriced` work unchanged.
- **T6.3** If Gemini/AGY produce turn events, extend the
  `AgentUsageEventDeliveryTests.swift:32` fixture and decide whether Live shows them. If
  they do not, Live stays Claude + Codex while the limit cards show four providers — a
  half-live state that §20 must describe honestly. Decide before starting.
- **T6.4** Poll less often than quota — trajectories are immutable once finished — and
  cache by `trajectoryId` to avoid re-walking history.
- **T6.5** Warm-start from the captured fixtures, never from the live server, in tests.

### Tests (T6)

One trajectory fixture → correct tokens, model, cost and heatmap day. Two trajectories,
overlapping ids, resumed workspace. An unpriced model → the T5.6 behaviour.

### Exit

`./build.sh --test` green; a real run's Spend total for Gemini matches a hand-counted
trajectory.

---

## 13. Phase 7 — Settings and persistence

**Entry:** Phase 1 landed; Phase 4 for the strip sample.

- **T7.1** `Defaults.swift` keys are done in T1.5.
- **T7.2** Both are automatically covered by `SettingsBackupSupport.exportKeys()`, which
  unions `registeredDefaults`. No change there; `PreferenceCleanupTests.sh` should pass
  untouched.
- **T7.3** `NotchAgentsSettings.swift` — four `providerRow` calls, and the two hardcoded
  two-provider expressions become provider-generic:
  - line 210 `.disabled(isOn.wrappedValue && !(claude && codex))` → disable only when the
    *count of enabled providers* is 1, so the AI page can never be emptied (§4.1 item 2).
  - line 82 `provider: claude || !codex ? .claude : .codex` → the first enabled provider
    from `NotchAgentSupport.providers()`, falling back to `.claude` (§4.1 item 3).
  - line 137's `onChange` list gains both new keys.
- **T7.4** `findRoots()` (lines 215-218) currently derives captions from
  `AgentLogRoot.all()` — Claude and Codex log directories only. Gemini and AGY have no log
  root, so the caption would read "not found" forever while their quota card is live. The
  row's secondary line must be provider-source-aware: log-root existence for Claude/Codex,
  process discovery for Gemini/AGY. Reuse the discovery seam from Phase 2; do not run a
  second `ps` sweep from the view.
- **T7.5** The "find the Claude app / get Claude" block stays Claude-only.

### Tests (T7)

Four toggle rows render; with three providers on, the fourth can be switched off; with one
on, it cannot be switched off; the strip sample shows the first enabled provider; a Gemini
row reads "running" while the language server is up and "not found" while it is not.

### Exit

`./build.sh --test` green, `PreferenceCleanupTests.sh` untouched, a real run confirms the
captions.

---

## 14. Phase 8 — Localization

- **T8.1** New `NotchAgentStrings` fields: the unavailable state per provider, the cached
  and stale read states, the spent-window state (§2.1, T4.5), the 3p bucket's honest title
  (T2.4), and the `fiveHour` / `weekly` window labels.
- **T8.2** **All 15 locales**: enUS, ptBR, es, sk, de, fr, it, ru, tr, ja, ko, uk, zhHans,
  zhTW, zhHK (`NotchAgentStrings.swift:129-143`). The first revision said 14 and would have
  shipped one language short.
- **T8.3** `LocalizationTests.check` validates field parity, non-empty text, no em-dash, and
  format-argument identity. Any positional `%1$@` reuse must stay correct across every
  locale — with 15 locales and new fields, this is where argument-order mistakes hide.
- **T8.4** Per-provider display names. Decide whether "Antigravity" is a product name that
  stays untranslated while "isn't running" and the read-state copy is localized. Mixed
  treatment is normal; do it deliberately and note it in the strings file.

### Tests (T8)

`LocalizationTests` green. A deliberate wrong-argument-order mutation in one locale fails the
check — confirm the harness catches it rather than assuming it does.

### Exit

`./build.sh --test` green with all 15 locales present for every new field.

---

## 15. Phase 9 — Documentation, privacy, trademarks

**Entry:** Phases 1-8 landed. The first revision of this plan had no documentation phase at
all, which is not acceptable for a change that adds a network request and reads another
vendor's process state.

- **T9.1** `docs/PRIVACY.md` — the "Network connections" list (lines 42-80) is exhaustive
  and ends "That is the entire list." Add a numbered entry for the Antigravity quota lookup:
  loopback only, what is sent (a Connect request with the CSRF token found in the local
  process's own arguments), what is not sent, the 30-second cadence while the provider is
  enabled, and how to stop it (the provider toggle). State plainly that the language server
  may itself contact Google to answer the quota question.
- **T9.2** Restate the privacy claim. "Zero network traffic leaves the machine" is not a
  claim we can stand behind. Vorssaint's own traffic is loopback, but driving
  `RetrieveUserQuotaSummary` every 30 seconds causes Antigravity to contact
  `--cloud_code_endpoint https://daily-cloudcode-pa.googleapis.com`. The accurate claim is
  about **Vorssaint's** traffic, and it must say that.
- **T9.3** `README.md` — Antigravity and Gemini support, and the best-effort/unversioned
  posture (Decision 7).
- **T9.4** Code comments: `AgentUsageService` header, `AgentUsageModels` docs, and
  `AgentAntigravityUsage` itself (T3.6 finishes the first two).
- **T9.5** `TRADEMARKS.md` — record the marks decision (Decision 6 / gate R4): SF Symbols,
  no third-party artwork, names used descriptively.
- **T9.6** `docs/AI-CONTRIBUTIONS.md` — attribute the Antigravity/Google RPC research and
  the Phase 0 outcome, consistent with how the existing agent work is credited.

### Tests (T9)

None. This phase is reviewed, not tested. It is in the plan because shipping without it is a
defect.

---

## 16. Validation and build wiring

| Gate | Command | Notes |
| --- | --- | --- |
| Compile | `./build.sh --dev` | |
| Full suite | `./build.sh --test` | |
| Targeted | `./build.sh --test-suite=agents` | The `"agents"` suite |
| Mutation | `python3 Tests/mutation_checks.py` | Add an `"agents"` group; none exists today |

**How tests are actually compiled — correcting the first revision.** It said a new test file
not listed in `TEST_SOURCES` "silently never compiles". That is wrong, and acting on it
would waste a cycle.

- `build.sh:520` globs `Tests/*.swift`, so a new test file in `Tests/` compiles
  automatically.
- `build.sh:252-283` is an explicit list of **production** sources. A new production file
  must be added there or the test target cannot reference it. The agent sources are
  `NotchAgentSupport.swift`, `AgentUsageModels.swift`, `AgentPricing.swift`,
  `AgentLogParser.swift`, `AgentUsageSummary.swift`, `AgentUsageStore.swift`,
  `AgentClaudeAppUsage.swift`; add `AgentAntigravityUsage.swift` beside them.
- A new test's `run(_:)` must be registered in the `"agents"` suite tuple at
  `Tests/MetricsTests.swift:75`, or it compiles and never executes.
- **`Tests/Fixtures/` files are not compiled by the glob.** The one file there,
  `QuitProtectionHUDChecks.swift`, is inlined into a generated source by
  `Tests/generate_sources.py:1158-1163`. So "fixtures in `Tests/Fixtures/antigravity/`"
  needs a mechanism decision: either a `generate_sources.py` entry that inlines a Swift
  checks file, or a payload directory read at runtime by path derived from `#filePath`.
  Pick one and write it down before writing the first fixture.
- `declaration()` in `generate_sources.py` **fails closed** when a prefix matches zero or
  more than one declaration. `AgentUsageService.read()` is extracted today
  (`generate_sources.py:1149-1153`); adding a second `private func read(` breaks test
  generation. Name the new method distinctly.
- SwiftUI or `Bundle`-dependent production code cannot go in `TEST_SOURCES` directly; it
  needs a `generate_sources.py` declaration, as `NotchAgentSupport` and the limit card
  already do.

### Exit for the sprint

`./build.sh --test` green, `./build.sh --dev` clean, `python3 Tests/mutation_checks.py`
green with an `"agents"` group, and a real run on a Mac with and without Antigravity open.

---

## 17. Test matrix

New file `Tests/AgentAntigravityTests.swift`, plus additions to `Tests/NotchAgentTests.swift`.
Every row is a required assertion, not a suggestion.

| Area | Cases | Phase |
| --- | --- | --- |
| `ps` parsing | 3 pid shapes; missing token; dead pid; no `--https_server_port`; both binary names; path-prefixed argv[0] | 2 |
| `lsof` parsing | 7 sockets; non-TCP rows; permission denied; empty | 2 |
| Port probe | first dead/second alive; all dead; 1.5 s timeout honoured; HTTP before HTTPS; 6-probe and 3-pid budgets | 2 |
| Pid liveness | cached winner dies → invalidated, no re-probe of dead ports | 2 |
| Quota parse | real §2.1 payload; empty groups; missing `resetTime`; missing `remainingFraction`; unknown bucket ids; fraction out of range; `resetTime` in the past | 2 |
| TLS | loopback self-signed accepted; non-loopback rejected; cert failure → 10-minute port backoff | 2 |
| Liveness states | live → cached at 45 min → unavailable → live; `source.freshness` dims the card | 1, 2, 4 |
| Service | limits set on the queue; cleared on toggle-off; no cross-thread store access; in-flight cycle dropped; cancelled on disable | 3 |
| Provider keys | `key(for:)` four distinct keys; `providers(in:)` order; all-off → `[]`; `registeredDefaults` `false`; `exportKeys()` superset | 1, 7 |
| Settings | four rows; one-cannot-be-disabled rule; strip sample picks the first enabled; roots caption per provider source | 7 |
| Store | `resumeWindow` and `AgentLogCursor` classify four providers, not two | 1 |
| UI layout | 4/3/2/1 cards pair; strip wing width with 4 providers; four card states; expired 5h shows spent copy; a Gemini card never shows Claude-only copy | 4 |
| Pricing | `gemini-3-pro-preview` variant-only; `gpt-oss-120b`; `claude-` under `.agy`; `decode` without `agent`; `decode` rejects schema 2; `newer` keeps bundled rows; `fullyPriced` per T5.6 | 5 |
| Localization | 15 locales × new fields; a wrong-argument-order mutation is caught | 8 |
| Analytics *(gated)* | one trajectory → tokens, model, cost, heatmap day; two overlapping; unpriced model | 6 |
| Mutation | `"agents"` group: `stale` freshness comparison, `key(for:)` switch, `fullyPriced` ordering | 1, 5 |

---

## 18. Risks and open items

- **R-RPC — undocumented third-party surface.** We call a private Google protobuf service
  whose name, shape and availability can change with no notice and no deprecation path. Gate
  R5 must record a go/no-go. Mitigation: the provider toggle is already a kill switch; the
  card degrades to "isn't running" rather than erroring; the docs say best-effort.
- **R-QUOTA-EGRESS — we cause outbound traffic.** Our request is loopback, but the language
  server will contact `--cloud_code_endpoint` to answer it, and we ask every 30 seconds. The
  DoD's privacy claim must be restated (§15, T9.2), and the 30 s cadence is a product
  decision, not an implementation detail. Consider 60 s, or cache-until-changed.
- **R-SERVERS — multiple language servers.** Three were running during research. Quota is
  account-wide, so it is read from the first server that answers and **never summed**.
  The original plan's rule — match `--workspace_id` to a tracked root — is unimplementable:
  two of the three had hashed workspace ids. Phase 0 criterion G3 must find a different
  signal or the project dimension is dropped for Gemini/AGY.
- **R-TLS — cert rotation.** Loopback-scoped trust is the default for that reason (§2.5,
  T2.6). A rotated certificate is handled by the 10-minute port backoff, not by a crash.
- **R-STALE — the 5h window expires while we watch.** §2.1. The card needs a designed
  expired state; a stale `resetsAt` otherwise shows 0% used with no explanation.
- **R-PRICE — Antigravity pricing.** Quota is consumed "proportionally to the cost of the
  tokens", so free 3P models such as GPT-OSS have a materially lower effective price. Rows
  must be researched, not guessed, and each variant named explicitly because `siblings`
  already rejects `pro` (T5.5, T5.8).
- **R-PRICE-LIST — the published list can silently erase the bundled one.**
  `AgentPriceList.newer` picks the later `updated` date. A newer published list without the
  `agent` table wins (T5.7).
- **R-DEFAULT-ON — cards for people without Antigravity.** Solved by Decision 5: both new
  providers default off. Do not "fix" this later by defaulting them on.
- **R-LIVE — half-live state.** Decide in T6.3 whether Gemini/AGY produce turn events. If
  not, Live shows two providers while the limit cards show four, and §20 must say so.
- **R-ARTWORK — marks.** Gate R4. Default is SF Symbols only.
- **R-SANDBOX — build environment.** The app is non-sandboxed with hardened runtime and has
  no ATS local-network exception. Loopback HTTP/HTTPS needs none. `build.sh` in a sandboxed
  shell must redirect the Clang module cache and `TMPDIR` into `build/`.
- **R-TIER — tier badges.** Pro / 1.5 / 3P / Plus would need `FetchUserInfo` or
  `GetDeploymentConfig`. Unverified. Ship without badges; do not block on them.

---

## 19. Sprint board

Estimates are in points, 1 point ≈ one focused morning. Quota sprint only; Phase 6 is
separately estimated once Phase 0 reports.

| ID | Task | Pts | Depends on | Phase |
| --- | --- | --- | --- | --- |
| R1 | Baseline `./build.sh --test` and `--test-suite=agents` | 1 | — | Readiness |
| R3 | Confirm price-list publication order | 1 | — | Readiness |
| R4 | Record the marks decision | 1 | — | Readiness |
| R5 | Go/no-go on the private RPC | 1 | — | Readiness |
| T0.1 | Discovery chain by hand; cert identity | 3 | R6 | 0 |
| T0.2 | `GetAllCascadeTrajectories` | 2 | T0.1 | 0 |
| T0.3 | `GetCascadeTrajectoryGeneratorMetadata` + workspace attribution | 3 | T0.2 | 0 |
| T0.4 | Model names → price rows | 2 | T0.3 | 0 |
| T0.5 | Commit captured fixtures | 1 | T0.4 | 0 |
| T1.1 | `AgentProvider` + order contract | 1 | R1 | 1 |
| T1.2 | `displayName`, `symbol`, `tint` | 1 | T1.1 | 1 |
| T1.3 | `Source` + `freshness`; fix `stale` | 2 | T1.1 | 1 |
| T1.4 | `key(for:)` exhaustive switch | 1 | T1.1 | 1 |
| T1.5 | Preference keys + `registeredDefaults` | 1 | T1.1 | 1 |
| T1.6 | Provider-comparison sweep incl. `AgentUsageStore` | 2 | T1.1 | 1 |
| T1.7 | `agents` tests + `"agents"` mutation group; fix `NotchAgentTests:950` | 2 | T1.3-1.6 | 1 |
| T2.1 | Discovery: hint → `ps` → `lsof` → bounded probe, own queue | 5 | T1.1 | 2 |
| T2.2 | Pid liveness + in-memory cache invalidation | 1 | T2.1 | 2 |
| T2.3 | `parse(groups:)` with drop-unknown and drop-missing | 2 | T2.1 | 2 |
| T2.4 | 3p bucket title decision | 1 | T2.3 | 2 |
| T2.5 | Failure-state table incl. cert backoff | 2 | T2.3 | 2 |
| T2.6 | TLS: loopback trust default | 2 | T2.1 | 2 |
| T2.7 | Cadence + response caching by `updated_at` | 1 | T2.3 | 2 |
| T2.8 | `build.sh` source list + fixture mechanism decision | 1 | R1 | 2 |
| T2.9 | Discovery/parse/TLS/state/concurrency tests | 5 | T2.1-2.7 | 2 |
| T3.1-3.4 | Service wiring, queue hops, clear-on-disable | 3 | T2.* | 3 |
| T3.5 | Confirm generic alerts; no copy change | 1 | T3.1 | 3 |
| T3.6 | Update service and model doc comments | 1 | T3.1 | 3 |
| T3.7 | Service tests | 2 | T3.1-3.4 | 3 |
| T4.1 | Marks, tints, symbols (no artwork) | 1 | T1.2, R4 | 4 |
| T4.2 | Drop the `seen` filter; four toggles | 1 | T3.1 | 4 |
| T4.3 | Pairing and strip-width verification | 2 | T4.2 | 4 |
| T4.4 | Four explicit card states | 2 | T1.3, T2.5 | 4 |
| T4.5 | Reset formatters + the expired-window state | 2 | T4.4 | 4 |
| T4.7 | UI tests | 3 | T4.1-4.5 | 4 |
| T5.1-5.4 | `agent` table, optional decode, table hint, `claude-` note | 4 | R3 | 5 |
| T5.5 | `siblings` behaviour documented | 1 | T5.1 | 5 |
| T5.6 | Decide and implement the `fullyPriced` scope | 2 | T5.1 | 5 |
| T5.7 | Publish rows; guard the `newer` regression | 2 | T5.1, R3 | 5 |
| T5.8 | Research the prices | 3 | T5.1 | 5 |
| T5.9 | Pricing tests | 2 | T5.1-5.7 | 5 |
| T7.3 | Provider-generic disable rule + strip sample | 2 | T1.5 | 7 |
| T7.4 | Provider-source-aware roots caption | 2 | T2.1 | 7 |
| T7.6 | Settings tests | 2 | T7.3, T7.4 | 7 |
| T8.1-8.4 | New strings across 15 locales; argument-order mutation | 5 | T4.4, T2.4 | 8 |
| T9.1-9.6 | `PRIVACY.md`, README, comments, trademarks, credits | 3 | T3.*, T4.* | 9 |
| — | Final validation: `--dev`, `--test`, `--test-suite=agents`, mutation | 2 | all | — |

**Total ≈ 100 points.** Phases 0, 1, 2 and 5 are independent of each other after readiness
and can run in parallel across three people; Phases 3, 4, 7, 8, 9 are a chain after Phase 2.

**Critical path:** R1 → T1.1 → T2.1 → T3.1 → T4.2 → T7.3 → T8.1 → T9.1 ≈ 21 points.

---

## 20. Definition of done

A phase is done when all of these hold. Where a line below contradicts the first revision
of this plan, **this list wins**.

1. Four limit cards render in the order Claude, Gemini, Antigravity, Codex, with 5h and
   weekly bars, correct percentages, reset countdowns and urgency colour. The order is
   pinned by a test, because it comes from `AgentProvider.allCases`.
2. An enabled but unavailable provider shows its explicit state — not a blank card, not a
   missing one, and not a card only some users see.
3. Disabling a provider removes its card without breaking row pairing, and the last enabled
   provider cannot be switched off.
4. A provider that has never run on this Mac shows its unavailable state from the first
   launch, because the new providers default off and the `seen` filter is gone.
5. An expired 5h window — the common case, see §2.1 — shows a designed state, not 0% with a
   missing countdown.
6. The 3p buckets are labelled for what they are: Claude and GPT models metered on a Google
   account, not "Antigravity".
7. Claude and Codex quota, Spend, Trend, Live, Models, Projects and the 13-week heatmap keep
   their existing behaviour for users with no Antigravity data. **This includes the
   `fullyPriced` consequence:** state explicitly, in the release note and in the code, which
   providers share the `fullyPriced` flag. If Gemini/AGY analytics ship and any of their
   models are unpriced, an existing Claude user's Models card may re-sort from cost to
   tokens and Spend may gain a `≥ ` prefix. That is a real, user-visible change and the DoD
   may not call it "unchanged".
8. Gemini/AGY analytics either work from measured data or are absent — never estimated.
9. All **15** locales complete and `LocalizationTests` passes.
10. `./build.sh --dev` clean, `./build.sh --test` green, `./build.sh --test-suite=agents`
    green, `python3 Tests/mutation_checks.py` green including a new `"agents"` group.
11. `docs/PRIVACY.md`, `README.md`, `TRADEMARKS.md`, `docs/AI-CONTRIBUTIONS.md` and the
    `AgentUsageService` / `AgentUsageModels` doc comments are updated.
12. **Privacy claim, restated accurately:** Vorssaint's own requests for this feature go to
    `127.0.0.1` on the Antigravity language server and nowhere else. The language server may
    contact Google to answer the quota question, so this feature can cause a periodic
    outbound request that Vorssaint does not make itself. The provider toggle stops all of
    it. Do not ship the phrase "zero network traffic leaves the machine".
13. No third-party artwork ships. Marks are SF Symbols, tinted per provider.
14. A real run, on a Mac with Antigravity open and on one without, with the AI page watched
    across a 5h window boundary.

---

## 21. Corrections to the original brief

| Brief said | Reality | Consequence |
| --- | --- | --- |
| Gemini/AGY appear in Spend, Models, Live cards | Quota sources carry no tokens; the reference app has no analytics path at all | Phase 0 gate decides; failing it means limits-only, which is correct rather than a shortfall |
| Provider hidden unless in `snapshot.seen` | An empty entry is invisible, so "isn't running" can never render | Filter removed; liveness derived from `windows.isEmpty` and `Source.freshness` |
| `ps` supplies `--https_server_port` and `--csrf_token` | Only `--csrf_token` is a flag; the port must come from `lsof`; the binary is now `language_server` and the protocol may be plain HTTP | Discovery is hint → `ps` → `lsof` → bounded probe → adopt |
| Loopback self-signed trust is sufficient | The extension ships its own `cert.pem`, but the served certificate is unverified and pinning costs version-fragility | Loopback-scoped trust is the default; pinning is opt-in after T0.1 |
| New file `AgentGeminiSource.swift` | Convention is `AgentClaudeAppUsage` | `AgentAntigravityUsage.swift`, one source for both providers |
| Add Gemini rows to `AgentPriceList` | The list has two tables and a binary table selector; `decode` is strict | Phase 5 is a substrate change, plus a coordinated publication |
| Ship the third-party marks | `NotchAgentComponents.swift:331-334` and `TRADEMARKS.md` say no artwork ships | SF Symbols only, pending a recorded decision |
| Zero network traffic leaves the machine | We cause a 30-second outbound request from the language server | Restated in §20, item 12, and documented in `PRIVACY.md` |
