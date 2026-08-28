#!/usr/bin/env bash
# The shared AI observer: exactly one --observe process per tmux server, a
# fresh state file the presenters consume, automatic respawn when it dies,
# and exit once no sidebar pane is left.
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="${TMUX_SESSION_LAUNCHER_UNDER_TEST:-$REPO_ROOT/scripts/tmux-session-launcher}"
FAKE_AI="$TEST_DIR/fake-ai.sh"
SOCKET="gradient-shared-observer-$$"
TMP_DIR="$(mktemp -d)"
CONTROL_FILE="$TMP_DIR/ai.control"
LOCK_ROOT="$TMP_DIR/locks"
mkdir -p "$LOCK_ROOT"
GRACE_SECONDS=3
IDLE_EXIT_SECONDS=3

cleanup() {
    kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    wait "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    for pid in $(observer_pids 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
    rm -rf "$TMP_DIR" 2>/dev/null || { sleep 0.5; rm -rf "$TMP_DIR" 2>/dev/null || true; }
}
trap cleanup EXIT INT TERM

tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
client_session() { tmuxc list-clients -F '#{session_name}' | head -n 1; }
sidebar_for() {
    tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' |
        awk -F'|' '$2 == "dotfiles-session-sidebar" { print $1; exit }'
}
strip_ansi() { sed -E $'s/\x1B\[[0-9;?]*[ -\\/]*[@-~]//g'; }
fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    tmuxc list-panes -a -F '#{session_name}|#{pane_id}|#{pane_title}|#{pane_current_command}' >&2 || true
    ls -la "$LOCK_ROOT" >&2 || true
    cat "$LOCK_ROOT"/*.state >&2 2>/dev/null || true
    exit 1
}
# Observer processes for THIS server: their environment carries our socket.
observer_pids() {
    local pid env_dump
    for pid in $(pgrep -f -- "tmux-session-(dock|launcher) --observe" 2>/dev/null || true); do
        # The process may exit between pgrep and the read (we kill one on purpose).
        [ -r "/proc/$pid/environ" ] || continue
        env_dump="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null || true)"
        case "$env_dump" in
            *"TMUX_SESSION_LAUNCHER_LOCK_ROOT=$LOCK_ROOT"*) printf '%s\n' "$pid" ;;
        esac
    done
    return 0
}
state_file() { ls "$LOCK_ROOT"/dotfiles-sidebar-ai-*.state 2>/dev/null | head -n 1; }
state_ts() { sed -n 's/^#ts \([0-9]*\).*/\1/p' "$(state_file)" 2>/dev/null | head -n 1; }
row_gradient_count() {
    local session="$1" pane="$2" frame plain line_index
    frame="$(tmuxc capture-pane -e -p -t "$pane" 2>/dev/null || true)"
    plain="$(strip_ansi <<< "$frame")"
    mapfile -t raw_lines <<< "$frame"
    mapfile -t plain_lines <<< "$plain"
    for line_index in "${!plain_lines[@]}"; do
        if [[ "${plain_lines[$line_index]}" == *"$session"* ]]; then
            { grep -o '38;5;' <<< "${raw_lines[$line_index]}" || true; } | wc -l | tr -d ' '
            return 0
        fi
    done
    printf '%s\n' '-1'
}
wait_for_gradient() {
    local session="$1" presenter="$2" expected="$3" seconds="$4" message="$5" deadline colors=-1
    deadline=$(( $(date +%s) + seconds ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        colors="$(row_gradient_count "$session" "$(sidebar_for "$presenter")")"
        case "$expected" in
            present) [ "$colors" -ge 1 ] && return 0 ;;
            absent) [ "$colors" -eq 0 ] && return 0 ;;
        esac
        sleep 0.2
    done
    fail_test "$message (gradient cells=$colors)"
}

