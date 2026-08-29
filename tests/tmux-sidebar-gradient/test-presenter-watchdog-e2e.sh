#!/usr/bin/env bash
# The observer's presenter watchdog: a presenter whose heartbeat stops while
# its process is alive is recorded in <state>.watchdog.log; in recover mode it
# also receives Escape, unless a prompt is open in that presenter.  The stall
# is produced with the presenter's test hook (TMUX_SESSION_SIDEBAR_TEST_STALL_FILE):
# a tty read with no timeout, the shape of the stall seen on a live server.
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="${TMUX_SESSION_LAUNCHER_UNDER_TEST:-$REPO_ROOT/scripts/tmux-session-launcher}"
FAKE_AI="$TEST_DIR/fake-ai.sh"
SOCKET="gradient-watchdog-$$"
TMP_DIR="$(mktemp -d)"
CONTROL_FILE="$TMP_DIR/ai.control"
LOCK_ROOT="$TMP_DIR/locks"
mkdir -p "$LOCK_ROOT"
STALE_SECONDS=3

cleanup() {
    kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    wait "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    for pid in $(observer_pids 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
    rm -rf "$TMP_DIR" 2>/dev/null || { sleep 0.5; rm -rf "$TMP_DIR" 2>/dev/null || true; }
}
trap cleanup EXIT INT TERM

tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
client_session() { tmuxc list-clients -F '#{session_name}' | sed -n 1p; }
sidebar_for() {
    tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' |
        awk -F'|' '!done && $2 == "dotfiles-session-sidebar" { print $1; done = 1 }'
}
stall_file_for() { printf '%s/stall-%s\n' "$TMP_DIR" "$1"; }
observer_pids() {
    local pid env_dump
    for pid in $(pgrep -f -- "tmux-session-(dock|launcher) --observe" 2>/dev/null || true); do
        [ -r "/proc/$pid/environ" ] || continue
        env_dump="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null || true)"
        case "$env_dump" in *"TMUX_SESSION_LAUNCHER_LOCK_ROOT=$LOCK_ROOT"*) printf '%s\n' "$pid" ;; esac
    done
    return 0
}
state_file() { ls "$LOCK_ROOT"/dotfiles-sidebar-ai-*.state 2>/dev/null | sed -n 1p; }
watchdog_log() { cat "$(state_file).watchdog.log" 2>/dev/null || true; }
heartbeat_epoch() { awk '{ print $1 }' "$(state_file).presenter-${1//%/pane}.hb" 2>/dev/null || true; }
fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    tmuxc list-panes -a -F '#{session_name}|#{pane_id}|#{pane_title}|#{pane_pid}' >&2 || true
    ls -la "$LOCK_ROOT" >&2 || true
    echo "== watchdog log" >&2; watchdog_log >&2
    exit 1
}

cp "$(command -v bash)" "$TMP_DIR/codex"
printf 'active\n' > "$CONTROL_FILE"
tmuxc new-session -d -s ai1 -x 120 -y 30 "'$TMP_DIR/codex' '$FAKE_AI' '$CONTROL_FILE'" >/dev/null
tmuxc new-session -d -s shell1 -x 120 -y 30 >/dev/null
for session in ai1 shell1; do
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 35 -t "=$session:" \
        "TMUX_SESSION_LAUNCHER_LOCK_ROOT='$LOCK_ROOT' TMUX_SESSION_SIDEBAR_WATCHDOG=recover TMUX_SESSION_SIDEBAR_WATCHDOG_STALE_SECONDS=$STALE_SECONDS TMUX_SESSION_SIDEBAR_TEST_STALL_FILE='$(stall_file_for "$session")' TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar" >/dev/null
done

coproc ATTACHED {
    script -qefc "tmux -L '$SOCKET' attach-session -t shell1" \
        --log-in "$TMP_DIR/input.log" --log-out "$TMP_DIR/output.log" >/dev/null 2>&1
}
CLIENT_PID="$ATTACHED_PID"

