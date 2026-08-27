#!/usr/bin/env bash
set -euo pipefail

export TERM="${TERM:-xterm-256color}"

# Scenario directory (pty-bridge.c lives there); this helper sits in tests/lib.
TEST_DIR="$(cd -- "$(dirname -- "$BASH_SOURCE")/../tmux-single-sidebar" && pwd -P)"
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd -P)"
RUN_DIR="${TMUX_INTERACTIVE_RUN_DIR:-/tmp/dotfiles-$SCENARIO_NAME-$$}"
HOME_DIR="$RUN_DIR/home"
HISTORY_DIR="$RUN_DIR/history"
SOCKET="${TMUX_INTERACTIVE_SOCKET:-dotfiles-$SCENARIO_NAME-$$}"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
INPUT_LOG="$RUN_DIR/input.log"
OUTPUT_LOG="$RUN_DIR/output.log"
TRACE_FILE="$RUN_DIR/trace.log"
DEBUG_FILE="$RUN_DIR/debug.log"
BRIDGE_LOG="$RUN_DIR/pty-bridge.log"
PTY_BRIDGE_BIN="$RUN_DIR/pty-bridge"
timestamp_mono_ms() { perl -MTime::HiRes=time -e 'printf "%.3f", time * 1000'; }
timestamp_wall() { date -u '+%Y-%m-%dT%H:%M:%S%z'; }
TEST_RUN_ID="${TEST_RUN_ID:-${SCENARIO_NAME}-$(timestamp_mono_ms | tr -d .)-$$}"
TEST_EVENT_SEQUENCE=0
LAST_INPUT_EVENT_SEQUENCE=0
TMUX_CMD=(tmux -L "$SOCKET" -f "$REPO_ROOT/dotfiles/tmux.conf")
CLIENT_PID=""
KEEP_RUN_DIR="${KEEP_RUN_DIR:-false}"

mkdir -p "$HOME_DIR/.local/bin" "$HISTORY_DIR"
ln -sfn "$LAUNCHER" "$HOME_DIR/.local/bin/tmux-session-launcher"
ln -sfn "$REPO_ROOT/scripts/tmux-sidebar-tmux-adapter" "$HOME_DIR/.local/bin/tmux-sidebar-tmux-adapter"
export HOME="$HOME_DIR" TMUX_SESSION_HISTORY_DIR="$HISTORY_DIR" TERM=xterm
tmuxc() { HOME="$HOME_DIR" tmux -L "$SOCKET" -f "$REPO_ROOT/dotfiles/tmux.conf" "$@"; }

test_log() {
  TEST_EVENT_SEQUENCE=$((TEST_EVENT_SEQUENCE + 1))
  printf 'ts_wall=%s ts_mono_ms=%s run_id=%s event_seq=%s %s\n' \
    "$(timestamp_wall)" "$(timestamp_mono_ms)" "$TEST_RUN_ID" \
    "$TEST_EVENT_SEQUENCE" "$*" >> "$RUN_DIR/test-trace.log"
}

test_context_snapshot() {
  local client_state pane_state operation_state_value
  client_state="$(tmuxc list-clients -F 'tty=#{client_tty}|session=#{session_name}|window=#{window_id}|pane=#{pane_id}|active=#{window_active}' 2>/dev/null | head -n 1 || true)"
  pane_state="$(tmuxc list-panes -a -F 'session=#{session_name}|window=#{window_id}|pane=#{pane_id}|title=#{pane_title}|pid=#{pane_pid}|active=#{pane_active}|dead=#{pane_dead}' 2>/dev/null | tr '\n' ';' || true)"
  operation_state_value="$(tmuxc show-option -gqv @dotfiles_sidebar_operation 2>/dev/null || true)"
  test_log "context client=[$client_state] operation=$operation_state_value panes=[$pane_state]"
}

cleanup() {
  local status=$?
  set +e
  [ "$status" -eq 0 ] || KEEP_RUN_DIR=true
  kill "$CLIENT_PID" 2>/dev/null
  tmuxc kill-server 2>/dev/null
  [ "$KEEP_RUN_DIR" = true ] || rm -rf "$RUN_DIR"
}
trap cleanup EXIT

