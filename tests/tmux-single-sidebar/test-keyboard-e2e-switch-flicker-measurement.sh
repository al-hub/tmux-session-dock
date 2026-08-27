#!/usr/bin/env bash
set -euo pipefail

# Measurement-only regression scenario for the perceived sidebar flicker:
# create several sessions, move the TUI selection with physical arrow bytes,
# press Enter, and sample the same sidebar pane while the session transition
# is in flight. This test intentionally does not change production behavior.

SCENARIO_NAME=switch-flicker-measurement
export SCENARIO_NAME
export TMUX_SESSION_LAUNCHER_TRACE=1
export TMUX_SESSION_LAUNCHER_DEBUG=1
source "$(dirname -- "$BASH_SOURCE")/test-interactive-common.sh"

MEASURE_FILE="$RUN_DIR/transition-samples.tsv"
BURST_FILE="$RUN_DIR/render-bursts.tsv"
PTY_BURST_FILE="$RUN_DIR/pty-output-bursts.tsv"
EXPECTED_SESSIONS=(flicker-a flicker-b flicker-c flicker-d)
PHYSICAL_INPUT_FALLBACKS=0
FLICKER_BURST_INTERVAL_MS="${TMUX_FLICKER_BURST_INTERVAL_MS:-250}"

# The sidebar marks the current session with '*' and the pending selection
# with '>'. The latter is the row that arrow input must advance.
sidebar_selected_name() {
  tmuxc capture-pane -p -t "$(sidebar_pane_id)" 2>/dev/null |
    sed $'s/\033\\[[0-9;]*m//g' |
    awk '
      $1 == ">*" { selected=$2; current=$2; next }
      $1 == "*" { current=$2; next }
      $1 == ">" { if ($2 == "*") selected=$3; else selected=$2; next }
      END { if (selected != "") print selected; else print current }
    '
}

capture_sample() {
  local iteration="$1" phase="$2" now="$3" capture session_count selected_count pane_id
  pane_id="$(sidebar_pane_id 2>/dev/null || true)"
  [ -n "$pane_id" ] || pane_id="$SIDEBAR_TARGET"
  capture="$(tmuxc capture-pane -p -t "$pane_id" 2>/dev/null || true)"
  session_count=0
  for session in "${EXPECTED_SESSIONS[@]}"; do
    printf '%s\n' "$capture" | grep -Fq "$session" && session_count=$((session_count + 1))
  done
  selected_count="$(printf '%s\n' "$capture" | grep -Ec '^> *\*? ' || true)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$iteration" "$phase" "$now" "$(sidebar_pane_id)" \
    "$(printf '%s\n' "$capture" | grep -Fc sessions || true)" \
    "$session_count" "$selected_count" >> "$MEASURE_FILE"
}

trace_selected_name() {
  awk -v pane="pane=$SIDEBAR_TARGET" '
    index($0, pane) && /selection\.update\.end/ {
      for (i = 1; i <= NF; i++)
        if ($i ~ /^session=/) { value=$i; sub(/^session=/, "", value) }
    }
    END { print value }
  ' "$TRACE_FILE" 2>/dev/null || true
}

trace_render_burst() {
  local start_line="$1" pane_id="$2"
  awk -v start="$((start_line + 1))" -v pane="pane=$pane_id" -v threshold="$FLICKER_BURST_INTERVAL_MS" '
    NR < start || index($0, pane) == 0 || $0 !~ /render\.full\.begin/ { next }
    {
      ts = $1 + 0
      if (previous > 0) {
        delta = (ts - previous) * 1000
        if (delta < minimum) minimum = delta
      }
      previous = ts
      count++
    }
    END {
      if (count < 2) minimum = -1
      printf "%d|%.0f\n", count + 0, minimum
    }
  ' "$TRACE_FILE" 2>/dev/null || printf '0|-1\n'
}

trace_pty_output_burst() {
  local observation_file="$1"
  awk -F '\t' -v threshold="$FLICKER_BURST_INTERVAL_MS" '
    BEGIN { minimum = -1 }
    NR == 1 { previous_bytes=$2; next }
    {
      if ($2 > previous_bytes) {
        burst_bytes = $2 - previous_bytes
        count++
        if (previous_event > 0) {
          delta = $1 - previous_event
          if (minimum < 0 || delta < minimum) minimum = delta
        }
        previous_event = $1
        if (burst_bytes > maximum_bytes) maximum_bytes = burst_bytes
      }
      previous_bytes = $2
    }
    END {
      if (count < 2) minimum = -1
      printf "%d|%.0f|%d\n", count + 0, minimum, maximum_bytes + 0
    }
  ' "$observation_file" 2>/dev/null || printf '0|-1|0\n'
}

