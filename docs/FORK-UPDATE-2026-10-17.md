# Upstream integration — 2026-10-17

Integrated 62 upstream commits while retaining the personal AI usage and Usage
Timeline features. This report records the review, adaptations and validation;
[FORK-MAINTENANCE.md](FORK-MAINTENANCE.md) defines the required future process.

## Inputs and scope

| Input | Commit |
| --- | --- |
| Original personal source | `ab4d6c7aeb4eafb3b515f076dc170bae6bb555ee` |
| P: personal starting point, after preservation-guide commit | `bb7574c2548a6703a49823f7df710e36ea9846e4` |
| U: freshly fetched upstream target | `125167ae2264d7c9c51c3a5b4d6cbad471e35a24` |
| B: merge base / previously integrated upstream | `0b8e94404621849ef7da24523e5c16a9815a1bee` |

The user successfully ran `git fetch --multiple --no-tags origin upstream` in
Terminal after this environment could not resolve GitHub. Upstream advanced from
B to U; origin's personal branch matched the original personal source. The
working tree was clean before the workflow documentation and merge work.
The trial used `git merge --no-commit --no-ff U` on `personal/ai-usage`.
No branches were created/switched, no remote was pushed, and `community` was not
advanced. The Developer app was built but not installed or relaunched.

Upstream changed 234 paths. The fork had 104 personal paths relative to B;
32 overlapped upstream changes. All 104 remain present. Of the 72 personal-only
paths, 68 remain byte-for-byte identical to P; two source/test paths were adapted
for Claude's new account reader and two guides were updated. No personal feature
or test was approved for removal.

## Accepted upstream changes and preservation decisions

- Agent parsers now use provider-specific readers under `AgentUsage/Harness/`.
  Personal Claude/Codex/OpenCode question handling was ported into those readers;
  Gemini still delegates to its existing parser and Antigravity remains quota-only.
  Pending question IDs, full in-memory prompts, matching-answer cleanup, heartbeat
  handling and persistent island notices survive the refactor.
- Codex continuation and subagent metadata now identify the main thread and dedup
  running totals. Personal question/approval detection and chronological startup
  replay remain. Added account-home cards coexist with the default personal
  10-point/five-hour session budget; adding accounts cannot hide that card.
- Claude Code can supply account-wide quotas through its CLI. Personal status-line
  and desktop-history fallbacks, empty Session/Week rows and account invalidation
  remain. Fresh CLI readings take priority; older observations expire without
  inventing replenished percentages. The weekly reset-schedule correction is kept.
- Usage archive format is 6, combining upstream's Codex thread metadata with the
  fork's pending-input metadata. Question text and command/patch contents remain
  excluded. Existing invalidation/re-read behavior applies to older archives.
- The island's top-band layout, period selection, shortcuts and notch sizing
  changes retain Usage Timeline navigation, per-provider timers/colors, Input
  badges, persistent prompts and Gemini/Antigravity cards. The new release-digest
  switch also recognizes the personal Usage Timeline feature.
- Accepted upstream screenshot canvas/spotlight/image layers, scratchpad tasklists,
  clipboard compact/search controls and sensitive-text preference migration,
  mixer/headphone/input improvements, window/switcher fixes, auto-quit visibility,
  snippet completion, uninstall handling, updater handoff and feature digest.
  Review emphasized settings, storage, lifecycle and callers of personal code;
  automated checks and compilation cover more than the manually inspected patches.

The personal default values remain, including opt-in Gemini/Antigravity and
Usage Timeline collection. Developer identity/update isolation, writable module
caches, CPU-count fallback and icon regeneration remain. Upstream privacy
disclosures were combined with the personal timeline, hook and in-memory prompt
disclosures; the quota guide now explains the combined Claude reader.

## Validation

| Check | Result |
| --- | --- |
| Pre-merge agents + Usage Timeline | 920 + 48 = 968 checks passed |
| Merged agents + Usage Timeline | 1,050 + 48 = 1,098 checks passed |
| `python3 Tests/CodexInputHookTests.py` | 7 tests passed |
| `./build.sh --dev` | Passed; complete Developer app compiled and bundled |
| `./build/VorssaintDeveloper --selftest` in user's Terminal | User supplied `SELFTEST OK` |
| `./build/metrics-tests` in user's Terminal | User supplied `TESTS OK (113150 checks)`; every suite passed |
| Personal-path audit | No missing paths; complete dispositions below |
| Conflict/whitespace checks | No remaining conflict markers or whitespace errors |

