# AI usage customization: current implementation plan

This plan supersedes the implementation sequence in the historical `../plan.md`.
It targets community commit `fe24c176`, aligned through the source-equivalent
`dcd7c1fb` baseline. The earlier feature plan remains as research history.

## Order of work

1. Preserve the old branches. Create `community` and `personal/ai-usage` on the
   equivalent upstream history and reapply only reviewed personal files.
2. Trial the pinned community update on `integrate/community-20261012`. Run the
   full automated suite, Developer build and selftest before promoting it.
3. Add Gemini and Antigravity usage-limit/reset cards. Both are opt-in and share
   one local Antigravity quota reader. Preserve Claude, Codex, OpenCode and Copilot.
4. Test decoding, lifecycle, expired/stale readings and UI behavior; build the
   customized Developer app. Save focused commits to the personal branch.
5. Assess token/cost analytics separately only if trustworthy usage data exists.
   Quota fractions alone cannot produce token counts, spend, models or live work.

## First feature scope

- Provider order starts Claude, Gemini, Antigravity, Codex, followed by the other
  community providers. New preferences default off, including missing-key fallback.
- Gemini means the Gemini pool inside Antigravity. Antigravity means its third-party
  Claude/GPT pool. Neither is a separate Gemini web-app subscription meter.
- Enabled quota providers retain visible limit cards even when unavailable; existing
  providers retain their current visibility rules. Analytics cards exclude quota-only
  providers. SF Symbols provide the new marks.
- Read `RetrieveUserQuotaSummary` only from a validated local Antigravity process.
  Discover executable paths safely even when they contain spaces; verify PID,
  token and listening port together. Stored endpoint data is only a hint.
- Use numeric loopback URLs, reject redirects, bound candidates/request duration
  and total work, and scope self-signed trust to the validated endpoint. Never
  print or persist tokens. Select one process deterministically and never combine
  readings from separate servers/accounts.
- A shared request returns both pools. Use existing service lifecycle hooks;
  invalidate callbacks on pause, stop and provider changes. Retain original
  timestamps for cached fallback from `~/.aiusage/gemini.json`.
- Decode only established bucket IDs (`gemini-5h`, `gemini-weekly`, `3p-5h`,
  `3p-weekly`) and finite fractions between zero and one. Unsupported or missing
  fractions are unavailable, not an assumed allowance.
- Reuse `AgentLimits.Source.account`; do not change the archive schema. New source
  status distinguishes loading, cached and unavailable readings.
- Expired quota windows must wait for a fresh reading. Do not let the existing
  automatic 0%-used reset behavior fabricate new Gemini/Antigravity allowances,
  either on cards or in the closed island. Preserve existing providers' behavior.
- Add settings help, localized states, and privacy documentation. Do not install
  hooks, change agent settings, add pricing tables, or modify unrelated features.

## Review and evidence

A separate agent reviewed the updated upstream architecture and this proposed
quota-first scope on 2026-10-12. Its corrections are incorporated above: preserve
existing visibility/analytics, reuse the archive-compatible source, avoid fabricated
resets, validate discovery, and reject obsolete callbacks.

Local cache inspection confirms the four bucket IDs and response wrapper shape,
but its last observation is 2026-10-03. That is historical format evidence, not a
successful live integration check. The RPC is undocumented and remains best-effort.

Validation must cover parser fixtures (both pools, missing/invalid fields), preserved
cache timestamps, expiry, default-off preferences, paths with spaces, cancellation,
and analytics isolation. Run the agents suite and relevant preferences/localization
checks, then the Developer build/selftest. Report live UI verification separately
from fixture tests and compilation.

## Progress

- History alignment complete; both aligned branches saved to the personal fork.
- Community update merged without conflicts on the integration branch.
- Full community test suite passed: 115,896 checks plus preference cleanup,
  uninstall-spaces and Developer installation-isolation scripts.
- Developer build and selftest passed. Build used the fallback icon because
  `actool` is unavailable. No manual UI verification has been claimed.
- User confirmed usage limits and reset times first; analytics remains deferred.
- Feature implementation is next.
