#!/usr/bin/env bash
# Verify the public warm-session contract: an attached client can enter a
# pre-provisioned Presenter, retain a valid screen, and then remain quiet.
# A full-render trace is deliberately not used as a flicker oracle.

set -euo pipefail

SCENARIO_NAME="first-enter-flicker-detect"
TMUX_INTERACTIVE_CREATE_PEER=false

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TEST_DIR/../lib/interactive_common.sh"

MIN_BURST_BYTES="${TMUX_FLICKER_MIN_BURST_BYTES:-500}"
BURST_INTERVAL_MS="${TMUX_FLICKER_BURST_INTERVAL_MS:-250}"
OBSERVATION_MS="${TMUX_FLICKER_OBSERVATION_MS:-1000}"

output_bytes() {
    wc -c < "$OUTPUT_LOG" | tr -d ' '
}

assert_quiet_settled_presenter() {
    local target="$1" observation="$RUN_DIR/settled-$target-pty.tsv"
    local started_ms burst_count minimum_interval maximum_burst
    : > "$observation"
    started_ms="$(date +%s%3N)"
    printf '%s\t%s\n' "$started_ms" "$(output_bytes)" >> "$observation"
    while [ $(( $(date +%s%3N) - started_ms )) -lt "$OBSERVATION_MS" ]; do
        printf '%s\t%s\n' "$(date +%s%3N)" "$(output_bytes)" >> "$observation"
        sleep 0.01
    done
    IFS='|' read -r burst_count minimum_interval maximum_burst <<< "$(awk -F '\t' -v min_bytes="$MIN_BURST_BYTES" '
        BEGIN { minimum = -1 }
        NR == 1 { previous = $2; next }
        {
          delta = $2 - previous
          if (delta >= min_bytes) {
            count++
            if (last > 0) {
              interval = $1 - last
              if (minimum < 0 || interval < minimum) minimum = interval
            }
            last = $1
            if (delta > maximum) maximum = delta
          }
          previous = $2
        }
        END { if (count < 2) minimum = -1; printf "%d|%.0f|%d\n", count + 0, minimum, maximum + 0 }
    ' "$observation")"
    echo "target=$target settled_bursts=$burst_count interval_ms=$minimum_interval max_bytes=$maximum_burst artifact=$observation"
    if [ "$burst_count" -ge 2 ] && [ "$minimum_interval" -ge 0 ] && [ "$minimum_interval" -le "$BURST_INTERVAL_MS" ]; then
        echo "PRODUCT_FLICKER_OUTPUT_BURST: target=$target repeated redraw after settled handover" >&2
        return 1
    fi
}

warm_session() {
    local session_name="$1" session_window
    tmuxc new-session -d -s "$session_name" -x 120 -y 30 -c "$REPO_ROOT" 'sleep 300'
    session_window="$(tmuxc display-message -p -t "=$session_name:" '#{window_id}')"
    tmuxc set-option -wq -t "$session_window" @dotfiles_sidebar_managed 1
    tmuxc run-shell "$LAUNCHER --ensure-sidebar-window '$session_window' 35"
    wait_until "$session_name warm Presenter ready" "tmuxc show-options -wqv -t '$session_window' @dotfiles_sidebar_ready | grep -Fq 1"
    wait_until "$session_name visible on source Presenter" "[ -n \"\$(sidebar_row_for '$session_name')\" ]"
}

echo "=== [1/3] Setting up attached source Presenter ==="
setup_interactive_test
wait_until "anchor sidebar ready" sidebar_ready

echo "=== [2/3] Creating two background-warmed Presenter Windows ==="
warm_session peer-warmed
warm_session peer-warmed-2

echo "=== [3/3] Entering each warm session and observing settled output ==="
for target in peer-warmed peer-warmed-2 interactive-anchor; do
    select_session_by_name "$target"
    target_window="$(tmuxc display-message -p -t "=$target:" '#{window_id}')"
    wait_for_settled_presenter_screen "$target_window" "$target"
    printf '%s\n' "$PRESENTER_SCREEN_RESULT" > "$RUN_DIR/settled-$target.screen"
    assert_quiet_settled_presenter "$target"
done

echo "PASS: warm Presenter switches settled with no repeated PTY redraw burst"
