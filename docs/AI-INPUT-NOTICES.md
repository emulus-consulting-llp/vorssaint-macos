# Agent input notices

Input notices stay on the closed island while an agent is waiting. Answering,
resuming work or ending the task clears them. Temporary system feedback can
cover a prompt; it returns when that feedback ends. Enable **Settings → Dynamic
Island → Content → AI Agents → When input is required**.

Claude Code `AskUserQuestion` and Antigravity `ask_question` calls come from their
local transcripts. Antigravity session questions currently use the Gemini
provider; the separate Antigravity toggle controls its Claude/GPT quota card.

Codex questions and explicit escalated command calls are also in its transcript.
A file-edit call does not say whether Codex showed a permission dialog. The
optional local approval hook supplies an explicit signal:

```sh
python3 Tools/codex-input-hook.py --install
```

The installer preserves existing entries in `~/.codex/hooks.json`, saves a
backup before changing it and adds file-edit approval/result/session lifecycle hooks.
The helper is copied to `~/.aiusage/codex-input-hook.py`. **Type `/hooks` inside
Codex, review the new helper entries, and trust and enable them.** Untrusted
hooks do not run. Reinstalling Vorssaint or resuming Codex alone does not grant
this trust. The hook emits no permission decision and does
not approve tools or alter sandbox rules.

Only session IDs, tool-call IDs or SHA-256 request fingerprints, an approval kind and request times are written
to `~/.aiusage/codex-input.json`, readable by your account. Commands, patches,
paths, prompts and results are excluded. Vorssaint checks the file about every
two seconds while following live sessions, joins approvals to their original
session and expires abandoned requests after six hours. A live test must verify
that your Codex build emits PermissionRequest for file edits; unsupported hooks
leave transcript-based detection available.

Codex 0.163 omits a call ID from PermissionRequest but supplies one in
PostToolUse. The helper hashes the shared turn/tool/input fields to correlate
these events, without storing the input itself. Matching the request fingerprint
also prevents an unrelated edit from dismissing a pending approval.

To uninstall, first complete or dismiss pending approvals. Remove the entries
whose command names `codex-input-hook.py` from the configuration, preserving
agent-guard and other hooks. The helper and its `codex-input.json` and
`codex-input.lock` files can then be removed from `~/.aiusage`.
