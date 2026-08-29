#!/usr/bin/env bash
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
FAKE_AI="$TEST_DIR/fake-ai-fullscreen-redraw.sh"
SOCKET="gradient-empty-activity-enter-$$"
TMP_DIR="$(mktemp -d)"
CONTROL_DIR="$TMP_DIR/control"
DEBUG_FILE="$TMP_DIR/debug.log"
mkdir -p "$CONTROL_DIR"
cp "$(command -v bash)" "$TMP_DIR/codex"

cleanup() {
    kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    wait "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
client_session() { tmuxc list-clients -F '#{session_name}' | sed -n 1p; }
sidebar_for() {
    tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' |
        awk -F'|' '!done && $2 == "dotfiles-session-sidebar" { print $1; done = 1 }'
}
strip_ansi() { sed -E $'s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g'; }
fail_test() { printf 'FAIL: %s\n' "$1" >&2; [ -f "$DEBUG_FILE" ] && tail -n 80 "$DEBUG_FILE" >&2 || true; exit 1; }

for session in live1 live2; do
    control="$CONTROL_DIR/$session"
    printf 'active\n' > "$control"
    tmuxc new-session -d -s "$session" -x 100 -y 30 \
        "'$TMP_DIR/codex' '$FAKE_AI' '$control'" >/dev/null
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 35 -t "=$session:" \
        "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$DEBUG_FILE' TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar"
done

coproc ATTACHED { script -qefc "tmux -L '$SOCKET' attach-session -t live1" --log-in "$TMP_DIR/input.log" --log-out "$TMP_DIR/output.log" >/dev/null 2>&1; }
CLIENT_PID="$ATTACHED_PID"

deadline=$(( $(date +%s) + 12 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    sidebar="$(sidebar_for live1)"
    [ -n "$sidebar" ] && tmuxc capture-pane -p -t "$sidebar" 2>/dev/null | grep -Fq sessions && break
    sleep 0.1
done
[ -n "${sidebar:-}" ] || fail_test 'live1 sidebar did not become ready'

ai_pane="$(tmuxc list-panes -t '=live1:' -F '#{pane_id}|#{pane_current_command}' | awk -F'|' '!done && $2 == "codex" { print $1; done = 1 }')"
[ -n "$ai_pane" ] || fail_test 'fullscreen redraw AI pane was not detected'

screen_one="$(tmuxc capture-pane -p -J -t "$ai_pane" -S -4 | cksum | awk '{print $1}')"
screen_changed=0
for sample in $(seq 1 8); do
    sleep 0.1
    screen_two="$(tmuxc capture-pane -p -J -t "$ai_pane" -S -4 | cksum | awk '{print $1}')"
    [ "$screen_one" != "$screen_two" ] && screen_changed=1 && break
    screen_one="$screen_two"
done
[ "$screen_changed" -eq 1 ] || fail_test 'AI screen did not redraw'

pane_signature_one="$(tmuxc display-message -p -t "$ai_pane" '#{pane_activity}:#{history_size}:#{cursor_y}:#{cursor_x}')"
sleep 0.4
pane_signature_two="$(tmuxc display-message -p -t "$ai_pane" '#{pane_activity}:#{history_size}:#{cursor_y}:#{cursor_x}')"
[ "$pane_signature_one" = "$pane_signature_two" ] || fail_test 'fixture did not preserve stable pane activity signature'

tmuxc select-pane -t "$sidebar"
tmuxc send-keys -t "$sidebar" Down Enter
switch_deadline=$(( $(date +%s) + 8 ))
while [ "$(date +%s)" -lt "$switch_deadline" ] && [ "$(client_session)" != live2 ]; do sleep 0.1; done
[ "$(client_session)" = live2 ] || fail_test 'Enter did not switch to live2'

sidebar="$(sidebar_for live2)"
[ -n "$sidebar" ] || fail_test 'live2 sidebar missing after Enter switch'
# Sample only after the live2 presenter has drawn its handover frame (its own
# row marked current); until then the pane shows the frames of the handover
# render sequence, whose cleared rows are not AI activity.
# ... and until that frame has held still for a moment: the handover render
# sequence (initial, geometry, enter fallback) can still repaint after the
# first marked frame.
handover_deadline=$(( $(date +%s) + 8 ))
settled_plain=""
while [ "$(date +%s)" -lt "$handover_deadline" ]; do
    plain_now="$(tmuxc capture-pane -p -t "$sidebar" 2>/dev/null || true)"
    if grep -Eq '^>[^a-z]*live2' <<< "$plain_now" && [ "$plain_now" = "$settled_plain" ]; then
        break
    fi
    settled_plain="$plain_now"
    sleep 0.3
done
grep -Eq '^>[^a-z]*live2' <<< "$settled_plain" || fail_test 'live2 presenter never marked live2 current after Enter'
gradient_samples=0
previous_frame=''
frame_changed=0
for sample in $(seq 1 12); do
    sleep 0.2
    frame="$(tmuxc capture-pane -e -p -t "$sidebar" 2>/dev/null || true)"
    plain="$(strip_ansi <<< "$frame")"
    mapfile -t raw_lines <<< "$frame"
    mapfile -t plain_lines <<< "$plain"
    live1_line=-1
    for line_index in "${!plain_lines[@]}"; do
        if [[ "${plain_lines[$line_index]}" == *live1* ]]; then
            live1_line="$line_index"
            break
        fi
    done
    [ "$live1_line" -ge 0 ] || fail_test 'live1 row missing after Enter'
    colors="$(grep -o '38;5;' <<< "${raw_lines[$live1_line]}" | wc -l | tr -d ' ' || true)"
    [ "$colors" -ge 1 ] && gradient_samples=$((gradient_samples + 1))
    [ -n "$previous_frame" ] && [ "$frame" != "$previous_frame" ] && frame_changed=1
    previous_frame="$frame"
done
[ "$gradient_samples" -ge 2 ] || fail_test "non-selected live1 gradient stopped after Enter ($gradient_samples/12 samples)"
[ "$frame_changed" -eq 1 ] || fail_test 'gradient frame did not continue changing after Enter'

printf 'PASS: fullscreen redraw changes while pane activity signature stays stable\n'
printf 'PASS: non-selected fullscreen redraw session retains gradient after Enter\n'
printf 'SUMMARY: pass=2 xfail=0 fail=0\n'
