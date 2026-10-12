#!/usr/bin/env python3
"""Claude Code statusLine hook for ai-usage-bar.

Claude Code pipes a JSON payload to its statusLine command on every render. That
payload carries `rate_limits` -- the account-wide subscription windows, the same
pool claude.ai draws on:

    "rate_limits": {
      "five_hour": { "used_percentage": number, "resets_at": number },
      "seven_day": { "used_percentage": number, "resets_at": number }
    }

They are only present for subscribers, and only after the first API response of
a session. We cache them for the menu bar app and print a compact status line so
the hook earns its place in the UI rather than just costing a render.

This must never fail the status line: every failure path still prints.
Set AIUSAGE_DEBUG=1 to also dump the full payload to ~/.aiusage/claude-raw.json.
"""

import json
import os
import sys
import tempfile
import time

CACHE_DIR = os.path.expanduser("~/.aiusage")
CACHE = os.path.join(CACHE_DIR, "claude.json")
RAW = os.path.join(CACHE_DIR, "claude-raw.json")


def write_atomic(path, obj):
    """Write JSON via temp file + rename so a reader never sees a partial file."""
    os.makedirs(CACHE_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=CACHE_DIR, prefix=".aiusage-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def window(limits, key):
    w = limits.get(key)
    if not isinstance(w, dict):
        return None
    used = w.get("used_percentage")
    if not isinstance(used, (int, float)):
        return None
    resets = w.get("resets_at")
    return {
        "used_percentage": float(used),
        "resets_at": float(resets) if isinstance(resets, (int, float)) else None,
    }


def render(five, seven):
    parts = []
    if five:
        parts.append("5h:%.0f%%" % five["used_percentage"])
    if seven:
        parts.append("7d:%.0f%%" % seven["used_percentage"])
    return "  ".join(parts)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        print("")
        return

    if os.environ.get("AIUSAGE_DEBUG"):
        try:
            write_atomic(RAW, data)
        except Exception:
            pass

    limits = data.get("rate_limits")
    if not isinstance(limits, dict):
        limits = {}

    five = window(limits, "five_hour")
    seven = window(limits, "seven_day")

    # Cache unconditionally, including the empty case: it lets the app tell
    # "the hook ran and Claude reported no windows" apart from "never ran".
    try:
        write_atomic(CACHE, {
            "fetched_at": time.time(),
            "five_hour": five,
            "seven_day": seven,
            "has_limits": bool(five or seven),
        })
    except Exception:
        pass

    print(render(five, seven))


main()
