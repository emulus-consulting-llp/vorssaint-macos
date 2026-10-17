# Maintaining your personal Vorssaint fork

Your active personal branch is `personal/ai-usage`; `community` records a tested
community baseline and may lag upstream commits already merged into your personal
branch. `main` and `ai-usage-tracker` preserve the original history.
The [AI usage customization](AI-USAGE-QUOTAS.md) lives on the aligned personal branch.

| Name | Meaning |
| --- | --- |
| `origin` | Your GitHub fork: `emulus-consulting-llp/vorssaint-macos` |
| `upstream` | Community source: `vorssaint/vorssaint-utils` |
| `main` | Preserved original community code, with no personal feature changes |
| `ai-usage-tracker` | Preserved work before history alignment |
| `community` | Clean, tested community baseline |
| `personal/ai-usage` | Active personal code, plans and documentation |

**For every upstream update, follow the preservation checks below. Personal
behavior takes priority when upstream and the fork disagree. A conflict-free merge
does not establish that personal features survived.**

Normal pushes target `origin`. The local `upstream` push URL is deliberately
unusable; fetching still works. Git remote settings are local to this checkout,
so a new clone needs the upstream setup below as well.

## Day-to-day changes

Work on `personal/ai-usage`, keep commits focused, and push them to the same
branch on your fork. Future features can use separate branches based on your personal
branch and be merged back when ready. Do not put personal feature changes on
`main` or open a pull request to the original project unless you want to contribute.

For AI usage, start with `Sources/Vorssaint/Services/AgentUsage/`, the
`NotchAgent*` views in `Sources/Vorssaint/UI/Notch/`, and
`Sources/Vorssaint/UI/Settings/NotchAgentsSettings.swift`. Keep changes to shared
app infrastructure as small as practical. The existing [feature plan](../plan.md)
is historical; follow [the revised plan](AI-USAGE-NEXT-STEPS.md). The preserved
[prototype reference](ai-usage-reference/SNAPSHOT.md) is not production code.

## One-time history alignment before development

The fetch on 2026-10-12 revealed substantially rewritten community history.
`main` and `upstream/main` have 1,335 and 1,732 commits unique to their respective
histories; most are patch-equivalent. This is not an ordinary behind-only branch.
Do not use Sync fork, reset, force-push, or a mass merge to repair this checkout.

There is an exact source-equivalent anchor in the new history:

| Reference | Commit |
| --- | --- |
| Original `main` and `origin/main` | `9be00fbc` |
| Same source tree in upstream history | `dcd7c1fb` |
| Shared tree object | `c53e5418eed174aace9f725a28688a0a65524c59` |
| Upstream tip when checked | `fe24c176` |

The alignment stage created `community` at `dcd7c1fb` and a new
personal branch, `personal/ai-usage`, from that anchor. Only the final reviewed
personal files were brought over: `plan.md`, the fork setup/maintenance guides,
the prototype reference directory, and the personal ignore entries. The broken
gitlink was excluded. Application files were verified against the preserved
baseline before the new branches were committed and pushed. The existing `main`
and `ai-usage-tracker` branches remain for historical reference.

Alignment is complete and the new branches are saved to GitHub. Use
`personal/ai-usage` for personal development and `community` for the clean community
baseline. This separates history alignment from application updates.

The first update brought in 397 newer upstream commits through `fe24c176`. It
merged without conflicts and passed 115,896 automated checks, the Developer build
and its selftest. The build uses the existing fallback app icon because `actool`
is not installed. This validates compilation and automated checks, not every
upstream UI or hardware behavior. The old plan's source locations are historical.

## Bringing in community updates after alignment

Updates require combining source code, testing, and rebuilding your personal app.
GitHub's Sync fork button only updates a repository branch. It does not update
your custom branch or the app installed on your Mac. Likewise, `git pull` on
`personal/ai-usage` normally reads your fork's matching branch, not `upstream/main`.

This is the standard process for an assistant asked to review or merge community
updates. Follow the active agent-guard rules and the user's current authorization.
In DEV mode, work in place, commit completed work, and do not create/switch branches
or push unless requested. Updating source does not authorize installing the app,
changing hooks, resetting preferences, or moving other branches.

### 1. Establish fresh, recoverable inputs

- Confirm the current branch is `personal/ai-usage`, the working tree is clean,
  and no merge/rebase is in progress. Leave someone else's uncommitted work alone;
  do not auto-stash, discard it, or include it in a checkpoint commit.
- Fetch `origin` and `upstream` without tags, with network approval when required.
  **If either fetch fails, stop the new-upstream merge.** Cached refs can be
  reviewed, but must not be described as the latest remote code. A successful
  user-run fetch is also acceptable.
- Compare `HEAD` with the freshly fetched `origin/personal/ai-usage`. Reconcile
  incoming personal work before upstream integration; do not reset to either ref.
- Record full commit IDs for the personal starting point (**P**), selected
  upstream target (**U**), and their merge base (**B**) in a dated update report.
  Commands below use `P`, `U`, and `B` as placeholders for those literal IDs.
  Use `upstream/main` for a request for current development code, or the requested
  release commit. Merge the recorded ID so a later fetch cannot change the target.
