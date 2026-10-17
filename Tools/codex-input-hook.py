#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
"""Forward approval lifecycle metadata to Vorssaint; never decide permissions.

Run with --install to add these hooks alongside existing Codex hooks. Hook
invocations read JSON on stdin and emit no approval decision or task content.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile
import time

EVENTS = ("PermissionRequest", "PostToolUse", "Stop", "Interrupt", "UserPromptSubmit", "SessionEnd")
MAX_AGE = 6 * 3600
MAX_BYTES = 512 * 1024


def request_fingerprint(payload):
    # Codex 0.163 PermissionRequest omits tool_use_id; PostToolUse includes it.
    # Both carry the same turn, tool and input. Retain only their digest, so
    # unrelated or simultaneous edits cannot accidentally answer this approval.
    if "tool_input" not in payload or not isinstance(payload.get("turn_id"), str):
        return None
    identity = [payload["turn_id"], payload.get("tool_name"), payload["tool_input"]]
    encoded = json.dumps(identity, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return "request:" + hashlib.sha256(encoded).hexdigest()


def write_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".codex-input-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle, separators=(",", ":"))
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def update(home, payload, now=None):
    now = time.time() if now is None else now
    event = payload.get("hook_event_name")
    session = payload.get("session_id")
    if event not in EVENTS or not isinstance(session, str) or not 0 < len(session) <= 256:
        return
    folder = home / ".aiusage"
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = folder / "codex-input.json"
    lock_fd = os.open(folder / "codex-input.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        sessions = {}
        if path.exists():
            if path.is_symlink() or path.stat().st_size > MAX_BYTES:
                return
            saved = json.loads(path.read_text())
            if saved.get("version") != 1:
                return
            sessions = saved.get("sessions", {})
        sessions = {
            key: [{"id": request["id"], "kind": request["kind"], "at": request["at"]}
                  for request in requests if isinstance(request, dict)
                  and isinstance(request.get("id"), str) and 0 < len(request["id"].encode()) <= 256
                  and request.get("kind") in ("edit", "command", "other")
                  and isinstance(request.get("at"), (int, float)) and 0 <= now - request["at"] < MAX_AGE]
            for key, requests in sessions.items() if isinstance(key, str) and isinstance(requests, list)
        }
        tool = payload.get("tool_name", "")
        call = payload.get("tool_use_id") or payload.get("tool_call_id")
        fingerprint = request_fingerprint(payload) if event in ("PermissionRequest", "PostToolUse") else None
        requests = sessions.get(session, [])
        if event == "PermissionRequest":
            call = call or fingerprint
            if not isinstance(tool, str) or not isinstance(call, str) or not 0 < len(call.encode()) <= 256:
                return
            requests = [request for request in requests if request.get("id") != call]
            # Keep an enum, never a tool's command, patch, path, arguments or result.
            kind = "edit" if tool == "apply_patch" else "command" if tool in ("Bash", "exec_command") else "other"
            requests.append({"id": call, "kind": kind, "at": now})
            sessions[session] = requests[-16:]
        elif event == "PostToolUse":
            completed = {value for value in (call, fingerprint) if isinstance(value, str)}
            sessions[session] = [request for request in requests if request.get("id") not in completed]
        else:
            sessions.pop(session, None)
        sessions = {key: requests for key, requests in sessions.items() if requests}
        sessions = dict(sorted(sessions.items(), key=lambda item: max(r["at"] for r in item[1]), reverse=True)[:64])
        write_json(path, {"version": 1, "sessions": sessions})


def install(home):
    folder = home / ".aiusage"
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    destination = folder / "codex-input-hook.py"
    if destination.is_symlink():
        raise ValueError("The hook destination must not be a symbolic link")
    config = home / ".codex/hooks.json"
    if config.is_symlink():
        raise ValueError("The hook configuration must not be a symbolic link")
    original = config.read_bytes() if config.exists() else None
    settings = json.loads(original) if original is not None else {}
    hooks = settings.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("Existing hooks must be a JSON object")
    command = "python3 " + shlex.quote(str(destination))
    changed = False
    for event in EVENTS:
        entries = hooks.setdefault(event, [])
        if not isinstance(entries, list):
            raise ValueError("Existing hook event must contain an array")
        if any(hook.get("command") == command for entry in entries for hook in entry.get("hooks", [])):
            continue
        entry = {"hooks": [{"type": "command", "command": command, "timeout": 2}]}
        if event in ("PermissionRequest", "PostToolUse"):
            entry["matcher"] = "apply_patch"
        entries.append(entry)
        changed = True
    # Validate the complete configuration before changing either destination.
    json.dumps(settings)
    if Path(__file__).resolve() != destination.resolve():
        shutil.copyfile(__file__, destination)
        destination.chmod(0o600)
    if changed:
        config.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if original is not None:
            backup = config.with_name("hooks.json.vorssaint-backup-" + time.strftime("%Y%m%d-%H%M%S"))
            with backup.open("xb") as handle:
                handle.write(original)
            backup.chmod(0o600)
        write_json(config, settings)
    print("Vorssaint approval hooks configured. Existing hooks preserved; no approval rules changed.")
    print("Activation required: type /hooks inside Codex, review the codex-input-hook.py entries, then Trust and enable them.")
    print("Untrusted hooks do not run. Reinstalling Vorssaint or resuming Codex alone does not grant hook trust.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.install:
        install(args.home)
    else:
        try:
            payload = json.loads(sys.stdin.buffer.read(8 * 1024 * 1024))
            if isinstance(payload, dict):
                update(args.home, payload)
        except (OSError, ValueError, TypeError, AttributeError):
            # A notification bridge must never block the agent's tool or decide
            # whether it may run, even if its metadata file cannot be written.
            pass


if __name__ == "__main__":
    main()
