# Activity feed (contract v1)

The activity feed is how other apps on this Mac read what
[Usage Timeline](USAGE-TIMELINE.md) records, without touching its private
history. It is a personal-fork feature built for Kaizen, but any local reader
can use it. This document is the contract: readers depend on exactly what is
written here and nothing else.

Enable it in Settings → Usage Timeline → Activity feed. It is off by default.

## Location and file format

```
~/Library/Application Support/VorssaintFeed/feed.sqlite
```

- The path does not depend on the bundle ID, so the Developer and release builds
  publish to the same file. Only one of them should be running.
- SQLite in WAL mode. The directory is 0700 and the files are 0600, readable only
  by the logged-in user.
- `PRAGMA user_version` is the schema version, currently `1`. Readers must check
  it and refuse any other value.
- The feed is **derived** from private history and can be rebuilt from it at any
  time (Settings → Rebuild feed). Nothing in it is authoritative; readers keep
  their own copies of anything they need to survive.

## Reading safely

- Open without `SQLITE_OPEN_CREATE`, set `PRAGMA query_only = ON`, and never
  write. A strict `SQLITE_OPEN_READONLY` open fails while no writer is connected,
  because WAL readers need to create the `-shm` file.
- Keep each read short and set a busy timeout (500 ms is plenty). WAL means a
  reader never blocks Vorssaint's writes, and a write never blocks a reader.
- Each day is replaced inside one transaction, so a reader never sees a
  half-written day.
- **Never open** `UsageTimeline/history.sqlite`. Its layout is private, and a
  long outside read can make Vorssaint stop recording.

## Tables

All times are Unix epoch **milliseconds**, UTC.

### `activity`

Active use of one window and one document. "Active" is exactly what the Usage
Timeline window counts as active: foreground time while the user was present.

| Column | Type | Meaning |
| --- | --- | --- |
| `id` | TEXT PK | Stable for the same history; changes when history changes. Do not store it as a foreign key. |
| `start_ms` | INTEGER | Segment start. |
| `end_ms` | INTEGER | Segment end; `end_ms > start_ms`. |
| `bundle_id` | TEXT | App bundle ID; NULL for processes without one. |
| `app_name` | TEXT NOT NULL | App display name. |
| `title` | TEXT | Window title shown longest in the segment; NULL when titles are not stored or unavailable. |
| `document_path` | TEXT | Local file path from the focused window; NULL when the app exposes none or paths are not stored. |
| `open` | INTEGER | 1 while the segment is still growing; its `end_ms` will move. |

Rules:

1. Consecutive visits to the same window and document whose titles differ
   (spinners, progress counters, terminal status lines) are one segment.
2. A different window or a different document is always a new segment.
3. Segments never cross local midnight: a visit spanning midnight is two rows.
4. Segments never overlap each other.
5. Time that is not in `activity` or `presence` is unrecorded: Vorssaint was not
   running, tracking was off, or history was deleted. Never infer activity there.

### `presence`

Spans that were not active use.

| Column | Type | Meaning |
| --- | --- | --- |
| `id` | TEXT PK | As for `activity`. |
| `start_ms`, `end_ms` | INTEGER | As for `activity`. |
| `state` | TEXT | One of `idle`, `screenOff`, `locked`, `sleeping`, `switchedAway`, `paused`, `excluded`. |
| `open` | INTEGER | 1 while the span is still growing. |

`excluded` means an app on the exclusion list was in front; no details are
recorded for it.

### `meta`

| Key | Value |
| --- | --- |
| `schema_version` | `1`. |
| `writer` | Bundle ID and version of the publishing build. |
| `timezone` | IANA zone in effect at the last publish. |
| `state` | Current recording state: an `activity`/`presence` state name, `active`, `unrecorded`, `off` (tracking stopped or Vorssaint quit), or `error` (history storage failed). |
| `updated_ms` | When the feed was last written. |
| `history_from_ms` | Start of the oldest day the last rebuild covered. |

## Freshness

While tracking runs, the feed is rewritten at most every 15 seconds, and
immediately on stop, quit, deletion and rebuild. Each publish rewrites today and,
once midnight passes, the previous day. A reader can treat the feed as stale
when `state` is a recording state but `updated_ms` is more than about a minute
old; that means Vorssaint stopped without a clean quit.

History edits apply to the feed: confirmed idle withdraws time that was briefly
published as active, and deleting a day in Usage Timeline removes its rows.

## Changing this contract

Any change to tables, columns or meanings bumps `schema_version` and updates
this document in the same commit. Readers pin the version they understand.
Vorssaint replaces a feed whose version it does not recognise and rebuilds it
from history; nothing is migrated.
