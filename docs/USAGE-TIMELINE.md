# Usage Timeline

Install **Usage Timeline** from Settings → Features → Utilities. Open it from the
Utilities launcher or its Settings page, then choose **Start tracking**. Installing
it does not start recording. It collects only while Vorssaint is running and keeps
working when its window is closed or the switcher is disabled.

The daily view shows active time, away time, app totals, a timeline, and individual
window visits. Select an app to filter its visits, or an interval to inspect its
title and available document path. Unrecorded, excluded, and paused periods are
labeled separately. The day follows the current local timezone, including DST.

## Permissions and collection

App tracking needs no special permission. Accessibility enables focused-window
identity and titles. Document paths are read from the focused window only when
the app exposes a local document URL; support varies by app. Missing titles or
paths are left empty. Screen Recording and Office Automation are not required.

The default idle threshold is five minutes. Once that threshold is reached,
idle time begins at the last input. Screen-off, lock, sleep, and switching away
from your login session stop active counting immediately. Idle is an estimate
based on system input: reading, calls, videos, or synthetic mouse movements can
affect its interpretation. Choose another threshold or turn idle detection off
in Settings if needed.

Pause persists until Resume, including across relaunches. Disabling tracking or
uninstalling the feature preserves history. Closing the view does not pause it.
App exclusions are checked before reading window details and leave anonymous
excluded-time gaps. Changes to exclusions and title/path storage affect future
records, not existing history.

## Local history

The database is `UsageTimeline/history.sqlite` inside Vorssaint’s private
Application Support container. Directories are owner-only (0700); database files
are owner-only (0600). No history is sent to an external service or included in
settings backups. History has no automatic expiration.

Delete selected day and Delete all history require confirmation. Deleting a day
preserves parts of intervals on neighboring days. Collection restarts at a fresh
boundary after deletion if it was enabled and running.

On a normal quit the final intervals are flushed. An interrupted process retains
its most recent checkpoint (normally within 15 seconds); downtime is unrecorded,
not charged to the last app. A storage error stops collection and displays Retry.
Existing data is preserved, including databases with an unsupported schema.

External data consumption, exports, cloud sync, website URLs, screenshots, and
background-window inventories are outside this version.

## Implementation validation

The `usage-timeline` suite covers interval accounting, delayed callbacks, window
identity, idle classification, pause/resume state, recovery, range deletion,
private file permissions, schema preservation, the native idle API, and all 15
locales. The affected feature/settings/utilities/localization/switcher suites,
the Developer build, and its native selftest passed during implementation.

Live UI rendering, Office document-path availability, short screen-off behavior,
and Keep Awake interaction remain unverified. Native UI automation returned stale
elements and could not capture the built app’s windows in this session. These
limitations do not establish whether a particular app exposes its document path.

When trying the new Developer build, quit an older running Developer instance
before opening the newly built bundle; both use the same Developer bundle ID.
