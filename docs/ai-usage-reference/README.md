# AI Usage Bar

A macOS menu bar app showing how much of your **5-hour** and **weekly** limits are left for
**Claude** and for **Gemini** (via Antigravity).

Collapsed, it shows average 5-hour consumption as a crisp ring gauge plus the number, floating
cleanly in the menu bar in full compliance with Apple Human Interface Guidelines (HIG):

```
◔ 69%
```

Clicking it opens a popover, one bar per limit:

```
┌──────────────────────────────────────────┐
│  Next 5 hours                            │
│  [✳]  Claude    resets at 8:30 PM    20% │
│       ▬▬▭▭▭▭▭▭▭▭                         │
│  [✦]  Gemini    resets at 8:44 PM     5% │
│       ▬▭▭▭▭▭▭▭▭▭                         │
│  [∧]  Antigravity  resets at 9:43 PM  0% │
│       ▭▭▭▭▭▭▭▭▭▭                         │
│                                          │
│  This week                               │
│  [✳]  Claude   resets Tue, 9:30 AM   19% │
│       ▬▬▭▭▭▭▭▭▭▭                         │
│  [✦]  Gemini   resets Sat, 3:12 AM   38% │
│       ▬▬▬▬▭▭▭▭▭▭                         │
│  [∧]  Antigravity resets Wed, 4:01 PM 0% │
│       ▭▭▭▭▭▭▭▭▭▭                         │
│                                          │
│  Claude live · Gemini live  [⟳ Refresh] Quit │
└──────────────────────────────────────────┘
```

Right-click the menu bar item for **Refresh Now**, **Open at Login** and **Quit** — a popover can't
host menu items, so those live in a context menu.

### How it looks, and why

**Two colour channels that never collide.** The bar says *who* — Claude clay, Gemini blue,
Antigravity grey. The percentage says *how urgent* — amber past 70% used, red past 90%. Keeping
them separate means brand colour never has to be given up to show a warning: Gemini reads blue at
81% with an amber number. The menu bar ring is an average across providers, so it belongs to no
brand and carries only the tone.

**The neutral ring is a template image.** macOS tints template images to match the menu bar
automatically, so light mode, dark mode and the highlighted-while-open state are handled by AppKit
rather than by guessing the appearance. Amber and red opt out — colour is the point of them.

**Native menu bar transparency.** Conforming to macOS 27 and modern Apple HIG, the status item has
no artificial rectangular box or chip container. It floats directly on the menu bar's vibrancy and
seamlessly accepts the native macOS selection capsule (`NSStatusBarButton.isHighlighted`) while the
popover is open.

**Standard 22pt status item sizing.** Sized to macOS's standard 22pt working area with an optically
balanced 14pt ring (1.45pt stroke) matching SF Symbols visual weight, paired with 12pt SF Pro
monospaced tabular digits.

**The popover's backdrop is pinned to its active state.** A popover's frame view is itself an
`NSVisualEffectView`, shipped with `state == .followsWindowActiveState`, and a menu bar popover is
shown before activation lands — the window is measurably not key at the moment its content is
installed. Left alone it opens in the material's inactive, more transparent form and only settles
once something makes the window key, which reads as "still loading" when it is in fact fully drawn.