The full test and selftest results above are the user's Terminal output from the
merged binaries built during this integration. Later source edits only restored
reader comments/formatting; remaining edits were documentation. The Terminal run
included nonfatal macOS sandbox-extension and text-layout diagnostics but ended
with every suite passing.

Inside the agent sandbox, targeted checks passed but the build test wrapper could
not clean three test preference plists. Selftest could not read swap memory or
uptime. Broader runs hit pasteboard, type registration, AppleScript, window-service
and recorder restrictions. A separate `git archive P` source snapshot built the
pre-merge tests: the same 92 failures appeared in clipboard/app-management/mixer/
updates/repository, and the same seven notch failures appeared before the merge.
The new transient-paste suite also failed under sandboxed pasteboard access.
These sandbox runs were not treated as passing; the subsequent normal Terminal
run resolved the validation gate.

The build used ad-hoc signing after the stable signing identity was unavailable,
and the existing ICNS fallback because `actool` was unavailable. Compilation and
fixtures do not establish every live UI/hardware interaction. Live optional Codex
PermissionRequest delivery and generic Claude/Gemini approval dialogs remain
unverified, as documented in [AI-INPUT-NOTICES.md](AI-INPUT-NOTICES.md).

## Personal path inventory

The following inventory accounts for every path in `B..P`. “Unchanged” means
identical file contents to P. Overlapping paths were also compared against U;
retained personal behavior is described explicitly rather than inferred from a
successful textual merge.

