# Personal fork setup plan

Scope: make this existing fork suitable for a personal AI usage customization while
keeping community updates manageable. This is repository setup, not implementation
of the Gemini/Antigravity feature described in `../plan.md`.

## Starting state

- `origin` is `https://github.com/emulus-consulting-llp/vorssaint-macos`.
- The original project is `https://github.com/vorssaint/vorssaint-utils`.
- `main` preserves the original community baseline; work is on `ai-usage-tracker`.
- The custom branch has four local commits and no configured tracking branch.
- `temp-ai-usage-bar` is recorded as a gitlink, but there is no `.gitmodules`
  file or remote in the nested repository. A normal clone cannot recover it.
- The prototype has an uncommitted executable-bit change to `Scripts/agy-status.py`.
  There are also generated local files.

## Steps and acceptance criteria

1. **Independent review before implementation.** Have a fresh agent inspect this
   plan and the repository, identify risks and missing steps, then incorporate its
   findings. Preserve the existing feature plan.
2. **Preserve existing work.** Save a local backup of committed history, prototype
   history and its current files before changing repository configuration or the
   gitlink. Exclude only reproducible prototype build output. Keep the backup
   ignored by Git and check its contents. Include the prototype's ignored working
   notes; exclude only its `.build/` directory. Do not delete user files or reset work.
3. **Connect both repositories.** Keep `origin` pointing to the personal fork. Add
   `upstream` for fetching community code, with an unusable push destination to
   prevent accidental pushes to the community project. Fetch both repositories
   without tags, inspect branch ancestry and report how far the local baseline
   differs. Configure ordinary pushes to target `origin`. Do not merge a moving
   community branch into the user's existing work as part of setup.
4. **Make the prototype recoverable.** After backup, stop tracking the broken
   gitlink while retaining the prototype directory locally and ignoring it.
   Export its current tracked source files into a documented reference directory
   in the personal branch, excluding nested Git data, generated output, `design/`,
   PNG artwork and `Sources/AIUsageBar/LogoAssets.swift` (embedded artwork). The
   prototype README identifies artwork extracted from an installed third-party
   app; keep those originals in the local backup, not the public snapshot. Label
   the snapshot as an incomplete source reference, not a runnable application. Review
   source/history for credentials or private machine data before any publication,
   including all four existing custom commits. If sensitive history is found,
   stop publication and report it; do not silently rewrite history.
   Record the prototype commit and preserve the local executable-bit change.
5. **Document the maintenance routine.** Add a short repository guide explaining
   the two remotes and branches, where custom code belongs, and the deliberate
   fetch / merge / test / rebuild cycle. Use temporary integration branches for
   update trials based on `personal/ai-usage`, merging `upstream/main` and validating
   before promotion once histories have been aligned (see execution findings).
   Preserve original `main`; a new clean `community` branch will advance only by
   fast-forward after alignment. Explain that an
   ordinary pull on the custom branch fetches the personal fork's branch, not
   community updates, and GitHub's Sync fork button does not rebuild the
   app. Use the existing Developer build with separate preferences and disabled
   official auto-updates. No release automation or application install is needed
   for repository setup. Existing CI does not run on direct pushes to the custom
   branch; document that limitation. Ignore the observed generated files without
   removing them.
6. **Validate and save.** Check only intended files are included; validate snapshot
   fidelity (content and executable bits), documentation paths, and the resulting Git configuration. Application
   tests are unnecessary if app code has not changed. Commit the setup on the
   custom branch and push it to the personal fork with tracking, using an explicit
   branch ref and no force push or tags. Verify the remote commit matches. If
   authentication or sandbox approval prevents a step, report precisely what
   remains rather than claiming completion.

## Next development stage

First align personal work onto the equivalent upstream-history anchor documented
in `FORK-MAINTENANCE.md`, preserving existing branches. Trial newer community code
separately and validate it. Reassess the existing feature plan against that baseline and the
user's desired AI usage screen. Implement in focused commits affecting the AI
usage UI and its supporting services. Validate the existing agents tests, the
Developer build and its selftest, then manually check the changed screen before
installing the personal app. Community updates that touch the same code may need
manual conflict resolution; automatic conflict-free updates are not guaranteed.

## Review and execution record

Independent review completed by a separate agent on 2026-10-12. Approved with
amendments for executable modes, source-only snapshot exclusions, outgoing history
review, explicit integration branches, and the existing CI limitation. All five
amendments are incorporated above. A final independent review also checked the
implemented setup and branch instructions before commit/publication.

Post-fetch finding, independently reviewed: the original community baseline is
not an ancestor of the current upstream tip. The old baseline `9be00fbc` and the
upstream-history commit `dcd7c1fb` have the identical tree
`c53e5418eed174aace9f725a28688a0a65524c59`. Upstream tip `fe24c176` is 397 commits
beyond that anchor. Preserve current branches during setup; next create aligned
`community` and `personal/ai-usage` branches at the equivalent anchor, reapply the
final personal files, and validate the later application update separately.

Implemented and checked locally:

- Added `upstream`, disabled its push destination, and set normal pushes to `origin`.
- Fetched both repositories and verified that local `main` matches `origin/main`.
- Created and verified parent/prototype Git bundles plus a full prototype archive
  excluding `.build/`. The ignored backup-location file identifies the archive.
- Verified the archive against all 32 tracked prototype files and executable flags.
- Replaced the unrecoverable gitlink with 20 reference files plus snapshot notes
  and a manifest; verified every included file's content and executable flags.
- Preserved the original prototype on disk and ignored local generated output.
- Reviewed all four outgoing custom commits and the new source snapshot. No
  credential patterns were found; early historical notes retain ordinary local
  project paths. No history was rewritten.
- Checked new documentation links and staged whitespace. Application source,
  resources, tests and build scripts remain unchanged; no app tests were needed.

The setup was saved to `origin/ai-usage-tracker` and its remote commit verified.
Subsequent history alignment and the newer community update are complete; both
`community` and `personal/ai-usage` are saved to the personal fork. See
[the revised feature plan](AI-USAGE-NEXT-STEPS.md) for implementation and validation
of the Gemini/Antigravity quota cards.
