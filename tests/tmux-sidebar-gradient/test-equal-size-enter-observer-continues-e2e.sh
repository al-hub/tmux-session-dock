#!/usr/bin/env bash
# Regression: after an Enter handover between windows of identical size, the
# target presenter must keep observing AI activity.  A window-local handover
# leaves @dotfiles_sidebar_transition_render_pending on the target window; that
# marker is only consumed by a geometry/topology render, which never happens
# when the windows already match the client.  The AI observer must not stay
# deferred behind it, otherwise the gradient freezes in its pre-switch state.
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="${TMUX_SESSION_LAUNCHER_UNDER_TEST:-$REPO_ROOT/scripts/tmux-session-launcher}"
FAKE_AI="$TEST_DIR/fake-ai.sh"
SOCKET="gradient-equal-size-enter-$$"
TMP_DIR="$(mktemp -d)"
CONTROL_DIR="$TMP_DIR/control"
mkdir -p "$CONTROL_DIR"
# Short idle grace keeps the idle transitions observable without long waits.
GRACE_SECONDS=3

cleanup() {
    kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    wait "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
client_session() { tmuxc list-clients -F '#{session_name}' | head -n 1; }
sidebar_for() {
    tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' |
        awk -F'|' '$2 == "dotfiles-session-sidebar" { print $1; exit }'
}
window_size() { tmuxc display-message -p -t "=$1:" '#{window_width}x#{window_height}'; }
set_state() { printf '%s\n' "$2" > "$CONTROL_DIR/$1"; }
strip_ansi() { sed -E $'s/\x1B\[[0-9;?]*[ -\\/]*[@-~]//g'; }
fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    tmuxc list-clients -F '#{client_tty}|#{session_name}|#{client_width}x#{client_height}' >&2 || true
    tmuxc list-panes -a -F '#{session_name}|#{pane_id}|#{pane_title}|#{pane_current_command}|#{pane_width}x#{pane_height}' >&2 || true
    for w in $(tmuxc list-windows -a -F '#{window_id}'); do
        printf '%s render_pending=%s\n' "$w" "$(tmuxc show-option -wqv -t "$w" @dotfiles_sidebar_transition_render_pending 2>/dev/null || true)" >&2
    done
    for debug_file in "$TMP_DIR"/*.debug; do
        [ -f "$debug_file" ] || continue
        printf '%s\n' "== $(basename "$debug_file") ==" >&2
        grep -E 'ai-observer|state session=live' "$debug_file" | tail -n 30 >&2
    done
    exit 1
}
# Number of gradient color cells on the row naming $1 inside sidebar pane $2.
row_gradient_count() {
    local session="$1" pane="$2" frame plain line_index colors
    frame="$(tmuxc capture-pane -e -p -t "$pane" 2>/dev/null || true)"
    plain="$(strip_ansi <<< "$frame")"
    mapfile -t raw_lines <<< "$frame"
    mapfile -t plain_lines <<< "$plain"
    for line_index in "${!plain_lines[@]}"; do
        if [[ "${plain_lines[$line_index]}" == *"$session"* ]]; then
            colors="$(grep -o '38;5;' <<< "${raw_lines[$line_index]}" | wc -l | tr -d ' ' || true)"
            printf '%s\n' "$colors"
            return 0
        fi
    done
    printf '%s\n' '-1'
}
# wait_for_gradient <row session> <presenter session> <present|absent> <seconds> <message>
wait_for_gradient() {
    local session="$1" presenter="$2" expected="$3" seconds="$4" message="$5" deadline colors
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
for session in live1 live2; do
    set_state "$session" active
    tmuxc new-session -d -s "$session" -x 120 -y 30 \
        "'$TMP_DIR/codex' '$FAKE_AI' '$CONTROL_DIR/$session'" >/dev/null
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 35 -t "=$session:" \
        "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$TMP_DIR/$session.debug' TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 TMUX_SESSION_SIDEBAR_BUSY_SECONDS=$GRACE_SECONDS '$LAUNCHER' --sidebar" >/dev/null
done

coproc ATTACHED {
    script -qefc "tmux -L '$SOCKET' attach-session -t live1" \
        --log-in "$TMP_DIR/input.log" --log-out "$TMP_DIR/output.log" >/dev/null 2>&1
}
CLIENT_PID="$ATTACHED_PID"

deadline=$(( $(date +%s) + 12 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -n "$(sidebar_for live1)" ] && [ -n "$(sidebar_for live2)" ] && [ "$(client_session)" = live1 ] && break
    sleep 0.1
done
[ -n "$(sidebar_for live1)" ] || fail_test 'live1 sidebar did not start'
[ -n "$(sidebar_for live2)" ] || fail_test 'live2 sidebar did not start'
[ "$(client_session)" = live1 ] || fail_test 'client did not attach to live1'

# Both AI panes are working: every presenter must show both rows animated.
wait_for_gradient live1 live1 present 10 'working live1 row has no gradient before switch'
wait_for_gradient live2 live1 present 10 'working live2 row has no gradient in live1 presenter before switch'

# Match the detached window to the attached one so the later switch changes no
# geometry at all (the shape of a real multi-session desktop on one terminal).
attached_size="$(window_size live1)"
tmuxc resize-window -t '=live2:' -x "${attached_size%x*}" -y "${attached_size#*x}"
deadline=$(( $(date +%s) + 5 ))
while [ "$(date +%s)" -lt "$deadline" ] && [ "$(window_size live2)" != "$attached_size" ]; do sleep 0.1; done
[ "$(window_size live2)" = "$attached_size" ] || fail_test "live2 window did not adopt size $attached_size (got $(window_size live2))"

# Let both AI panes go quiet so the switch happens with idle rows.
set_state live1 waiting
set_state live2 waiting
wait_for_gradient live2 live1 absent $((GRACE_SECONDS + 8)) 'idle live2 row kept gradient before switch'
wait_for_gradient live1 live1 absent $((GRACE_SECONDS + 8)) 'idle live1 row kept gradient before switch'

# Public Enter transition, exactly as the sidebar UI drives it.
tmuxc select-pane -t "$(sidebar_for live1)"
tmuxc send-keys -t "$(sidebar_for live1)" Down Enter
deadline=$(( $(date +%s) + 8 ))
while [ "$(date +%s)" -lt "$deadline" ] && [ "$(client_session)" != live2 ]; do sleep 0.1; done
[ "$(client_session)" = live2 ] || fail_test 'Enter did not switch to live2'
[ "$(window_size live2)" = "$attached_size" ] || fail_test "switch changed live2 window size to $(window_size live2)"
sleep 1

# The target presenter must keep observing: work starting after the switch
# lights the row, and stopping again clears it after the grace period.
set_state live2 active
wait_for_gradient live2 live2 present 10 'live2 presenter did not observe AI work starting after equal-size Enter switch'
set_state live1 active
wait_for_gradient live1 live2 present 10 'live2 presenter did not observe non-selected live1 work after equal-size Enter switch'

set_state live2 waiting
wait_for_gradient live2 live2 absent $((GRACE_SECONDS + 8)) 'live2 presenter kept gradient after AI went idle post-switch'

printf 'PASS: target presenter observes AI work starting after equal-size Enter switch\n'
printf 'PASS: target presenter observes non-selected AI work after equal-size Enter switch\n'
printf 'PASS: target presenter drops gradient after AI goes idle post-switch\n'
printf 'SUMMARY: pass=3 xfail=0 fail=0\n'