deadline=$(( $(date +%s) + 12 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -n "$(sidebar_for ai1)" ] && [ -n "$(sidebar_for shell1)" ] && [ "$(client_session)" = shell1 ] && [ -n "$(state_file)" ] && break
    sleep 0.1
done
[ -n "$(state_file)" ] || fail_test 'no shared observer state file appeared'
ai_pane="$(sidebar_for ai1)"; shell_pane="$(sidebar_for shell1)"
deadline=$(( $(date +%s) + 8 ))
while [ "$(date +%s)" -lt "$deadline" ] && { [ -z "$(heartbeat_epoch "$ai_pane")" ] || [ -z "$(heartbeat_epoch "$shell_pane")" ]; }; do sleep 0.2; done
[ -n "$(heartbeat_epoch "$ai_pane")" ] || fail_test 'ai1 presenter never wrote a heartbeat'

# Healthy presenters produce no watchdog entries.
sleep $((STALE_SECONDS + 2))
[ -z "$(watchdog_log)" ] || fail_test "watchdog flagged healthy presenters: $(watchdog_log)"
printf 'PASS: healthy presenters are not flagged\n'

# A presenter blocked in a tty read without a timeout stops heartbeating; the
# watchdog records it and, in recover mode, its Escape unblocks the read.
before="$(heartbeat_epoch "$ai_pane")"
: > "$(stall_file_for ai1)"
deadline=$(( $(date +%s) + STALE_SECONDS + 8 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    grep -q "pane=$ai_pane .*action=escape-sent" <<< "$(watchdog_log)" && break
    sleep 0.3
done
grep -q "pane=$ai_pane .*action=escape-sent" <<< "$(watchdog_log)" || fail_test 'stalled ai1 presenter was not recovered by the watchdog'
stalled_epoch="$(grep "pane=$ai_pane " <<< "$(watchdog_log)" | sed -n 1p | grep -oE 'age=[0-9]+' || true)"
deadline=$(( $(date +%s) + 8 ))
while [ "$(date +%s)" -lt "$deadline" ] && [ "$(heartbeat_epoch "$ai_pane")" = "$before" ]; do sleep 0.2; done
[ "$(heartbeat_epoch "$ai_pane")" != "$before" ] || fail_test 'ai1 presenter heartbeat did not resume after the watchdog Escape'
printf 'PASS: a stalled presenter is logged (%s) and unblocked by the watchdog Escape\n' "${stalled_epoch:-age=?}"

# With a prompt open the watchdog only logs; it must not type into the prompt.
shell_win="$(tmuxc display-message -p -t "$shell_pane" '#{window_id}')"
tmuxc set-environment -gh "DOTFILES_SIDEBAR_PROMPT_READY_${shell_win//[^A-Za-z0-9]/_}" 1
: > "$(stall_file_for shell1)"
deadline=$(( $(date +%s) + STALE_SECONDS + 8 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    grep -q "pane=$shell_pane .*prompt_ready=1 action=logged" <<< "$(watchdog_log)" && break
    sleep 0.3
done
grep -q "pane=$shell_pane .*prompt_ready=1 action=logged" <<< "$(watchdog_log)" || fail_test 'prompting presenter was not logged as prompt_ready'
if grep -q "pane=$shell_pane .*action=escape-sent" <<< "$(watchdog_log)"; then
    fail_test 'watchdog sent Escape into an open prompt'
fi
tmuxc set-environment -gh "DOTFILES_SIDEBAR_PROMPT_READY_${shell_win//[^A-Za-z0-9]/_}" 0
# Release the deliberately stalled presenter ourselves.
tmuxc send-keys -t "$shell_pane" Escape
printf 'PASS: a prompting presenter is logged but not touched\n'
printf 'SUMMARY: pass=3 xfail=0 fail=0\n'
