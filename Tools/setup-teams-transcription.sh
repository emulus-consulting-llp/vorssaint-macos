#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
set -euo pipefail
umask 077

# Install only when the engine is not already available.
TEAMS_WHISPER_CLI=$(command -v whisper-cli || true)
if [[ -z "$TEAMS_WHISPER_CLI" ]]; then
    TEAMS_BREW=$(command -v brew || true)
    if [[ -z "$TEAMS_BREW" ]]; then
        print -u2 "Homebrew is required to install whisper.cpp. Install Homebrew, then rerun this script."
        exit 1
    fi
    env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 "$TEAMS_BREW" install whisper.cpp
fi
# Model URL/checksum published by the upstream model repository:
# https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-small.bin
TEAMS_MODEL_DIR="${1:-$HOME/Library/Application Support/com.vorssaint.utils/MeetingModels}"
TEAMS_MODEL_SHA256="1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
TEAMS_MODEL_FILE="$TEAMS_MODEL_DIR/ggml-small.bin"
mkdir -p "$TEAMS_MODEL_DIR"
chmod 700 "$TEAMS_MODEL_DIR"

verify_model() {
    local digest
    digest=$(shasum -a 256 "$1" | cut -d ' ' -f 1)
    [[ "$digest" == "$TEAMS_MODEL_SHA256" ]]
}

if [[ -e "$TEAMS_MODEL_FILE" ]]; then
    if ! verify_model "$TEAMS_MODEL_FILE"; then
        print -u2 "Existing speech model failed checksum; it was not replaced."
        exit 1
    fi
    print "Verified local speech model: $TEAMS_MODEL_FILE"
    exit 0
fi

TEAMS_MODEL_TEMP=$(mktemp "$TEAMS_MODEL_DIR/.ggml-small.XXXXXX")
trap 'rm -f "$TEAMS_MODEL_TEMP"' EXIT
curl --disable --fail --location --retry 2 --proto '=https' \
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin' \
    --output "$TEAMS_MODEL_TEMP"
if ! verify_model "$TEAMS_MODEL_TEMP"; then
    print -u2 "Downloaded speech model failed checksum; no model was installed."
    exit 1
fi
# Exclusive link avoids replacing another installation or an existing symlink.
ln "$TEAMS_MODEL_TEMP" "$TEAMS_MODEL_FILE"
print "Verified local speech model: $TEAMS_MODEL_FILE"