send_keys() {
  test_log "input.begin bytes=$(printf '%b' "$1" | od -An -tx1 | tr -d ' \n') client=$(client_tty 2>/dev/null || true) session=$(client_session 2>/dev/null || true) window=$(client_window_id 2>/dev/null || true) sidebar=$(sidebar_pane_id 2>/dev/null || true)"
  LAST_INPUT_EVENT_SEQUENCE="$TEST_EVENT_SEQUENCE"
  eval 'exec 9>&"${ATTACHED[1]}"'
  if ! printf '%b' "$1" >&9; then
    test_log "input.write.failed"
    return 1
  fi
  test_log "input.end"
}

wait_until() {
  local description="$1" command="$2" i
  test_log "wait.begin description=$description command=$command"
  for i in $(seq 1 100); do
    if eval "$command"; then
      test_log "wait.end description=$description attempts=$i result=pass"
      return 0
    fi
    sleep 0.05
  done
  test_log "wait.end description=$description attempts=100 result=timeout"
  test_context_snapshot
  echo "FAIL: timeout waiting for $description" >&2
  KEEP_RUN_DIR=true
  printf '%s\n' "failure_description=$description" > "$RUN_DIR/failure.txt"
  tmuxc list-clients -F '#{client_control_mode}|#{client_tty}|#{session_name}|#{window_id}|#{pane_id}' > "$RUN_DIR/failure-clients.txt" 2>/dev/null || true
  tmuxc list-panes -a -F '#{session_name}|#{window_id}|#{pane_id}|#{pane_title}|#{pane_pid}|#{pane_active}' > "$RUN_DIR/failure-panes.txt" 2>/dev/null || true
  tmuxc show-options -g 2>/dev/null | grep -E 'dotfiles_sidebar|sidebar_force_refresh' > "$RUN_DIR/failure-options.txt" || true
  tmuxc capture-pane -p -t "$(sidebar_pane_id 2>/dev/null || true)" 2>/dev/null || true
  return 1
}

wait_for_selection_sync_ack() {
  local window_id="$1" session_name="$2" attempt ack
  test_log "wait.begin description=selection sync acknowledged window=$window_id session=$session_name"
  # A tmux option lookup dominates the 2ms sleep, so cap the probe at the
  # same practical timeout as wait_until instead of accumulating minutes.
  for attempt in $(seq 1 150); do
    ack="$(tmuxc show-options -wqv -t "$window_id" @dotfiles_sidebar_selection_sync_ack 2>/dev/null || true)"
    if [ "$ack" = "$session_name" ]; then
      test_log "wait.end description=selection sync acknowledged window=$window_id session=$session_name attempts=$attempt result=pass"
      return 0
    fi
    sleep 0.002
  done
  test_log "wait.end description=selection sync acknowledged window=$window_id session=$session_name attempts=150 result=timeout"
  test_context_snapshot
  echo "FAIL: timeout waiting for selection sync acknowledgement for $session_name" >&2
  return 1
}

