# Usage Tracker Implementation Plan

## Goal and boundaries

Add **Usage Timeline** inside Vorssaint: collect foreground app and focused-window
activity, store history locally, and display a daily timeline in a dedicated,
resizable window launched through Utilities.

- Distinguish windows within the same app; store titles and local document paths
  when Accessibility exposes them.
- Default idle threshold: five minutes. Screen-off stops active counting immediately.
- Explicitly enable once; resume with Vorssaint launches. Remember manual pauses.
- Keep history until deleted. Collection runs independently of the switcher.
- External app integration, exports, cloud sync, browser URL integrations,
  screenshots, keystroke content and background-window inventories are out of scope.

## Collection and time accounting

Create an independent UsageTimelineService. Observe application activation and
termination, focused-window changes, window destruction and title changes. Reuse
window resolution helpers without changing the switcher's ordering or lifecycle.
Accessibility reads run on a serial background worker with a 350 ms timeout and
generation checks to reject stale replies. A five-second metadata refresh catches
unsupported notifications. Ignore transient Vorssaint activation handoffs.

Track app-level activity when Accessibility is unavailable and show “App tracking
only”; never carry old window metadata forward. Permissions changes take effect
without deleting history. The feature does not need Screen Recording permission.

Assign window UUIDs scoped to a process instance and window lifetime. Numeric
WindowServer IDs are optional hints, not sole identity; fall back to Accessibility
element identity. Title changes do not create a different window identity. Split
foreground intervals on app/window/title/path changes and coalesce duplicate reads.

Read kAXDocumentAttribute and keep local file URLs only. Do not infer paths from
titles, scan files, or add Office automation. Verify Excel and PowerPoint live.

Maintain separate foreground and presence streams; active usage is their
intersection. Sample system input idle age every two seconds. Offer 1/3/5/10
minutes or off. Once idle is confirmed, backdate it to the last input, bounded by
the uninterrupted collection period. Screen sleep, system sleep, lock and inactive
user sessions immediately block active counting. Track conditions independently;
waking the screen must not override a lock. Display priority: paused, switched-away,
sleeping, locked, screen-off, idle, excluded, active. Stop metadata reads while
paused/idle/unavailable and refresh before resuming.

Use monotonic elapsed time for durations and UTC timestamps for placement; split
on clock changes. Idle reflects system input, not attention; synthetic input and
Keep Awake may affect it and need documented live verification.

## Storage and controls

Use bundled SQLite without downloading dependencies, under the private Application
Support container at UsageTimeline/history.sqlite. Apply owner-only permissions
to its directory, database and companion files. Never log titles or paths.

Persist foreground intervals (stable ID, collection session, process/window
identity, app metadata, nullable title/path, timestamps and duration), presence
intervals (timestamps and state), collection checkpoints and schema version.
Serialize database work and index timestamps and app identity.

Write transitions transactionally and checkpoint open intervals every 15 seconds.
Flush on quit, sleep, pause and disablement. Recover interrupted intervals at the
last checkpoint and show downtime as unrecorded. Use transactional schema upgrades;
preserve unsupported/corrupt databases. A storage error stops collection and offers
Retry without inventing activity during the gap.

Internal layers: collector observations → pure accounting reducer with injectable
clocks → store for writes/day queries/totals/checkpoints/deletion → observable UI
service. No external data contract is introduced.

Settings: enabled, persistent pause, idle threshold, title/path storage (default
on) and bundle-ID app exclusions. Check exclusions before metadata reads and retain
only anonymous excluded gaps. Changes affect future records. Portable preferences
participate in backup; private history and machine-specific runtime state do not.

Confirm Delete selected day and Delete all history. Split intervals crossing day
boundaries. Stop observations, invalidate queued callbacks and drain writes before
deletion; resume at a fresh boundary with the previous enabled/paused state.
Installing alone never collects; uninstalling stops collection and preserves data.

## Interface

Register usageTimeline in the catalog, runtime, Utilities, Settings, permission
handling and every locale. Keep it opt-in on updates and exclude it from automatic
first-install enablement. Reuse one 960×640 window (minimum 680×480), existing
SwiftUI materials, app icons and light/dark appearance. Closing it keeps tracking.

- Date navigation, recording status, Pause/Resume and Settings.
- Active/away totals; separate paused, excluded and unrecorded labels.
- Horizontal day timeline with stable app colors and neutral gaps.
- App totals sorted by active duration, app filter, chronological interval list.
- Selected interval details, copyable title and document path where available.
- First-use, empty/loading, paused, app-only and storage-error states.

Filtering changes chart/list/app totals, not labeled day-wide status totals.
Respect local calendar days/DST/timezone changes. Paginate rows and update live
display only while visible. Narrow layouts move totals above the list and details
below the selection.

```text
Usage Timeline                         ● Tracking  [Pause] [Settings]
‹  Today · 14 October 2026  ›
Active 1h 15m                           Away 10m
09:00                                                      10:25
[PowerPoint][ Excel ][Away][ VS Code ][Away][Safari]

Apps                         Activity
All apps                     09:00–09:20 PowerPoint 20m
Excel          25m           Client proposal.pptx
VS Code        25m           09:20–09:45 Excel 25m
PowerPoint     20m           Project budget.xlsx
Safari          5m           09:45–09:50 Screen off 5m

Selected: Excel · Project budget.xlsx
~/Projects/Client A/Project budget.xlsx               [Copy path]
```

## Implementation and acceptance

Commit completed subtasks: collector/accounting; persistence/queries/controls;
feature/UI/localization and verification. Test activation races, same-app windows,
ID reuse, missing/changed metadata, permission revocation, retroactive idle,
overlapping away states, startup locked, pause/exclusions, midnight/DST/clock
changes, recovery/errors/permissions, boundary deletion and stale callbacks.

Run relevant build.sh test suites, full build and selftest per CONTRIBUTING.md.
Verify Finder, browser, VS Code, Excel, PowerPoint, short screen-off, lock/wake,
Keep Awake and switcher-disabled collection live. Report Mac/macOS details and
unverified interactions honestly.

Acceptance: history survives relaunch; focused windows remain distinguishable;
active totals exclude away time; missing metadata stays empty; pause stops
collection; closing the timeline leaves collection running.