transition_idle() {
  local state
  state="$(tmuxc show-options -gqv @dotfiles_sidebar_transition 2>/dev/null || true)"
  case "$state" in
    *result=running*|*result=committed*) return 1 ;;
    *) return 0 ;;
  esac
}

sample_until_stable() {
  local iteration="$1" target="$2" sampler_pid start end trace_start_line burst_count burst_min_ms
  local pty_burst_count pty_burst_min_ms pty_burst_max_bytes output_observation_file
  output_observation_file="$RUN_DIR/pty-output-$iteration.tsv"
  : > "$output_observation_file"
  printf '%s\t%s\n' "$(date +%s%3N)" "$(wc -c < "$OUTPUT_LOG" 2>/dev/null || printf 0)" >> "$output_observation_file"
  start="$(date +%s%N)"
  trace_start_line="$(wc -l < "$TRACE_FILE" 2>/dev/null || printf 0)"
  (
    while :; do
      capture_sample "$iteration" transition "$(date +%s%3N)"
      printf '%s\t%s\n' "$(date +%s%3N)" "$(wc -c < "$OUTPUT_LOG" 2>/dev/null || printf 0)" >> "$output_observation_file"
      sleep 0.01
    done
  ) &
  sampler_pid="$!"

  send_keys $'\r'
  if ! wait_until "session $target" "wait_session '$target'"; then
    kill "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
    printf 'PRODUCT_FAIL_SWITCH: target=%s client_session=%s\n' \
      "$target" "$(client_session 2>/dev/null || true)" >&2
    return 3
  fi
  if ! wait_until "sidebar ready after session $target" sidebar_ready; then
    kill "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
    printf 'PRODUCT_FAIL_RUNTIME_RENDER: target=%s reason=sidebar-not-ready\n' "$target" >&2
    return 3
  fi
  end="$(date +%s%N)"
  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
  capture_sample "$iteration" stable "$end"
  IFS='|' read -r burst_count burst_min_ms <<< "$(trace_render_burst "$trace_start_line" "$SIDEBAR_TARGET")"
  IFS='|' read -r pty_burst_count pty_burst_min_ms pty_burst_max_bytes <<< "$(trace_pty_output_burst "$output_observation_file")"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$iteration" "$target" "$SIDEBAR_TARGET" "$burst_count" "$burst_min_ms" >> "$BURST_FILE"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$iteration" "$target" "$SIDEBAR_TARGET" "$pty_burst_count" "$pty_burst_min_ms" "$pty_burst_max_bytes" >> "$PTY_BURST_FILE"
  printf 'iteration=%s target=%s transition_ns=%s\n' \
    "$iteration" "$target" "$((end - start))"
}

move_selection_to_target() {
  local target="$1" current index target_index key trace_before
  local -a order=(flicker-a flicker-b flicker-c flicker-d interactive-anchor interactive-peer)
  SIDEBAR_TARGET="$(sidebar_pane_id 2>/dev/null || true)"
  [ -n "$SIDEBAR_TARGET" ] || return 1
  for _ in $(seq 1 8); do
    current="$(trace_selected_name)"
    [ -n "$current" ] || current="$(sidebar_selected_name)"
    [ "$current" = "$target" ] && return 0
    index=0
    target_index=0
    for i in "${!order[@]}"; do
      [ "${order[$i]}" = "$current" ] && index="$i"
      [ "${order[$i]}" = "$target" ] && target_index="$i"
    done
    key=$'\033[B'
    [ "$index" -gt "$target_index" ] && key=$'\033[A'
    # Reassert the attached client's pane boundary immediately before the
    # physical arrow byte. A sidebar can finish a prior redraw after focus
    # was observed, causing the first byte to reach the work pane.
    tmuxc select-pane -t "$SIDEBAR_TARGET" 2>/dev/null || true
    trace_before="$(wc -l < "$TRACE_FILE" 2>/dev/null || printf 0)"
    send_keys "$key"
    moved=false
    for attempt in $(seq 1 20); do
      if [ "$(sidebar_selected_name)" != "$current" ] && [ -n "$(sidebar_selected_name)" ]; then
        moved=true
        break
      fi
      sleep 0.05
    done
    if [ "$moved" != true ]; then
      test_log "harness.input.selection-timeout target=$target pane=$SIDEBAR_TARGET"
      printf 'HARNESS_ERROR_INPUT: PTY selection did not reach %s\n' "$target" >&2
      return 2
    fi
  done
  return 1
}

wait_selection_target() {
  local target="$1"
  wait_until "selection trace $target" "[ \"\$(trace_selected_name)\" = '$target' ]"
  sleep 0.1
}

wait_action_target() {
  local target="$1"
  wait_until "enter action target $target" \
    "grep -Eq 'action.begin .*type=enter session=$target' '$TRACE_FILE'"
}

setup_interactive_test
for session in "${EXPECTED_SESSIONS[@]}"; do
  create_session "$session"
