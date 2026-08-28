#!/usr/bin/env bash
# Only the presenter whose session has an attached client animates the
# gradient.  A detached presenter keeps the running state on its rows (the
# frame carries gradient colours) but does not redraw at frame rate, and it
# resumes animating once the client switches to it.
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="${TMUX_SESSION_LAUNCHER_UNDER_TEST:-$REPO_ROOT/scripts/tmux-session-launcher}"
FAKE_AI="$TEST_DIR/fake-ai.sh"
SOCKET="gradient-detached-static-$$"
TMP_DIR="$(mktemp -d)"
CONTROL_DIR="$TMP_DIR/control"
mkdir -p "$CONTROL_DIR"

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
strip_ansi() { sed -E $'s/\x1B\[[0-9;?]*[ -\\/]*[@-~]//g'; }
fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    tmuxc list-clients -F '#{client_tty}|#{session_name}' >&2 || true
    tmuxc list-panes -a -F '#{session_name}|#{pane_id}|#{pane_title}|#{pane_current_command}' >&2 || true
    for debug_file in "$TMP_DIR"/*.debug; do
        [ -f "$debug_file" ] || continue
        printf '%s\n' "== $(basename "$debug_file") ==" >&2
        tail -n 30 "$debug_file" >&2
    done
    exit 1
}
# Raw (colour-bearing) line of the row naming $1 inside sidebar pane $2.
row_raw() {
    local session="$1" pane="$2" frame plain line_index
    frame="$(tmuxc capture-pane -e -p -t "$pane" 2>/dev/null || true)"
    plain="$(strip_ansi <<< "$frame")"
    mapfile -t raw_lines <<< "$frame"
    mapfile -t plain_lines <<< "$plain"
    for line_index in "${!plain_lines[@]}"; do
        if [[ "${plain_lines[$line_index]}" == *"$session"* ]]; then
            printf '%s\n' "${raw_lines[$line_index]}"
            return 0
        fi
    done
    printf '\n'
}
row_gradient_count() { { grep -o '38;5;' <<< "$(row_raw "$1" "$2")" || true; } | wc -l | tr -d ' '; }
wait_for_gradient() {
    local session="$1" presenter="$2" seconds="$3" message="$4" deadline colors=0
    deadline=$(( $(date +%s) + seconds ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        colors="$(row_gradient_count "$session" "$(sidebar_for "$presenter")")"
        [ "$colors" -ge 1 ] && return 0
        sleep 0.2
    done
    fail_test "$message (gradient cells=$colors)"
}
# Colour sequence of a row: the gradient phase per character, independent of
# the age column that ticks once a second.
row_colors() { { grep -oE '38;5;[0-9]+' <<< "$(row_raw "$1" "$2")" || true; } | tr '\n' ' '; }
# Does the row repaint with different colours within the sample window?
row_animates() {
    local session="$1" pane="$2" first sample
    first="$(row_colors "$session" "$pane")"
    for sample in 1 2 3 4 5 6; do
        sleep 0.15
        [ "$(row_colors "$session" "$pane")" != "$first" ] && return 0
    done
    return 1
}

cp "$(command -v bash)" "$TMP_DIR/codex"
for session in live1 live2; do
    printf 'active\n' > "$CONTROL_DIR/$session"
    tmuxc new-session -d -s "$session" -x 120 -y 30 \
        "'$TMP_DIR/codex' '$FAKE_AI' '$CONTROL_DIR/$session'" >/dev/null
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 35 -t "=$session:" \
        "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$TMP_DIR/$session.debug' TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar" >/dev/null
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

# Both presenters know both AI panes are working ...
wait_for_gradient live2 live1 10 'attached live1 presenter shows no gradient for working live2'
wait_for_gradient live2 live2 10 'detached live2 presenter shows no gradient state for working live2'
sleep 1.5

# ... but only the attached presenter repaints frames.
row_animates live2 "$(sidebar_for live1)" || fail_test 'attached live1 presenter does not animate the working live2 row'
if row_animates live2 "$(sidebar_for live2)"; then
    fail_test 'detached live2 presenter keeps animating although no client watches it'
fi
printf 'PASS: attached presenter animates, detached presenter holds a static gradient frame\n'

# Switching the client over hands the animation to the other presenter.
tmuxc select-pane -t "$(sidebar_for live1)"
tmuxc send-keys -t "$(sidebar_for live1)" Down Enter
deadline=$(( $(date +%s) + 8 ))
while [ "$(date +%s)" -lt "$deadline" ] && [ "$(client_session)" != live2 ]; do sleep 0.1; done
[ "$(client_session)" = live2 ] || fail_test 'Enter did not switch to live2'
wait_for_gradient live1 live2 10 'live2 presenter shows no gradient for working live1 after switch'
deadline=$(( $(date +%s) + 6 ))
until row_animates live1 "$(sidebar_for live2)"; do
    [ "$(date +%s)" -lt "$deadline" ] || fail_test 'live2 presenter did not start animating after the client switched to it'
done
# The source presenter stops at the switch itself and, at the latest, on its
# next one-second observation.
sleep 2.5
if row_animates live1 "$(sidebar_for live1)"; then
    fail_test 'live1 presenter keeps animating after the client left it'
fi
printf 'PASS: animation follows the attached client across an Enter switch\n'
printf 'SUMMARY: pass=2 xfail=0 fail=0\n'