**Reset times name the moment, not the interval.** The 5-hour window reads `resets at 8:30 PM`:
that's the thing you plan around, and `in 4 hr` threw away the minutes that decide it. Inside the
last hour it flips to `resets in 18 min`, where "soon" is the answer and a clock time would make you
do the subtraction yourself. The weekly window stays relative while that's useful — `resets in
18 min`, then `resets in 4 hr` — and becomes `resets Thu, 2:54 PM` past half a day, where a weekday
reads better than "in 3 days".

**The gauge fill is clipped, not rounded.** Rounding the fill itself makes anything narrower than
the bar's own height collapse to a dot, hiding real differences at the low end.

**The number occupies a fixed-width field**, so the menu bar item doesn't resize as the value
changes and shove everything else sideways.

**Stale readings dim rather than disappear** — mark, bar and percentage all recede. The number stays
visible, since usage barely moves while a tool is idle, but it never presents itself as current.

**Rows with no reading show text and no bar.** An empty bar reads as "exhausted", the opposite of
"we couldn't ask".

**Logos.** Antigravity's is the real mark, its path lifted from `jetski-logo-black.svg` inside the
installed app. Claude's and Gemini's are deliberately generic marks in each brand's colour — no
asset for either ships on this machine, and a trademark redrawn from memory comes out subtly wrong,
which reads worse than an honest placeholder. Drop the official SVGs in to swap them.

### Which pool is which

Three separate allowances, and two of them involve Claude models.

| Row | What it is |
|---|---|
| **Claude** | Your Anthropic subscription. Claude Code and claude.ai share it. |
| **Gemini** | Gemini Flash/Pro, metered by Antigravity. One account-level pool — the Antigravity IDE and CLI share it. |
| **Antigravity** | Claude Opus/Sonnet and GPT-OSS used *inside Antigravity* ("AGY"). Provided and billed by Google, entirely separate from your Anthropic subscription. |

That last one is the trap: selecting Claude Sonnet inside Antigravity spends Google's allowance,
not your Claude plan. Antigravity calls the group "Claude and GPT models"; the underlying
`bucketId` is `3p`, for third-party.

Gemini being account-level is measured, not assumed: two language-server processes with different
CSRF tokens return identical fractions to three decimal places.

### How it looks, and why

**Colour means "pay attention".** The gauge is neutral up to 70% used, amber past it, red past 90%.
A permanently coloured menu bar item is noise, and noise is what stops a real warning from
registering.

**The neutral menu bar item is a template image.** macOS tints template images to match the menu
bar automatically, so light mode, dark mode and the highlighted-while-open state are all handled
by AppKit rather than by guessing the appearance. Amber and red opt out — colour is the point of
them — and are drawn explicitly.

**The gauge fill is clipped, not rounded.** Rounding the fill itself makes anything narrower than
the bar's own height collapse to a dot, hiding real differences at the low end. Clipping a plain
rectangle to the capsule keeps proportions true at every value.

**The number occupies a fixed-width field.** Sizing it to the current string would resize the item
as the value changed, shoving everything else in the menu bar sideways several times an hour.

**Stale readings dim rather than disappear.** Name, bar and percentage all recede, and the title
falls back to a softened fill. The number stays visible — usage barely moves while a tool is idle
— but it never presents itself as current.

**No tooltips.** The rows carry their own meaning; see the pool table above for what each is.

**Rows with no reading show text and no bar.** An empty bar reads as "exhausted", the opposite of
"we couldn't ask".

## Install

```sh
./Scripts/install.sh
```

Builds with SwiftPM (no Xcode needed), assembles `~/Applications/AIUsageBar.app`, installs a login
agent, and registers the Claude Code status line hook. Re-run it to redeploy after changes.

## Running it

It starts automatically at login. The installer registers a launch agent
(`~/Library/LaunchAgents/co.emulus.aiusagebar.plist`) with `RunAtLoad`, so macOS starts it for you
after every restart. Nothing to click.

**It does not need a terminal.** The app is a normal bundle at `~/Applications/AIUsageBar.app`,
launched by `launchd` — its parent is pid 1 and it has no controlling terminal. Closing the
terminal, quitting Claude Code, or logging out of a shell has no effect on it.

If the icon ever isn't there, any of these bring it back:

```sh
open ~/Applications/AIUsageBar.app                        # simplest
launchctl kickstart -k gui/$(id -u)/co.emulus.aiusagebar  # restart via launchd
./Scripts/install.sh                                      # rebuild + reinstall
```

Or double-click **AIUsageBar** in `~/Applications` in Finder. There's no Dock icon or app-switcher
entry by design (`LSUIElement`) — the menu bar is the whole interface. Quit it from its own menu.

What *does* depend on other things running is the freshness of the data, not the app:

- **Claude** updates whenever Claude Code renders its status line. With Claude Code closed the
  number holds and is marked stale.
- **Gemini** needs Antigravity (IDE or CLI) running, since the quota comes from its language
  server. Otherwise the rows read "Antigravity isn't running".

## Where the numbers come from

Limits are enforced server-side and appear in no local log, so each provider needs its own door.

**Claude — the Claude Code `statusLine` hook.** Claude Code pipes a JSON payload to its status line
command on every render, carrying `rate_limits.five_hour` and `rate_limits.seven_day` as
`used_percentage` + `resets_at`. `Scripts/claude-statusline.py` caches that to `~/.aiusage/claude.json`
and prints `5h:28%  7d:12%` so the hook also earns its place in your status line.

These are **account-wide subscription limits** — claude.ai in the browser draws on the same pool —
so one reading covers all your Claude usage, not just Claude Code.

**Gemini — the Antigravity language server.** `language_server_macos_arm` serves a Connect RPC on a
loopback HTTPS port:

```
POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary
x-codeium-csrf-token: <token>
{}
```

Port and token come from the server's own command line via `ps`. The token is read locally and sent
only to `127.0.0.1`; the self-signed-certificate exemption in `LocalTrust.swift` is scoped to
loopback so it can't widen into a general TLS bypass. Both flags are paired **per process** — there
are usually two language servers running and a token is only valid on its own server's port.

The response also carries Antigravity's third-party pool (its Claude/GPT models). That's shown, but
excluded from the headline average, since it isn't one of the two providers being tracked.

## Limitations

- **Claude refreshes only while Claude Code is running.** The hook fires on every render, so it's
  current while you work and goes stale overnight. Readings older than 15 minutes are dimmed,
  labelled with their age, and drop the title to `◔`. They still count toward the average — usage
  barely moves while a tool is idle — but never present themselves as current.
- **Gemini needs Antigravity (IDE or CLI) running.** Same treatment.
- The status line contract is documented and stable. The Antigravity RPC is **internal** and may
  change on any update; if it does, Gemini rows go to "unavailable" rather than showing a wrong
  number.
- proto3 JSON omits default values, so a bucket carrying neither `remainingFraction` nor
  `remainingAmount` is read as **0% remaining**. For a tool meant to predict a cutoff, the safe
  failure is warning early rather than falsely reassuring. This case has not been observed in
  practice — a depleted bucket may well serialize `0` explicitly.
- Not tracked: **opencode**. Its DB (`~/.local/share/opencode/opencode.db`) has clean per-message
  token counts, but its provider exposes no quota percentage, so there's no 5h/weekly limit to show.

## Diagnostics

```sh
.build/release/AIUsageBar --dump            # text form of exactly what the menu renders
.build/release/AIUsageBar --preview <dir>   # renders the UI to PNGs, offscreen
```

`--dump` prints the discovered language servers and the rows as text bars.

`--preview` is how the *artwork* gets checked without a screenshot: `screencapture` needs Screen
Recording permission, but drawing doesn't need the screen at all — an NSImage and an NSView can
both be rasterised into a bitmap. It writes the ring at every tone threshold and the whole popover — rendered from the real view
tree, not a second description of it — in both light and dark appearances.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/co.emulus.aiusagebar
rm -rf ~/Applications/AIUsageBar.app ~/Library/LaunchAgents/co.emulus.aiusagebar.plist
```

Then remove the `"statusLine"` key from `~/.claude/settings.json`. The installer backs that file up
as `settings.json.bak-<timestamp>` on every run.

`~/.aiusage/` holds only the cached readings and can be deleted.