done

focus_sidebar
wait_until "sidebar input ready before initial selection" \
  '[ "$(tmuxc show-options -wqv -t "$(client_window_id)" @dotfiles_sidebar_input_ready 2>/dev/null || true)" = 1 ]'
move_selection_to_target flicker-a
wait_selection_target flicker-a
send_keys $'\r'
if ! wait_action_target flicker-a; then
  printf 'PRODUCT_FAIL_SELECTION_SYNC: Enter target was not flicker-a\n' >&2
  exit 3
fi
wait_until "initial session flicker-a" "wait_session 'flicker-a'"
wait_until "initial sidebar flicker-a" sidebar_ready
wait_until "initial transition idle" transition_idle
: > "$MEASURE_FILE"
printf '%b\n' 'iteration\ttarget\tpane_id\tfull_render_count\tminimum_interval_ms' > "$BURST_FILE"
printf '%b\n' 'iteration\ttarget\tpane_id\toutput_burst_count\tminimum_interval_ms\tmaximum_burst_bytes' > "$PTY_BURST_FILE"

for iteration in $(seq 1 8); do
  focus_sidebar
  if [ $((iteration % 2)) -eq 1 ]; then
    target=flicker-b
  else
    target=flicker-a
  fi
  wait_until "sidebar input ready before flicker selection" \
    '[ "$(tmuxc show-options -wqv -t "$(client_window_id)" @dotfiles_sidebar_input_ready 2>/dev/null || true)" = 1 ]'
  move_selection_to_target "$target"
  wait_selection_target "$target"
  wait_until "transition idle before flicker Enter" transition_idle
  sleep 0.02
  sample_until_stable "$iteration" "$target"
done

sample_count="$(awk 'END {print NR + 0}' "$MEASURE_FILE")"
invalid_count="$(awk -F '\t' '$5 != 1 || $6 != 4 || $7 != 1 {n++} END {print n + 0}' "$MEASURE_FILE")"
identity_count="$(cut -f4 "$MEASURE_FILE" | sort -u | wc -l | tr -d ' ')"
transition_count="$(grep -c $'\ttransition\t' "$MEASURE_FILE" || true)"
burst_count="$(awk -F '\t' -v threshold="$FLICKER_BURST_INTERVAL_MS" \
  'NR > 1 && $4 >= 2 && $5 >= 0 && $5 <= threshold {n++} END {print n + 0}' "$BURST_FILE")"
pty_burst_count="$(awk -F '\t' -v threshold="$FLICKER_BURST_INTERVAL_MS" \
  'NR > 1 && $4 >= 2 && $5 >= 0 && $5 <= threshold {n++} END {print n + 0}' "$PTY_BURST_FILE")"

echo "measurement_file=$MEASURE_FILE"
echo "samples=$sample_count transition_samples=$transition_count invalid_frames=$invalid_count sidebar_identities=$identity_count"
echo "physical_input_fallbacks=$PHYSICAL_INPUT_FALLBACKS"
echo "render_bursts=$burst_count burst_interval_ms=$FLICKER_BURST_INTERVAL_MS"
echo "pty_output_bursts=$pty_burst_count burst_interval_ms=$FLICKER_BURST_INTERVAL_MS"

if [ "$invalid_count" -gt 0 ] || [ "$identity_count" -ne 1 ]; then
  echo "invalid_sample_rows(iteration phase timestamp sidebar_id title_count session_count selected_count):"
  awk -F '\t' '$5 != 1 || $6 != 4 || $7 != 1 {print}' "$MEASURE_FILE"
  echo "RED: sidebar transition produced inconsistent sampled frames or pane identity changes" >&2
  exit 1
fi

if [ "$burst_count" -gt 0 ]; then
  echo "render_burst_rows(iteration target pane_id full_render_count minimum_interval_ms):"
  awk -F '\t' -v threshold="$FLICKER_BURST_INTERVAL_MS" \
    'NR > 1 && $4 >= 2 && $5 >= 0 && $5 <= threshold {print}' "$BURST_FILE"
  echo "PRODUCT_FLICKER_REFRESH_BURST: repeated full sidebar refresh detected" >&2
  exit 1
fi

if [ "$pty_burst_count" -gt 0 ]; then
  echo "pty_output_burst_rows(iteration target pane_id output_burst_count minimum_interval_ms maximum_burst_bytes):"
  awk -F '\t' -v threshold="$FLICKER_BURST_INTERVAL_MS" \
    'NR > 1 && $4 >= 2 && $5 >= 0 && $5 <= threshold {print}' "$PTY_BURST_FILE"
  echo "PRODUCT_FLICKER_OUTPUT_BURST: repeated PTY sidebar output detected" >&2
  exit 1
fi

echo "PASS: no sampled sidebar frame inconsistency detected"