client_session() {
  local sess=""
  if [ -n "${CLIENT_TTY:-}" ]; then
    sess="$(tmuxc display-message -c "$CLIENT_TTY" -p '#{session_name}' 2>/dev/null || true)"
  fi
  if [ -z "$sess" ]; then
    sess="$(tmuxc list-clients -F '#{client_control_mode}|#{client_tty}|#{session_name}' 2>/dev/null | awk -F'|' -v tty="${CLIENT_TTY:-}" '($1 != 1 && (tty == "" || $2 == tty)) {print $3; exit}')"
  fi
  if [ -z "$sess" ]; then
    sess="$(tmuxc list-clients -F '#{client_control_mode}|#{session_name}' 2>/dev/null | awk -F'|' '$1 != 1 {print $2; exit}')"
  fi
  printf '%s\n' "$sess"
}
client_tty() { local tty; tty="$(tmuxc list-clients -F '#{client_control_mode}|#{client_tty}' 2>/dev/null | awk -F'|' '$1 != 1 && $2 != "" {print $2; exit}')"; if [ -n "$tty" ]; then printf '%s\n' "$tty"; else tmuxc list-clients -F '#{client_tty}' 2>/dev/null | grep -v '^[[:space:]]*$' | head -n 1; fi; }
client_window_id() { local win; win="$(tmuxc list-clients -F '#{client_tty}|#{window_id}' 2>/dev/null | awk -F'|' -v tty="${CLIENT_TTY:-}" '$1 == tty && $2 != "" {print $2; exit}')"; if [ -n "$win" ]; then printf '%s\n' "$win"; else win="$(tmuxc list-clients -F '#{client_control_mode}|#{window_id}' 2>/dev/null | awk -F'|' '$1 != 1 && $2 != "" {print $2; exit}')"; if [ -n "$win" ]; then printf '%s\n' "$win"; else tmuxc list-windows -F '#{window_id}' 2>/dev/null | head -n 1; fi; fi; }
sidebar_pane_id() { tmuxc list-panes -t "$(client_window_id)" -F '#{pane_id}|#{pane_title}' | awk -F'|' '$2=="dotfiles-session-sidebar"{print $1; exit}'; }
count_sidebars() { tmuxc list-panes -a -F '#{pane_title}' | awk '$1=="dotfiles-session-sidebar"{n++} END{print n+0}'; }
count_sessions() { tmuxc list-sessions -F '#{session_name}' | wc -l | tr -d ' '; }
window_sidebar_pane_id() {
  local window_id="$1"
  tmuxc list-panes -t "$window_id" -F '#{pane_id}|#{pane_title}' |
    awk -F'|' '$2=="dotfiles-session-sidebar"{print $1; exit}'
}
window_sidebar_count() {
  local window_id="$1"
  tmuxc list-panes -t "$window_id" -F '#{pane_title}' |
    awk '$1=="dotfiles-session-sidebar"{n++} END{print n+0}'
}
managed_window_ids() {
  tmuxc list-windows -a -F '#{window_id}|#{session_id}|#{session_name}' |
    awk -F'|' '$3 != "" {print $1}' | sort -u
}
window_sidebar_geometry() {
  local window_id="$1" pane_id
  pane_id="$(window_sidebar_pane_id "$window_id")"
  [ -n "$pane_id" ] || return 1
  tmuxc display-message -p -t "$pane_id" \
    '#{pane_id}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}'
}
window_work_topology() {
  local window_id="$1"
  tmuxc list-panes -t "$window_id" \
    -F '#{pane_title}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{pane_current_path}' |
    awk '$1 != "dotfiles-session-sidebar"' | sort
}
window_sidebar_snapshot() {
  local window_id="$1" pane_id
  pane_id="$(window_sidebar_pane_id "$window_id" || true)"
  [ -n "$pane_id" ] || {
    printf 'window=%s sidebar=absent\n' "$window_id"
    return 0
  }
  printf 'window=%s sidebar=%s pid=%s geometry=%s\n' \
    "$window_id" "$pane_id" \
    "$(tmuxc display-message -p -t "$pane_id" '#{pane_pid}')" \
    "$(window_sidebar_geometry "$window_id")"
}
session_exists() { tmuxc has-session -t "=$1" 2>/dev/null; }
wait_session() { [ "$(client_session)" = "$1" ]; }
wait_sidebar_count() { [ "$(count_sidebars)" = "$1" ]; }
wait_session_exists() { session_exists "$1"; }
wait_session_absent() { ! session_exists "$1"; }
wait_capture() { tmuxc capture-pane -p -t "$(sidebar_pane_id)" | grep -Fq "$1"; }
wait_trace() { [ -f "$TRACE_FILE" ] && grep -Fq "$1" "$TRACE_FILE"; }
wait_trace_regex() { [ -f "$TRACE_FILE" ] && grep -Eq "$1" "$TRACE_FILE"; }
wait_sidebar_stable() {
  local first second
  first="$(tmuxc list-panes -a -F '#{pane_id}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}' | awk -F'|' -v id="$(sidebar_pane_id)" '$1 == id {print; exit}')" || return 1
  [ -n "$first" ] || return 1
  sleep 0.1
  second="$(tmuxc list-panes -a -F '#{pane_id}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}' | awk -F'|' -v id="$(sidebar_pane_id)" '$1 == id {print; exit}')" || return 1
  [ "$first" = "$second" ]
}
pane_count_at_least() { [ "$(tmuxc list-panes -t "=$1:" | wc -l)" -ge "$2" ]; }
sidebar_ready() {
  local window_id="$(client_window_id)" pane_id pane_dead pane_pid
  [ "$(tmuxc show-options -wqv -t "$window_id" @dotfiles_sidebar_ready 2>/dev/null || true)" = 1 ] ||
    [ "$(tmuxc show-options -wqv -t "$window_id" @dotfiles_sidebar_input_ready 2>/dev/null || true)" = 1 ] || {
      pane_id="$(sidebar_pane_id)"
      [ -n "$pane_id" ] || return 1
      pane_dead="$(tmuxc display-message -p -t "$pane_id" '#{pane_dead}' 2>/dev/null || true)"
      pane_pid="$(tmuxc display-message -p -t "$pane_id" '#{pane_pid}' 2>/dev/null || true)"
      [ "$pane_dead" = 0 ] && [ -n "$pane_pid" ] &&
        tmuxc capture-pane -p -t "$pane_id" 2>/dev/null | grep -Fq sessions
    }
}
sidebar_active() { [ "$(tmuxc display-message -p -t "$CLIENT_TTY" '#{pane_id}' 2>/dev/null || true)" = "$(sidebar_pane_id 2>/dev/null || true)" ]; }
sidebar_present() { [ -n "$(sidebar_pane_id)" ]; }

