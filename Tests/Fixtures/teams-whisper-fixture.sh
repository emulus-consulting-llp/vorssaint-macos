#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
# A deterministic subprocess fixture, never a substitute for an ASR live test.
while [ "$#" -gt 0 ]; do
    case "$1" in
        -of) shift; fixture_output=$1 ;;
        -m) shift; fixture_model=$1 ;;
        -ng) fixture_cpu=1 ;;
        -np) fixture_quiet=1 ;;
    esac
    shift
done
case "$(cat "$fixture_model")" in
    fail) exit 1 ;;
    slow) exec /bin/sleep 30 ;;
    gpu)
        if [ "${fixture_cpu:-0}" != 1 ]; then
            # Match 1.9.5: quiet mode hides the allocation diagnostic.
            if [ "${fixture_quiet:-0}" = 1 ]; then
                printf '%s' 'GGML_ASSERT(buffer) failed' >&2
            else
                printf '%s' 'ggml_metal_buffer_init: error: failed to allocate buffer' >&2
            fi
            exit 1
        fi
        ;;
esac
printf '%s' '{"transcription":[{"offsets":{"from":100,"to":350},"text":"Please send the review tomorrow."}]}' > "$fixture_output.json"
