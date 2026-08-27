#!/usr/bin/env bash
set -euo pipefail

# Stable baseline detector for sidebar text flicker. It observes the real
# attached-client PTY and intentionally does not send selection input.
SCENARIO_NAME=sidebar-pty-output-burst
export SCENARIO_NAME
source "$(dirname -- "$BASH_SOURCE")/test-interactive-common.sh"

OBSERVATION_FILE="$RUN_DIR/pty-output-observations.tsv"
MIN_BURST_BYTES="${TMUX_FLICKER_MIN_BURST_BYTES:-500}"
BURST_INTERVAL_MS="${TMUX_FLICKER_BURST_INTERVAL_MS:-250}"
OBSERVATION_MS="${TMUX_FLICKER_OBSERVATION_MS:-3000}"

setup_interactive_test
sleep 0.2

: > "$OBSERVATION_FILE"
start_ms="$(date +%s%3N)"
start_bytes="$(wc -c < "$OUTPUT_LOG" | tr -d ' ')"
printf '%s\t%s\n' "$start_ms" "$start_bytes" >> "$OBSERVATION_FILE"
while [ $(( $(date +%s%3N) - start_ms )) -lt "$OBSERVATION_MS" ]; do
  printf '%s\t%s\n' "$(date +%s%3N)" "$(wc -c < "$OUTPUT_LOG" | tr -d ' ')" >> "$OBSERVATION_FILE"
  sleep 0.01
done

IFS='|' read -r burst_count minimum_interval maximum_burst_bytes <<< "$(awk -F '\t' \
  -v min_bytes="$MIN_BURST_BYTES" '
  BEGIN { minimum = -1 }
  NR == 1 { previous_bytes = $2; next }
  {
    delta_bytes = $2 - previous_bytes
    if (delta_bytes >= min_bytes) {
      count++
      if (previous_event > 0) {
        delta_ms = $1 - previous_event
        if (minimum < 0 || delta_ms < minimum) minimum = delta_ms
      }
      previous_event = $1
      if (delta_bytes > maximum) maximum = delta_bytes
    }
    previous_bytes = $2
  }
  END {
    if (count < 2) minimum = -1
    printf "%d|%.0f|%d\n", count + 0, minimum, maximum + 0
  }' "$OBSERVATION_FILE")"

echo "artifact=$RUN_DIR"
echo "samples=$(wc -l < "$OBSERVATION_FILE" | tr -d ' ') burst_count=$burst_count minimum_interval_ms=$minimum_interval maximum_burst_bytes=$maximum_burst_bytes"
if [ "$burst_count" -ge 2 ] && [ "$minimum_interval" -ge 0 ] && [ "$minimum_interval" -le "$BURST_INTERVAL_MS" ]; then
  echo "PRODUCT_FLICKER_OUTPUT_BURST: repeated sidebar text redraw detected" >&2
  exit 1
fi

echo "PASS: no repeated sidebar PTY output burst detected"