wait_prompt() {
  local expected="$1"
  wait_until "prompt $expected" "tmuxc capture-pane -p -t \"\$(sidebar_pane_id)\" | grep -Fq '$expected'"
}

sidebar_row_for() {
  local name="$1"
  tmuxc capture-pane -p -t "$(sidebar_pane_id)" | sed $'s/\033\\[[0-9;]*m//g' | nl -ba | awk -v n="$name" 'index($0,n)>0 {print $1; exit}'
}

sidebar_selected_name() {
  tmuxc capture-pane -p -t "$(sidebar_pane_id)" 2>/dev/null |
    sed $'s/\033\\[[0-9;]*m//g' |
    awk '
      $1 == ">*" { print $2; exit }
      $1 == ">" && $2 == "*" { print $3; exit }
      $1 == ">" { print $2; exit }
    '
}

sidebar_marker_invariant() {
  local expected="$1" state stars selected star_session selected_session actual
  state="$(tmuxc capture-pane -p -t "$(sidebar_pane_id)" 2>/dev/null |
    sed $'s/\033\\[[0-9;]*m//g' |
    awk '
      $1 == ">*" { stars++; selected++; star=$2; choice=$2; next }
      $1 == "*" { stars++; star=$2; next }
      $1 == ">" { selected++; if ($2 == "*") { star=$3; choice=$3 } else { choice=$2 } }
      END { printf "%d|%d|%s|%s\n", stars+0, selected+0, star, choice }
    ')"
  IFS='|' read -r stars selected star_session selected_session <<< "$state"
  actual="$(client_session 2>/dev/null || true)"
  [ "$stars" -eq 1 ] && [ "$selected" -eq 1 ] &&
    [ "$star_session" = "$actual" ] && [ "$selected_session" = "$expected" ]
}

focus_sidebar() {
  sidebar_active && return 0
  tmuxc select-pane -t "$(sidebar_pane_id 2>/dev/null || true)" 2>/dev/null || return 1
  wait_until "sidebar focus" "sidebar_active"
}

select_session_by_name() {
  local name="$1" i selected
  focus_sidebar
  wait_until "session $name selectable" "[ -n \"\$(sidebar_row_for '$name')\" ]"
  for i in $(seq 1 12); do
    selected="$(sidebar_selected_name 2>/dev/null || true)"
    [ "$selected" = "$name" ] && break
    focus_sidebar || return 1
    send_keys $'\033[B'
    wait_until "selection step $i toward $name" "selected=\$(sidebar_selected_name 2>/dev/null || true); [ -n \"\$selected\" ] && [ \"\$selected\" != '$selected' ]"
  done
  wait_until "selection $name stable" "first=\$(sidebar_selected_name 2>/dev/null || true); sleep 0.1; second=\$(sidebar_selected_name 2>/dev/null || true); [ \"\$first\" = '$name' ] && [ \"\$second\" = '$name' ]"
  [ "$(sidebar_selected_name 2>/dev/null || true)" = "$name" ] || {
    echo "FAIL: could not select session $name through attached PTY input" >&2
    return 1
  }
  send_keys $'\r'
  wait_until "session selection $name" "wait_session '$name'"
  wait_until "sidebar ready" sidebar_ready
}

