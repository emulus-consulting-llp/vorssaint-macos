# Gemini and Antigravity limits in this personal fork

In the Developer app, open **Settings → Dynamic Island → AI agents** and enable
Gemini, Antigravity, or both. They are off by default. The AI page shows the
five-hour and weekly allowances and their reset countdowns when available.

- **Gemini** is the Gemini model pool inside Antigravity.
- **Antigravity** is the Claude/GPT model pool inside Antigravity.

These cards do not measure a separate Gemini web-app subscription or your Anthropic
subscription. Existing Claude, Codex, OpenCode and Copilot behavior is preserved.
Gemini/Antigravity quotas do not create token counts, costs, model breakdowns or
live activity. With only these providers enabled, the page shows limit cards only.
Warning and reset notifications for these two pools are deferred; existing
providers retain their notifications.

## Claude and Codex session bars

**Claude** shows its five-hour session and weekly limit from the newer of two local
readings: the Claude app's saved plan history, or `~/.aiusage/claude.json`, which
the personal Claude Code status line hook from the ai-usage-bar prototype writes on
every render. That file carries exact renewal times. It is as fresh as Claude Code's
last render; after 30 minutes the bars dim. A window that has since renewed has
spent an unknown amount, so its percentage is not shown: the card keeps its
**Session** and **Week** rows with an empty bar and a dash until the next reading,
and the session counts down to the end of Claude Code's current five-hour block
when there is one. Without a reading from the last seven days, the card keeps its
previous estimated-session behavior.

**Codex** plans that report only a weekly window gain a **Session** bar from a
personal budget: 10 percentage points of the weekly window per five-hour session. A
session starts at the first reading that shows the weekly window went up and ends
five hours later. 100% means those 10 points are spent. Codex itself does not
enforce this; it is computed from the weekly readings Codex writes to its session
logs, and plans with their own five-hour window are left unchanged. A new week
counts what it already shows. A banked reset or an account change starts the count
again. The budget is display-only and sends no notifications. Its state is kept in
`codex-session-budget.json` beside the usage archive, so a relaunch keeps the
running session.

## Reading states

The app checks when the feature starts, when the AI page opens, and about once a
minute while the feature is active. It shows a loading or unavailable message
when there is no usable observation. Open Antigravity and use its signed-in session
to make its language server available, then reopen the AI page to retry.

If a refresh fails, the latest known reading is shown dimmed with a **Cached**
badge. Hover over a card to see when it was observed. A local prototype cache can
also supply a fallback, but rereading that file never makes the observation newer.
Once a quota window expires, its row waits for an updated reading instead of
claiming the allowance has replenished. The closed island likewise stops using
expired windows. These are last-known readings, not guaranteed account balances.

## Local connection and limitations

The reader identifies Antigravity `language_server`, `language_server_macos`, or
`language_server_macos_arm` processes whose executable paths contain Antigravity.
It verifies their executable paths and listening ports, then asks the local
`RetrieveUserQuotaSummary` RPC for limits. Unsupported installation paths may
remain unavailable. Discovery does not launch Antigravity, install hooks, or
change its settings.

Up to three candidate processes are tried in descending PID order, and one
responding process supplies both pools. The app does not merge different servers'
responses or identify which account a server belongs to. If multiple Antigravity
accounts are running, stop the unwanted session before relying on the result.
Cached readings may belong to the previously used account.

Requests go only to verified numeric loopback listeners. Redirects are rejected,
response sizes and request times are bounded, and self-signed HTTPS certificates
are accepted only for that exact local listener. Tokens are read from the running
process arguments and kept in memory; they are not logged or saved. Antigravity
may contact its own service to answer the quota request.

The existing `~/.aiusage/gemini.json` file is read as a fallback when present. This
fork does not write that file or read credentials from the prototype's endpoint
cache. Limits may be saved in the app's existing local usage archive; credentials
are never included. Disabling the feature or pausing it cancels its quota requests.

This is an undocumented, best-effort integration. Antigravity updates can change
the process layout or response schema; unavailable data is preferred to invented
percentages. Only the four established bucket IDs and explicit valid fractional
allowances are understood.