cp "$(command -v bash)" "$TMP_DIR/codex"
printf 'active\n' > "$CONTROL_FILE"
# The lock root is passed through the server environment so the observer the
# presenters spawn via run-shell inherits it too.
tmuxc new-session -d -s ai1 -x 120 -y 30 "'$TMP_DIR/codex' '$FAKE_AI' '$CONTROL_FILE'" >/dev/null
tmuxc set-environment -g TMUX_SESSION_LAUNCHER_LOCK_ROOT "$LOCK_ROOT"
tmuxc set-environment -g TMUX_SESSION_SIDEBAR_BUSY_SECONDS "$GRACE_SECONDS"
tmuxc set-environment -g TMUX_SESSION_SIDEBAR_AI_OBSERVER_IDLE_EXIT_SECONDS "$IDLE_EXIT_SECONDS"
tmuxc new-session -d -s shell1 -x 120 -y 30 >/dev/null
for session in ai1 shell1; do
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 35 -t "=$session:" \
        "TMUX_SESSION_LAUNCHER_LOCK_ROOT='$LOCK_ROOT' TMUX_SESSION_SIDEBAR_BUSY_SECONDS=$GRACE_SECONDS TMUX_SESSION_SIDEBAR_AI_OBSERVER_IDLE_EXIT_SECONDS=$IDLE_EXIT_SECONDS TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar" >/dev/null
done

coproc ATTACHED {
    script -qefc "tmux -L '$SOCKET' attach-session -t shell1" \
        --log-in "$TMP_DIR/input.log" --log-out "$TMP_DIR/output.log" >/dev/null 2>&1
}
CLIENT_PID="$ATTACHED_PID"

deadline=$(( $(date +%s) + 12 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -n "$(sidebar_for ai1)" ] && [ -n "$(sidebar_for shell1)" ] && [ "$(client_session)" = shell1 ] && break
    sleep 0.1
done
[ "$(client_session)" = shell1 ] || fail_test 'client did not attach to shell1'

# One observer, one fresh state file.
deadline=$(( $(date +%s) + 10 ))
while [ "$(date +%s)" -lt "$deadline" ] && [ -z "$(state_file)" ]; do sleep 0.2; done
[ -n "$(state_file)" ] || fail_test 'no shared observer state file appeared'
sleep 2
count="$(observer_pids | wc -l | tr -d ' ')"
[ "$count" -eq 1 ] || fail_test "expected exactly one observer for this server, found $count"
age=$(( $(date +%s) - $(state_ts) ))
[ "$age" -le 3 ] || fail_test "state file is stale ($age s old)"
grep -Pq $'^ai1\trunning\t%' "$(state_file)" || fail_test "state file does not report ai1 running: $(grep '^ai1' "$(state_file)" || true)"
printf 'PASS: one shared observer publishes a fresh state file\n'

# Presenters consume it: the shell presenter tracks the AI session.
wait_for_gradient ai1 shell1 present 10 'shell1 presenter shows no gradient for working ai1'
printf 'waiting\n' > "$CONTROL_FILE"
wait_for_gradient ai1 shell1 absent $((GRACE_SECONDS + 8)) 'shell1 presenter kept the gradient after ai1 went idle'
printf 'active\n' > "$CONTROL_FILE"
wait_for_gradient ai1 shell1 present 10 'shell1 presenter did not relight ai1'
printf 'PASS: presenters follow the shared state through idle and resume\n'

# Kill the observer: presenters respawn it and the gradient keeps working.
old_pid="$(observer_pids | head -n 1)"
kill "$old_pid"
deadline=$(( $(date +%s) + 15 ))
new_pid=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    new_pid="$(observer_pids | head -n 1)"
    [ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ] && break
    sleep 0.2
done
[ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ] || fail_test 'observer was not respawned after being killed'
printf 'waiting\n' > "$CONTROL_FILE"
wait_for_gradient ai1 shell1 absent $((GRACE_SECONDS + 10)) 'after respawn the shell1 presenter kept the gradient once ai1 went idle'
printf 'PASS: a killed observer is respawned and observation continues\n'

# No sidebars left: the observer exits on its own.
tmuxc kill-pane -t "$(sidebar_for ai1)"
tmuxc kill-pane -t "$(sidebar_for shell1)"
deadline=$(( $(date +%s) + IDLE_EXIT_SECONDS + 8 ))
while [ "$(date +%s)" -lt "$deadline" ] && [ -n "$(observer_pids)" ]; do sleep 0.3; done
[ -z "$(observer_pids)" ] || fail_test 'observer kept running after the last sidebar pane was gone'
printf 'PASS: observer exits when no sidebar pane remains\n'
printf 'SUMMARY: pass=4 xfail=0 fail=0\n'