# A Presenter is settled only when the user-visible terminal buffer is valid
# twice after the client has reached the target session. Transient coordination
# options are intentionally not part of this public display oracle.
presenter_screen_has_current_session() {
  local screen="$1" session_name="$2"
  printf '%s\n' "$screen" | sed $'s/\033\\[[0-9;]*m//g' | awk -v name="$session_name" '
    /^[[:space:]]*sessions[[:space:]]*$/ { title = 1 }
    $1 == ">*" && $2 == name { current = 1 }
    $1 == "*" && $2 == name { current = 1 }
    $1 == ">" && $2 == "*" && $3 == name { current = 1 }
    END { exit !(title && current) }
  '
}

wait_for_settled_presenter_screen() {
  local window_id="$1" session_name="$2" attempt pane_id first second
  for attempt in $(seq 1 100); do
    [ "$(client_session 2>/dev/null || true)" = "$session_name" ] || { sleep 0.05; continue; }
    pane_id="$(window_sidebar_pane_id "$window_id" 2>/dev/null || true)"
    [ -n "$pane_id" ] || { sleep 0.05; continue; }
    [ "$(tmuxc display-message -p -t "$pane_id" '#{pane_dead}' 2>/dev/null || true)" = 0 ] || { sleep 0.05; continue; }
    first="$(tmuxc capture-pane -p -t "$pane_id" 2>/dev/null || true)"
    presenter_screen_has_current_session "$first" "$session_name" || { sleep 0.05; continue; }
    sleep 0.1
    second="$(tmuxc capture-pane -p -t "$pane_id" 2>/dev/null || true)"
    if presenter_screen_has_current_session "$second" "$session_name"; then
      PRESENTER_SCREEN_RESULT="$second"
      return 0
    fi
    sleep 0.05
  done
  echo "FAIL: target Presenter did not settle for $session_name" >&2
  return 1
}

presenter_screen_session_rows() {
  local screen="$1" session_name="$2"
  printf '%s\n' "$screen" | sed $'s/\033\\[[0-9;]*m//g' | awk -v name="$session_name" '
    $1 == ">*" && $2 == name { count++ }
    $1 == "*" && $2 == name { count++ }
    $1 == ">" && $2 == "*" && $3 == name { count++ }
    $1 == ">" && $2 == name { count++ }
    $1 == name { count++ }
    END { print count + 0 }
  '
}

wait_for_sidebar_selection_change() {
  local previous="$1" attempt first second
  for attempt in $(seq 1 100); do
    first="$(sidebar_selected_name 2>/dev/null || true)"
    if [ -n "$first" ] && [ "$first" != "$previous" ]; then
      sleep 0.1
      second="$(sidebar_selected_name 2>/dev/null || true)"
      if [ "$first" = "$second" ]; then
        SIDEBAR_SELECTED_RESULT="$first"
        return 0
      fi
    fi
    sleep 0.05
  done
  echo "FAIL: sidebar selection did not advance from $previous" >&2
  return 1
}

# A selection is actionable only after two user-visible Presenter frames agree.
# This deliberately avoids internal readiness/options as an activation oracle.
wait_for_stable_sidebar_selection() {
  local expected="$1" attempt first second
  for attempt in $(seq 1 100); do
    first="$(sidebar_selected_name 2>/dev/null || true)"
    if [ "$first" = "$expected" ]; then
      sleep 0.1
      second="$(sidebar_selected_name 2>/dev/null || true)"
      if [ "$second" = "$expected" ]; then
        return 0
      fi
    fi
    sleep 0.05
  done
  echo "FAIL: sidebar selection did not settle on $expected" >&2
  return 1
}

pty_output_size() {
  [ -f "$OUTPUT_LOG" ] && wc -c < "$OUTPUT_LOG" | tr -d ' ' || printf '0\n'
}

# Verify one real navigation key caused a rendered selection change. A target
# fixture must make the expected marker adjacent to the current one.
navigate_sidebar_once() {
  local key="$1" expected="$2" before_size after_size
  before_size="$(pty_output_size)"
  send_keys "$key"
  wait_until "PTY output after navigation" "[ \"\$(pty_output_size)\" -gt '$before_size' ]"
  wait_for_stable_sidebar_selection "$expected"
  after_size="$(pty_output_size)"
  [ "$after_size" -gt "$before_size" ] || return 1
}