| Personal path | Disposition |
| --- | --- |
| `.gitignore` | Personal ignore entries retained alongside upstream additions. |
| `CONTRIBUTING.md` | Unchanged. |
| `README.md` | Personal fork maintenance pointer retained alongside upstream documentation. |
| `Sources/Vorssaint/App/AppDelegate.swift` | Timeline flush-on-termination retained with upstream app lifecycle updates. |
| `Sources/Vorssaint/App/FeatureRuntime.swift` | Unchanged. |
| `Sources/Vorssaint/Core/Defaults.swift` | All personal keys/defaults retained; new Codex-profile keys combined. |
| `Sources/Vorssaint/Core/FeatureCatalog.swift` | Unchanged. |
| `Sources/Vorssaint/Core/FeaturePresets.swift` | Unchanged. |
| `Sources/Vorssaint/Core/NotchAgentQuotaStrings.swift` | Unchanged. |
| `Sources/Vorssaint/Core/NotchAgentStrings.swift` | Input alert and waiting-state strings retained. |
| `Sources/Vorssaint/Core/NotchEditorStrings.swift` | Unchanged. |
| `Sources/Vorssaint/Core/SettingsBackupSupport.swift` | Timeline paused state stays excluded from backups; upstream account exclusions retained. |
| `Sources/Vorssaint/Core/UsageTimelineStrings.swift` | Unchanged. |
| `Sources/Vorssaint/Services/AgentUsage/AgentAntigravityReader.swift` | Unchanged. |
| `Sources/Vorssaint/Services/AgentUsage/AgentAntigravityUsage.swift` | Unchanged. |
| `Sources/Vorssaint/Services/AgentUsage/AgentClaudeAppUsage.swift` | Unknown/expired readings retain empty rows; upstream weekly reset schedule adopted. |
| `Sources/Vorssaint/Services/AgentUsage/AgentClaudeStatusLineUsage.swift` | Unchanged. |
| `Sources/Vorssaint/Services/AgentUsage/AgentCodexInputHook.swift` | Unchanged. |
| `Sources/Vorssaint/Services/AgentUsage/AgentCodexSessionBudget.swift` | Unchanged. |
| `Sources/Vorssaint/Services/AgentUsage/AgentLogParser.swift` | Personal state and Gemini parser retained; other input-aware parsers moved into Harness readers. |
| `Sources/Vorssaint/Services/AgentUsage/AgentPricing.swift` | Unchanged. |
| `Sources/Vorssaint/Services/AgentUsage/AgentUsageArchive.swift` | Format 6 includes both input metadata and Codex thread metadata; prompt text excluded. |
| `Sources/Vorssaint/Services/AgentUsage/AgentUsageModels.swift` | Unchanged. |
| `Sources/Vorssaint/Services/AgentUsage/AgentUsageService.swift` | Quota loop, hook polling, personal budget and account invalidation combined with CLI/profile services. |
| `Sources/Vorssaint/Services/AgentUsage/AgentUsageStore.swift` | Input transitions, heartbeats and Gemini path context retained with Codex parent tracking. |
| `Sources/Vorssaint/Services/AgentUsage/AgentUsageSummary.swift` | Personal display behavior retained; added Claude CLI idle-window expiry handling. |
| `Sources/Vorssaint/Services/Notch/NotchAgentSupport.swift` | Personal provider/timer/input support retained; default budget card remains beside added accounts. |
| `Sources/Vorssaint/Services/Notch/NotchService.swift` | Persistent input notices and quota-only provider visibility retained in upstream lifecycle. |
| `Sources/Vorssaint/Services/Notch/NotchSupport.swift` | Timeline module, shortcut, availability and page-height routing retained. |
| `Sources/Vorssaint/Services/UsageTimeline/UsageFocusCollector.swift` | Unchanged. |
| `Sources/Vorssaint/Services/UsageTimeline/UsageFocusSupport.swift` | Unchanged. |
| `Sources/Vorssaint/Services/UsageTimeline/UsageTimelineModels.swift` | Unchanged. |
| `Sources/Vorssaint/Services/UsageTimeline/UsageTimelineService.swift` | Unchanged. |
| `Sources/Vorssaint/Services/UsageTimeline/UsageTimelineStore.swift` | Unchanged. |
| `Sources/Vorssaint/UI/MenuPanel/MenuPanelView.swift` | Timeline utility action, visibility and ordering retained. |
| `Sources/Vorssaint/UI/MenuPanel/PanelLayout.swift` | Unchanged. |
| `Sources/Vorssaint/UI/Notch/NotchAgentComponents.swift` | Unchanged. |
| `Sources/Vorssaint/UI/Notch/NotchAgentStrip.swift` | Unchanged. |
| `Sources/Vorssaint/UI/Notch/NotchAgentsView.swift` | Unknown quota rows, Gemini/AGY and Input displays retained; new account cards and period UI combined. |
| `Sources/Vorssaint/UI/Notch/NotchCapsuleViews.swift` | Per-provider readouts and waiting marks retained. |
| `Sources/Vorssaint/UI/Notch/NotchUsageTimelineView.swift` | Unchanged. |
| `Sources/Vorssaint/UI/Notch/NotchView.swift` | Timeline page and title routing retained in new island layout. |
| `Sources/Vorssaint/UI/Settings/FeatureHubSettings.swift` | Unchanged. |
| `Sources/Vorssaint/UI/Settings/FeatureVisibilitySupport.swift` | Unchanged. |
| `Sources/Vorssaint/UI/Settings/NotchAgentsSettings.swift` | Gemini/AGY and input-alert controls retained beside new account settings. |
| `Sources/Vorssaint/UI/Settings/NotchContentEditor.swift` | Timeline preview, localized summary and tint retained. |
| `Sources/Vorssaint/UI/Settings/NotchSettings.swift` | Timeline settings route and feature mapping retained. |
| `Sources/Vorssaint/UI/Settings/SettingsDirectory.swift` | Unchanged. |
| `Sources/Vorssaint/UI/Settings/SettingsView.swift` | Timeline settings page retained. |
| `Sources/Vorssaint/UI/UsageTimeline/UsageTimelineSettings.swift` | Unchanged. |
| `Sources/Vorssaint/UI/UsageTimeline/UsageTimelineWindow.swift` | Unchanged. |
| `Tests/AgentAntigravityTests.swift` | Unchanged. |
| `Tests/AgentClaudeAccountTests.swift` | Existing assertions retained; fixture adds new CLI account-limit state. |
| `Tests/AgentCodexInputHookTests.swift` | Unchanged. |
| `Tests/AgentCodexInputLogTests.swift` | Unchanged. |
| `Tests/AgentInputStateTests.swift` | Unchanged. |
| `Tests/AgentPersistentInputTests.swift` | Unchanged. |
| `Tests/AgentPersonalLimitsTests.swift` | Unchanged. |
| `Tests/AgentProviderInputLogTests.swift` | Unchanged. |
| `Tests/AgentUsageArchiveTests.swift` | Personal persistence assertions retained; reflected field sets include both metadata additions. |
| `Tests/AgentUsageEventDeliveryTests.swift` | Unchanged. |
| `Tests/AgentUsageReadTests.swift` | Personal startup-budget replay checks retained beside upstream Codex-thread checks. |
| `Tests/CodexInputHookTests.py` | Unchanged. |
| `Tests/FeatureCatalogTests.swift` | Timeline catalog and opt-in installation assertions retained. |
| `Tests/MetricsTests.swift` | Timeline suite remains registered; upstream suites added. |
| `Tests/NotchAgentTests.swift` | All personal suites remain registered alongside new upstream reader/account suites. |
| `Tests/NotchHoverTests.swift` | Unchanged. |
| `Tests/NotchTests.swift` | Timeline module availability/navigation checks retained. |
| `Tests/UsageTimelineTests.swift` | Unchanged. |
| `Tests/generate_sources.py` | Personal source extraction retained; Claude fixtures extract combined production methods. |
| `Tools/codex-input-hook.py` | Unchanged. |
| `build.sh` | Personal sources/cache/CPU/icon handling retained alongside upstream source additions. |
| `docs/AI-INPUT-NOTICES.md` | Unchanged. |
| `docs/AI-USAGE-NEXT-STEPS.md` | Unchanged. |
| `docs/AI-USAGE-QUOTAS.md` | Updated combined Claude source behavior and default Codex card; clarified separate Gemini transcripts. |
| `docs/FORK-MAINTENANCE.md` | Preservation workflow retained; linked this report and recorded new reader/card integration points. |
| `docs/FORK-SETUP-PLAN.md` | Unchanged. |
| `docs/PERMISSIONS.md` | Timeline Accessibility and screen-recording distinction retained. |
| `docs/PRIVACY.md` | Timeline, input metadata, hook and quota disclosures retained with upstream CLI/browser disclosures. |
| `docs/USAGE-TIMELINE.md` | Unchanged. |
| `docs/ai-usage-reference/.gitignore` | Unchanged. |
| `docs/ai-usage-reference/Package.swift` | Unchanged. |
| `docs/ai-usage-reference/README.md` | Unchanged. |
| `docs/ai-usage-reference/Resources/Info.plist` | Unchanged. |
| `docs/ai-usage-reference/SNAPSHOT.md` | Unchanged. |
| `docs/ai-usage-reference/Scripts/agy-status.py` | Unchanged. |
| `docs/ai-usage-reference/Scripts/claude-statusline.py` | Unchanged. |
| `docs/ai-usage-reference/Scripts/install.sh` | Unchanged. |
| `docs/ai-usage-reference/Sources/AIUsageBar/AppDelegate.swift` | Unchanged. |
| `docs/ai-usage-reference/Sources/AIUsageBar/Brand.swift` | Unchanged. |
| `docs/ai-usage-reference/Sources/AIUsageBar/ClaudeSource.swift` | Unchanged. |
| `docs/ai-usage-reference/Sources/AIUsageBar/Diagnostics.swift` | Unchanged. |
| `docs/ai-usage-reference/Sources/AIUsageBar/Formatting.swift` | Unchanged. |
| `docs/ai-usage-reference/Sources/AIUsageBar/GaugeRenderer.swift` | Unchanged. |
| `docs/ai-usage-reference/Sources/AIUsageBar/GeminiSource.swift` | Unchanged. |
| `docs/ai-usage-reference/Sources/AIUsageBar/LocalTrust.swift` | Unchanged. |
| `docs/ai-usage-reference/Sources/AIUsageBar/Models.swift` | Unchanged. |
| `docs/ai-usage-reference/Sources/AIUsageBar/PanelView.swift` | Unchanged. |
| `docs/ai-usage-reference/Sources/AIUsageBar/Preview.swift` | Unchanged. |
| `docs/ai-usage-reference/Sources/AIUsageBar/UsageRowView.swift` | Unchanged. |
| `docs/ai-usage-reference/Sources/AIUsageBar/main.swift` | Unchanged. |
| `docs/ai-usage-reference/snapshot-manifest.json` | Unchanged. |
| `plan.md` | Unchanged. |
| `usage_tracker_implementation_plan.md` | Unchanged. |
