# Maintaining your personal Vorssaint fork

Your active personal branch is `personal/ai-usage`; `community` tracks the tested
community baseline. `main` and `ai-usage-tracker` preserve the original history.
The [AI usage customization](AI-USAGE-QUOTAS.md) lives on the aligned personal branch.

| Name | Meaning |
| --- | --- |
| `origin` | Your GitHub fork: `emulus-consulting-llp/vorssaint-macos` |
| `upstream` | Community source: `vorssaint/vorssaint-utils` |
| `main` | Preserved original community code, with no personal feature changes |
| `ai-usage-tracker` | Preserved work before history alignment |
| `community` | Clean, tested community baseline |
| `personal/ai-usage` | Active personal code, plans and documentation |

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

Have your coding assistant follow this routine whenever you want an update:

1. Save and push current personal work. Start with a clean working tree and fetch
   both remotes. Check whether `origin/personal/ai-usage` contains newer work from
   another machine and reconcile it before starting. Note the community commit
   being tested; preferably choose an upstream stable release's commit.
2. Confirm `community` remains an ancestor of the selected upstream commit. If
   history has been rewritten again, review a new alignment instead of forcing a
   merge. Create a new integration branch **from `personal/ai-usage`**, then merge the
   selected upstream commit. For the latest development code, use `upstream/main`.
3. Resolve overlapping changes while preserving the desired personal behavior.
   If abandoning an in-progress merge, use `git merge --abort`. Leave the personal
   branch untouched until validation passes.
4. Run the appropriate tests, build the Developer app, run its selftest, and
   inspect the changed UI. Follow [CONTRIBUTING.md](../CONTRIBUTING.md) for checks.
   For AI usage changes, the starting commands are:

   ```sh
   ./build.sh --test-suite=agents
   ./build.sh --dev
   ./build/VorssaintDeveloper --selftest
   ```

   Broader community changes require their relevant tests and, as appropriate,
   `./build.sh --test`. Passing a source merge alone is not a successful update.
5. After validation, fast-forward `personal/ai-usage` to the tested integration
   branch and push it to `origin`. If personal work advanced during testing,
   integrate that work and validate again before promotion. Never force-push to
   make an update fit.
6. Advance `community` only by fast-forward to the selected community commit and push
   it to `origin/community`. Never merge your personal branch into `community`. If the
   fast-forward is refused, investigate the branch history instead of resetting it.
7. Rebuild and install the tested personal app when you are ready to use it.

For example, step 2 for the latest development code is:

```sh
git switch personal/ai-usage
git switch -c integrate/community-YYYYMMDD
git merge upstream/main
```

Use a new branch name each time. The example assumes history alignment, fetching, and the clean-tree
checks above are already complete. Community changes may require manual conflict
resolution, especially when they modify the same AI usage code.

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
