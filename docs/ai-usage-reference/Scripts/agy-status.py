#!/usr/bin/env python3
"""Antigravity (agy) status hook for ai-usage-bar.

When agy runs, it exposes its language server address and CSRF token through
ANTIGRAVITY_LS_ADDRESS and ANTIGRAVITY_CSRF_TOKEN. This script:
1. Records the active agy endpoint to ~/.aiusage/antigravity.json so the menu
   bar app can query it directly during its 60-second refresh cycles.
2. Queries RetrieveUserQuotaSummary and writes the response to ~/.aiusage/gemini.json,
   mirroring Claude's cache pattern.

Hook contract:
Reads JSON from stdin (common hook metadata) and outputs `{}` on stdout.
This must never fail or block agent execution.
"""

import json
import os
import ssl
import sys
import tempfile
import time
import urllib.request

CACHE_DIR = os.path.expanduser("~/.aiusage")
ENDPOINT_FILE = os.path.join(CACHE_DIR, "antigravity.json")
QUOTA_FILE = os.path.join(CACHE_DIR, "gemini.json")


def write_atomic(path, obj):
    """Write JSON via temporary file and rename for atomic file updates."""
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


def record_endpoint(address, token, pid):
    try:
        _, port_str = address.split(":")
        port = int(port_str)
    except Exception:
        port = 0

    info = {
        "address": address,
        "port": port,
        "csrf_token": token,
        "pid": pid,
        "updated_at": time.time(),
    }
    write_atomic(ENDPOINT_FILE, info)


def fetch_quota(address, token):
    # Address is usually "localhost:<port>" or "127.0.0.1:<port>"
    urls = [
        f"http://{address}/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
        f"https://{address}/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
    ]

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    for url in urls:
        try:
            req = urllib.request.Request(
                url,
                data=b"{}",
                headers={
                    "Content-Type": "application/json",
                    "x-codeium-csrf-token": token,
                },
            )
            use_ctx = ctx if url.startswith("https") else None
            with urllib.request.urlopen(req, timeout=3, context=use_ctx) as resp:
                if resp.status == 200:
                    data = json.loads(resp.read().decode("utf-8"))
                    payload = {
                        "fetched_at": time.time(),
                        "raw_response": data,
                    }
                    write_atomic(QUOTA_FILE, payload)
                    return True
        except Exception:
            continue
    return False


def main():
    # Consume stdin if present (hook contract)
    try:
        if not sys.stdin.isatty():
            _ = sys.stdin.read()
    except Exception:
        pass

    address = os.environ.get("ANTIGRAVITY_LS_ADDRESS")
    token = os.environ.get("ANTIGRAVITY_CSRF_TOKEN")
    ppid = os.getppid()

    if address and token:
        try:
            record_endpoint(address, token, ppid)
        except Exception:
            pass
        try:
            fetch_quota(address, token)
        except Exception:
            pass

    # Always output valid JSON for hook contract
    print("{}")


if __name__ == "__main__":
    main()