- Check `community` and the previously integrated upstream target are ancestors
  of U. Derive the latter from prior merge parents/reports, not just the possibly
  older `community` pointer. If upstream rewrote history or the merge base is
  unexpected/non-unique, stop integration and explain the mismatch.
- If U is already an ancestor of P, there is nothing new to merge. Record a no-op;
  do not manufacture a merge commit. P remains the recovery point for any trial.

Useful read-only commands, run separately from this repository:

```sh
git status --short --branch
git rev-parse HEAD upstream/main origin/personal/ai-usage community
git rev-list --left-right --count HEAD...origin/personal/ai-usage
git merge-base --all P U
git log --oneline P..U
git diff --name-status --find-renames B P
git diff --name-status --find-renames B U
```

### 2. Review upstream and inventory personal changes before merging

Read the actual patches in `B..U`, group meaningful fixes/features, and flag
changes to settings, storage, providers, UI, build scripts and dependencies. Check
callers and integration points; commit titles alone are not a code review.

Inventory **every** personal change in `B..P`, including tests, build integration,
docs, ignore rules, resources and deletions. Read the personal commit history as
well. The feature table below is a starting point, not an exhaustive allowlist:
extend it for any additional customization found in the diff.

Intersect both changed-path lists, following renames, and review every overlapping
file even when Git reports no conflict. Also review upstream changes in callers
of personal code. Record how each overlap will retain personal behavior and which
test or manual check exercises it. Run the relevant existing tests on P first so
later failures can be compared against a real baseline.

### 3. Trial the merge without committing it

In the current DEV workflow, with all preconditions satisfied:

```sh
git merge --no-commit --no-ff U
```

Resolve each conflict by combining the intended upstream improvement with the
personal behavior. Do not use blanket `ours`/`theirs`, `-s ours`, `-X ours`,
`-X theirs`, or replace an entire customized file with upstream's version. Preserve
local tests; do not delete/weaken them just to accept an upstream implementation.
If upstream independently implements a personal feature, remove duplicate code
only after showing behavior equivalence in the report and checks.

If upstream's design cannot coexist with a personal requirement, keep the personal
behavior and document the adaptation. Ask the user only if the choice would change
their intended behavior or cannot be resolved from existing requirements. Never
silently drop a customization. For an abandoned trial, `git merge --abort` is
appropriate only for the merge started by this workflow, before a merge commit,
and after checking no unrelated work appeared. Do not use a hard reset.

An isolated integration branch is an option only when the user authorizes branch
creation/switching. Start it at P, apply the same checks, and promote only if the
personal branch has not advanced; otherwise integrate and validate the new work.

### 4. Audit preservation and validate the combined result

Before committing, review both directions:

```sh
git diff --cached --stat P
git diff --cached P
git diff --cached U
git diff --check
git diff --cached --check
git ls-files -u
git diff
```

The P comparison shows exactly what the update changes in the personal app. The U
comparison shows which customizations remain in the merged result. Compare that
residual diff with the original `B..P` inventory. Account for **every** personal
change as retained, adapted with equivalent behavior, or explicitly approved for
removal. Flag personal files unexpectedly equal to upstream, disappeared files,
lost test registration, and changed settings defaults. File counts alone do not
prove preservation. Stage intended conflict resolutions explicitly; require no
unmerged paths and no unintended unstaged changes.

Run at least these checks for application updates, plus suites affected by the
upstream patch (use the full suite for broad changes):

```sh
./build.sh --test-suite=agents --test-suite=usage-timeline
python3 Tests/CodexInputHookTests.py
./build.sh --dev
./build/VorssaintDeveloper --selftest
```

See [CONTRIBUTING.md](../CONTRIBUTING.md). The tests compile a subset of the app;
they do not replace the Developer build. Run checks on the merged source, not an
old executable. Inspect affected UI when feasible. Record commands, counts,
failures and unverified interaction separately. A previous session's failure is
not proof that today's failure is pre-existing: compare it with P under the same
conditions. Do not label a merge validated if a required check is blocked. If a
block cannot be resolved, preserve the review record and abort the owned trial;
report what remains rather than leaving an unexplained half-merge.

### 5. Commit and record the outcome

After validation, commit the merge on `personal/ai-usage` with a clear message and
a dated report recording P/U/B, accepted upstream changes, overlap decisions,
the personal preservation inventory, and checks/limitations. Confirm the merge
contains both P and U in its ancestry and the working tree is clean. A no-op or
blocked fetch needs only a documentation commit, not a source merge.

Push only if the user requested it, using the explicit personal branch on
`origin`; never force-push or push to `upstream`. Advance `community` only when
requested, only by fast-forward to U, and only after validating U separately:
testing the customized merged tree does not prove the clean upstream tree works.
Never merge the personal branch into `community`.

Install/relaunch the Developer app only when requested. State separately whether
source was merged, checks passed, changes were committed/pushed, and the installed
app was updated. An older running app does not establish the merged UI's behavior.

## Personal behavior that upstream updates must preserve

