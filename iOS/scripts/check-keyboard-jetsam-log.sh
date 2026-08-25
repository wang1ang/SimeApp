#!/usr/bin/env bash
set -euo pipefail

LOG="${1:-/tmp/sime-device.log}"
if [[ ! -s "$LOG" ]]; then
  printf 'Missing or empty device log: %s\n' "$LOG" >&2
  exit 2
fi

PATTERN='SimeKeyboard.*(exceeded mem limit|per-process-limit|jetsam)|(?:exceeded mem limit|per-process-limit|jetsam).*SimeKeyboard'
if rg -n -i -C 6 "$PATTERN" "$LOG"; then
  printf '\nFAIL: SimeKeyboard hit the Jetsam/per-process memory limit.\n' >&2
  exit 1
fi

printf 'PASS: no SimeKeyboard Jetsam event found in %s\n' "$LOG"
