#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

import contextlib
import importlib.util
import io
import json
import multiprocessing
from pathlib import Path
import stat
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("codex_input_hook", Path(__file__).resolve().parents[1] / "Tools/codex-input-hook.py")
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


class CodexInputHookTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="vorss-input-hook-")
        self.home = Path(self.folder.name)

    def tearDown(self):
        self.folder.cleanup()

    def send(self, event, call="edit", session="s", **extra):
        hook.update(self.home, dict(hook_event_name=event, session_id=session,
                                   tool_use_id=call, tool_name="apply_patch", **extra), now=1_800_000_000)

    def read(self):
        return json.loads((self.home / ".aiusage/codex-input.json").read_text())["sessions"]

    def test_lifecycle_and_metadata_only(self):
        self.send("PermissionRequest", tool_input={"patch": "private invented patch contents"}, cwd="/private/project")
        self.assertEqual(self.read(), {"s": [{"id": "edit", "kind": "edit", "at": 1_800_000_000}]})
        self.assertNotIn("private", (self.home / ".aiusage/codex-input.json").read_text())
        self.assertEqual(stat.S_IMODE((self.home / ".aiusage/codex-input.json").stat().st_mode), 0o600)
        self.send("PostToolUse", call="unrelated")
        self.assertIn("s", self.read())
        self.send("PermissionRequest", call="second")
        self.send("PostToolUse")
        self.assertEqual([r["id"] for r in self.read()["s"]], ["second"])
        self.send("PostToolUse", call="second")
        self.assertEqual(self.read(), {})

    def test_ordinary_edits_do_not_request_input(self):
        self.send("PreToolUse")
        self.assertFalse((self.home / ".aiusage/codex-input.json").exists())
        self.send("PostToolUse")
        self.assertEqual(self.read(), {})

    def test_native_permission_without_call_id_matches_real_post_tool_use(self):
        # Keys follow Codex 0.163's embedded permission-request.command.input
        # and post-tool-use.command.input schemas, which have different IDs.
        first = dict(session_id="s", turn_id="turn", tool_name="apply_patch",
                     tool_input={"patch": "invented private patch A"})
        second = dict(first, tool_input={"patch": "invented private patch B"})
        hook.update(self.home, dict(first, hook_event_name="PermissionRequest"))
        hook.update(self.home, dict(second, hook_event_name="PermissionRequest"))
        self.assertEqual(len(self.read()["s"]), 2)
        self.assertNotIn("invented private", (self.home / ".aiusage/codex-input.json").read_text())
        unrelated = dict(first, tool_input={"patch": "unrelated ordinary edit"})
        hook.update(self.home, dict(unrelated, hook_event_name="PostToolUse", tool_use_id="other-call"))
        self.assertEqual(len(self.read()["s"]), 2)
        hook.update(self.home, dict(first, hook_event_name="PostToolUse", tool_use_id="actual-call-1"))
        self.assertEqual(len(self.read()["s"]), 1)
        hook.update(self.home, dict(second, hook_event_name="PostToolUse", tool_use_id="actual-call-2"))
        self.assertEqual(self.read(), {})

    def test_cancellation_and_completion_clear_only_their_session(self):
        for event in ("Stop", "Interrupt", "UserPromptSubmit", "SessionEnd"):
            self.send("PermissionRequest")
            self.send("PermissionRequest", session="other")
            self.send(event)
            self.assertEqual(set(self.read()), {"other"})

    def test_expiry_and_bounded_state(self):
        self.send("PermissionRequest")
        hook.update(self.home, {"hook_event_name": "PermissionRequest", "session_id": "fresh",
                                "tool_name": "Bash", "tool_use_id": "cmd"}, now=1_800_000_000 + hook.MAX_AGE)
        self.assertEqual(set(self.read()), {"fresh"})
        for index in range(25):
            self.send("PermissionRequest", call=str(index))
        self.assertEqual(len(self.read()["s"]), 16)

    def test_parallel_hooks_preserve_other_sessions(self):
        processes = [multiprocessing.get_context("fork").Process(target=hook.update, args=(self.home,
                     {"hook_event_name": "PermissionRequest", "session_id": str(index), "tool_name": "apply_patch",
                      "turn_id": "turn", "tool_input": {"patch": "invented"}}))
                     for index in range(8)]
        for process in processes:
            process.start()
        for process in processes:
            process.join(5)
            self.assertEqual(process.exitcode, 0)
        self.assertEqual(len(self.read()), 8)

    def test_install_preserves_hooks_and_is_idempotent(self):
        config = self.home / ".codex/hooks.json"
        config.parent.mkdir()
        original = {"description": "keep", "hooks": {"PermissionRequest": [{"matcher": "Bash", "hooks": [
            {"type": "command", "command": "existing-guard", "timeout": 30}]}]}}
        config.write_text(json.dumps(original))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            hook.install(self.home)
            first = config.read_bytes()
            hook.install(self.home)
        self.assertEqual(config.read_bytes(), first)
        saved = json.loads(first)
        self.assertEqual(saved["hooks"]["PermissionRequest"][0], original["hooks"]["PermissionRequest"][0])
        self.assertEqual(saved["hooks"]["PermissionRequest"][1]["matcher"], "apply_patch")
        self.assertEqual(saved["hooks"]["PostToolUse"][0]["matcher"], "apply_patch")
        self.assertEqual(saved["description"], "keep")
        self.assertEqual(len(list(config.parent.glob("hooks.json.vorssaint-backup-*"))), 1)
        self.assertEqual(set(saved["hooks"]), set(hook.EVENTS))
        self.assertIn("/hooks inside Codex", output.getvalue())
        self.assertIn("Trust and enable", output.getvalue())


if __name__ == "__main__":
    unittest.main()