switch_to_next_sidebar_selection() {
  local previous target
  focus_sidebar || return 1
  # The pane can be focused before its first paint. Wait for the visible marker
  # rather than treating that render race as a product navigation failure.
  wait_until "sidebar selection visible" "[ -n \"\$(sidebar_selected_name 2>/dev/null || true)\" ]"
  previous="$(sidebar_selected_name 2>/dev/null || true)"
  send_keys $'\033[B'
  wait_for_sidebar_selection_change "$previous" || return 1
  target="$SIDEBAR_SELECTED_RESULT"
  send_keys $'\r'
  wait_until "session selection $target" "wait_session '$target'"
  wait_until "sidebar ready" sidebar_ready
  printf '%s\n' "$target"
}

create_session() {
  local name="$1"
  focus_sidebar
  send_keys c
  wait_prompt New:
  send_keys "$name"
  send_keys $'\r'
  wait_until "session $name" "wait_session_exists '$name'"
  wait_until "session $name visible" "[ -n \"\$(sidebar_row_for '$name')\" ]"
  wait_until "sidebar ready" sidebar_ready
}

setup_interactive_test() {
  if [ ! -x "$PTY_BRIDGE_BIN" ] || [ "$TEST_DIR/pty-bridge.c" -nt "$PTY_BRIDGE_BIN" ]; then
    cc -O2 -Wall -Wextra "$TEST_DIR/pty-bridge.c" -lutil -o "$PTY_BRIDGE_BIN"
  fi
  tmuxc new-session -d -s interactive-anchor -c "$REPO_ROOT" 'sleep 300'
  if [ "${TMUX_INTERACTIVE_CREATE_PEER:-true}" = true ]; then
    tmuxc new-session -d -s interactive-peer -c "$REPO_ROOT" 'sleep 300'
  fi
  if [ "${TMUX_SESSION_LAUNCHER_TRACE:-0}" = 1 ]; then
    tmuxc set-environment -g TMUX_SESSION_LAUNCHER_TRACE 1
    tmuxc set-environment -g TMUX_SESSION_LAUNCHER_TRACE_FILE "$TRACE_FILE"
  fi
  if [ "${TMUX_SESSION_LAUNCHER_DEBUG:-0}" = 1 ]; then
    tmuxc set-environment -g TMUX_SESSION_LAUNCHER_DEBUG 1
    tmuxc set-environment -g TMUX_SESSION_LAUNCHER_DEBUG_FILE "$DEBUG_FILE"
  fi
  if [ -n "${TMUX_SESSION_LAUNCHER_METRICS_FILE:-}" ]; then
    tmuxc set-environment -g TMUX_SESSION_LAUNCHER_METRICS_FILE "$TMUX_SESSION_LAUNCHER_METRICS_FILE"
    tmuxc set-environment -g TMUX_SESSION_LAUNCHER_METRICS_RUN_ID "${TMUX_SESSION_LAUNCHER_METRICS_RUN_ID:-$TEST_RUN_ID}"
  fi
  tmuxc split-window -d -t '=interactive-anchor:' -h -b -l 35 "$LAUNCHER --sidebar"
  local i
  for i in $(seq 1 100); do
    SIDEBAR_TARGET="$(sidebar_pane_id)"
    if [ -z "$SIDEBAR_TARGET" ]; then
      SIDEBAR_TARGET="$(window_sidebar_pane_id "$(tmuxc display-message -p -t '=interactive-anchor:' '#{window_id}')")"
    fi
    [ -n "$SIDEBAR_TARGET" ] && break
    sleep 0.05
  done
  SIDEBAR_PID="$(tmuxc display-message -p -t "$SIDEBAR_TARGET" '#{pane_pid}')"
  local attach_command
  coproc ATTACHED {
    "$PTY_BRIDGE_BIN" --log "$BRIDGE_LOG" --input "$INPUT_LOG" --output "$OUTPUT_LOG" -- \
      tmux -L "$SOCKET" -f "$REPO_ROOT/dotfiles/tmux.conf" attach-session -t interactive-anchor \
      >/dev/null 2>&1
  }
  CLIENT_PID="$ATTACHED_PID"
  sleep 0.3
  CLIENT_TTY="$(client_tty)"
  wait_until "sidebar pane provision" sidebar_present
  SIDEBAR_TARGET="$(sidebar_pane_id)"
  focus_sidebar
  wait_until "sidebar input readiness" sidebar_ready
  [ "$(count_sidebars)" = 1 ]
}
