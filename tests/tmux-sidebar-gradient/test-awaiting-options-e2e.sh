#!/usr/bin/env bash
# Contract: the three Awaiting settings do what the popup says they do.
#
# Covered here and nowhere else:
#   @session-dock-awaiting-blink off  - the mark shows but never blanks
#   @session-dock-awaiting-blink <ms> - it blinks for that long, then settles
#                                       static while the state itself remains
#   @session-dock-awaiting-after <ms> - the mark is withheld until the session
#                                       has been silent for exactly that long
#
# The threshold is measured from the session's last visible output, and its
# floor is the busy window, so the number always means what it says. This test
# sets a threshold well above the floor and measures the delay against it; a
# value below the floor is raised to it, which the unit test covers.
# The marker on/off switch, the blink itself and the header count are asserted
# by test-awaiting-e2e; they are not repeated.
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
FAKE_AI="$TEST_DIR/fake-ai-heartbeat.sh"
SOCKET="gradient-awaiting-opts-$$"
TMP_DIR="$(mktemp -d)"
CONTROL="$TMP_DIR/control"
HEARTBEAT="$TMP_DIR/heartbeat"
DEBUG_FILE="$TMP_DIR/debug.log"
CLIENT_PID=""
cp "$(command -v bash)" "$TMP_DIR/codex"

cleanup() { kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true; tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM
tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
strip_ansi() { sed -E $'s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g'; }
fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    tmuxc capture-pane -p -t "$SIDEBAR" 2>/dev/null | strip_ansi | sed -n '1,8p' >&2 || true
    [ -f "$DEBUG_FILE" ] && tail -n 30 "$DEBUG_FILE" >&2 || true
    exit 1
}
row_for() {
    tmuxc capture-pane -p -t "$SIDEBAR" 2>/dev/null | strip_ansi |
        awk -v n="$1" '$0 ~ ("(^|[^[:alnum:]_-])" n "([^[:alnum:]_-]|$)") { print; exit }'
}
mark_for() { local row; row="$(row_for "$1")"; printf '%s' "${row:1:1}"; }

# What the mark does over a window: prints "on" if the glyph was ever seen,
# "blank" if a blank was ever seen, both if it alternates.
sample_marks() {   # sample_marks <session> <seconds>
    local name="$1" secs="$2" end saw_on='' saw_off='' m
    end=$(( $(date +%s) + secs ))
    while [ "$(date +%s)" -lt "$end" ]; do
        m="$(mark_for "$name")"
        case "$m" in '●') saw_on=on ;; ' '|'') saw_off=blank ;; esac
        sleep 0.2
    done
    printf '%s %s' "${saw_on:-.}" "${saw_off:-.}"
}
stop_ai()  { printf 'waiting\n' > "$CONTROL"; }
start_ai() { printf 'active\n'  > "$CONTROL"; }
wait_mark() {   # wait_mark <session> <seconds> -> 0 when the glyph appears
    local end=$(( $(date +%s) + $2 ))
    while [ "$(date +%s)" -lt "$end" ]; do
        [ "$(mark_for "$1")" = '●' ] && return 0
        sleep 0.2
    done
    return 1
}

start_ai
tmuxc new-session -d -s anchor -x 100 -y 30 'sleep 300' >/dev/null
tmuxc new-session -d -s worker -x 100 -y 30 "'$TMP_DIR/codex' '$FAKE_AI' '$CONTROL' '$HEARTBEAT'" >/dev/null
for s in anchor worker; do tmuxc set-option -q -t "=$s:" @dotfiles_sidebar_managed 1; done
tmuxc set-option -gq @session-dock-awaiting-after 1000
tmuxc split-window -d -h -b -l 35 -t '=anchor:' \
    "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$DEBUG_FILE' TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar"

coproc ATTACHED { script -qefc "tmux -L '$SOCKET' attach-session -t anchor" --log-out "$TMP_DIR/out.log" >/dev/null 2>&1; }
CLIENT_PID="$ATTACHED_PID"

# The loop's own verdict is the one that counts. Re-asking after the break
# re-captures the pane, and a capture that lands inside a repaint (the dock
# animates a working session, and a resize repaints every row) can miss a row
# that is on screen - which failed this test twice in one suite run, a second
# after the row had already been seen.
SIDEBAR=''
worker_seen=false
deadline=$(( $(date +%s) + 45 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    SIDEBAR="$(tmuxc list-panes -t '=anchor:' -F '#{pane_id}|#{pane_title}' |
        awk -F'|' '!done && $2=="dotfiles-session-sidebar" { print $1; done=1 }')"
    if [ -n "$SIDEBAR" ] && [ -n "$(row_for worker)" ]; then
        worker_seen=true
        break
    fi
    sleep 0.2
done
[ -n "$SIDEBAR" ] || fail_test 'the dock never started'
[ "$worker_seen" = true ] || fail_test 'the worker row never appeared'
[ -s "$HEARTBEAT" ] || fail_test 'the fake AI never produced output'

# --- blink off: the mark shows, and stays shown ------------------------------
tmuxc set-option -gq @session-dock-awaiting-blink off
stop_ai
wait_mark worker 25 || fail_test 'blink off: the mark never appeared'
read -r saw_on saw_off <<< "$(sample_marks worker 6)"
[ "$saw_on" = on ] || fail_test 'blink off: the glyph vanished'
[ "$saw_off" = . ] || fail_test 'blink off: the mark still blanked, so it is still blinking'
printf 'PASS: blink off leaves a steady mark\n'

# --- blink <ms>: blinks for the budget, then settles, state unaffected -------
start_ai; sleep 2
tmuxc set-option -gq @session-dock-awaiting-blink 4000
stop_ai
wait_mark worker 25 || fail_test 'blink budget: the mark never came back'
read -r saw_on saw_off <<< "$(sample_marks worker 3)"
[ "$saw_off" = blank ] || fail_test 'blink budget: it never blinked inside the budget'
sleep 5                       # past the 4 s budget
read -r saw_on saw_off <<< "$(sample_marks worker 6)"
[ "$saw_on" = on ] || fail_test 'blink budget: the mark disappeared once the budget ran out'
[ "$saw_off" = . ] || fail_test 'blink budget: it kept blinking past its budget'
printf 'PASS: a blink budget stops the blinking and leaves the mark standing\n'

# --- Mark After: the delay is the number, measured from the last output -------
start_ai; sleep 2
tmuxc set-option -gq @session-dock-awaiting-blink off
tmuxc set-option -gq @session-dock-awaiting-after 20000
sleep 2                       # let the presenter re-read the options
start_ai; sleep 2
stopped_at="$(date +%s)"
stop_ai
sleep 15                      # comfortably inside the 20 s threshold
if [ "$(mark_for worker)" = '●' ]; then
    fail_test "Mark After 20000: marked after only $(( $(date +%s) - stopped_at ))s"
fi
wait_mark worker 40 || fail_test 'Mark After 20000: the mark never appeared'
elapsed=$(( $(date +%s) - stopped_at ))
[ "$elapsed" -ge 20 ] ||
    fail_test "Mark After 20000: marked after ${elapsed}s, sooner than the threshold"
[ "$elapsed" -le 30 ] ||
    fail_test "Mark After 20000: took ${elapsed}s, far longer than the threshold"
printf 'PASS: Mark After 20000 marks the session after %ss of silence\n' "$elapsed"
printf 'SUMMARY: pass=3 xfail=0 fail=0\n'