Update this inventory whenever a personal feature changes. Test filenames below
are under `Tests/`; their registration and generated production-source inclusion
in `MetricsTests.swift`, `generate_sources.py`, and `build.sh` must also survive.

| Area | Required behavior | Evidence to check |
| --- | --- | --- |
| Claude quotas | Keep Session and Week rows even with absent/expired data; show unknown values, not invented quota percentages or cost/elapsed substitutes. Retain usable readings across empty hook renders; invalidate them on account change/sign-out. | `AgentClaudeStatusLineUsage.swift`, `NotchAgentsView.swift`; `AgentPersonalLimitsTests.swift`, `AgentClaudeAccountTests.swift`, `NotchAgentTests.swift`; inspect missing-data UI. |
| Codex personal session | For week-only plans, keep the 10-point/five-hour personal budget, including its idle Session row and persistence. Preserve real provider sessions, chronological startup readings and account/reset handling. | `AgentCodexSessionBudget.swift`, `AgentUsageService.swift`, `AgentUsageSummary.swift`; `AgentPersonalLimitsTests.swift`, `AgentUsageReadTests.swift`. |
| Gemini / Antigravity | Preserve opt-in quota cards and bounded local discovery/cache behavior. Preserve Gemini transcript activity, token/pricing support, question decoding and session attribution separately from quota-only observations. | `AgentAntigravityReader.swift`, `AgentLogParser.swift`, `AgentPricing.swift`; `AgentAntigravityTests.swift`, `AgentUsageReadTests.swift`, `AgentProviderInputLogTests.swift`. |
| Input state and notices | Keep full question text in memory, correct pending-call matching and resume/answer cleanup; unrelated activity must not clear pending questions. Persistent closed-island notices return after temporary feedback and clear when resolved. | `AgentInputStateTests.swift`, `AgentPersistentInputTests.swift`, `AgentProviderInputLogTests.swift`, `AgentCodexInputLogTests.swift`, `NotchHoverTests.swift`; [input-notice scope](AI-INPUT-NOTICES.md). |
| Codex approval hook | Keep the optional metadata-only bridge, request/result correlation, expiry and existing-hook preservation. It must not grant approval. Fixture success does not prove live PermissionRequest delivery. | `AgentCodexInputHookTests.swift`, `CodexInputHookTests.py`, `Tools/codex-input-hook.py`; explicit live verification if available. |
| Provider display | Keep stable per-provider timers/readouts, provider colors, orange Input badges, and sufficient strip/capsule width. The Now logo row remains idle-only. | `NotchAgentSupport.swift`, `NotchAgentStrip.swift`, `NotchCapsuleViews.swift`, `NotchAgentsView.swift`; `NotchAgentTests.swift` and multi-provider UI inspection. |
| Usage Timeline | Preserve opt-in collection, native window/island views, app/document attribution, exclusions, pause/history deletion, local private storage, settings integration, and elapsed time through sleep. | `Services/UsageTimeline/`, `UI/UsageTimeline/`, `NotchUsageTimelineView.swift`; `UsageTimelineTests.swift`, affected feature/settings tests; [timeline behavior](USAGE-TIMELINE.md). |
| Privacy and build | Do not persist question text or hook command/patch contents; retain metadata-only archive lifecycle. Keep Developer identity/update isolation, writable module caches, CPU-count fallback and icon regeneration. | `AgentUsageArchiveTests.swift`, `CodexInputHookTests.py`, `build.sh`, [privacy contract](PRIVACY.md); Developer build/selftest and affected install-isolation tests. |

Known limits are part of this contract: generic Claude/Gemini approval dialogs
are not established by question-tool tests, and Codex file-edit approval delivery
depends on the runtime actually emitting the optional hook event. Do not claim
these work solely because fixtures pass. Older feature-plan prose is historical;
the current source, tests and explicit user decisions govern preservation.

## Running your version

Use the project's existing Developer variant:

```sh
./build.sh --dev --install
```

This builds and installs **Vorssaint (Developer)** with a separate app identity,
preferences, and permissions. The current code disables official update checks
for this variant. Recheck that behavior when accepting changes to the updater or
build configuration. The app must be rebuilt to receive community improvements.
An official downloaded app does not contain your private customizations.

Direct pushes to `ai-usage-tracker` do not trigger the current CI workflow. It runs
on pushes to `main` and on pull requests. A successful GitHub push therefore does
not mean the app was built or tested. Setup-only documentation/reference changes
do not require building the app. The `personal/ai-usage` and `community`
branches likewise will not trigger push CI under the existing configuration.

## Setting up another checkout

```sh
git clone https://github.com/emulus-consulting-llp/vorssaint-macos.git
cd vorssaint-macos
git switch personal/ai-usage
git remote add upstream https://github.com/vorssaint/vorssaint-utils.git
git remote set-url --push upstream https://example.invalid/upstream-push-disabled
git config --local remote.pushDefault origin
git config --local push.default simple
git fetch --no-tags upstream
```

The prototype reference is included in a clone; the full original prototype and
local backups are not. See [the snapshot notes](ai-usage-reference/SNAPSHOT.md).
The setup steps and review record are in [the setup plan](FORK-SETUP-PLAN.md).
