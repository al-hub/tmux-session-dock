#!/usr/bin/env bash
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
FAKE_AI="$TEST_DIR/fake-ai-fullscreen-redraw.sh"
SOCKET="gradient-opencode-nonselected-stability-$$"
TMP_DIR="$(mktemp -d)"
DEBUG_FILE="$TMP_DIR/debug.log"
cp "$(command -v bash)" "$TMP_DIR/opencode"

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
strip_ansi() { sed -E $'s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g'; }
fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    [ -f "$DEBUG_FILE" ] && tail -n 100 "$DEBUG_FILE" >&2 || true
    exit 1
}

for session in live1 live2; do
    # The fake AI exits when its control file is missing, which would destroy
    # the session before the sidebar is split into it: write it first.
    printf 'active\n' > "$TMP_DIR/$session.control"
    tmuxc new-session -d -s "$session" -x 100 -y 30 \
        "'$TMP_DIR/opencode' '$FAKE_AI' '$TMP_DIR/$session.control'" >/dev/null
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 35 -t "=$session:" \
        "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$DEBUG_FILE' TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar"
done

coproc ATTACHED {
    script -qefc "tmux -L '$SOCKET' attach-session -t live1" \
        --log-in "$TMP_DIR/input.log" --log-out "$TMP_DIR/output.log" >/dev/null 2>&1
}
CLIENT_PID="$ATTACHED_PID"

deadline=$(( $(date +%s) + 12 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    sidebar="$(sidebar_for live1)"
    [ -n "$sidebar" ] && tmuxc capture-pane -p -t "$sidebar" 2>/dev/null | grep -Fq sessions && break
    sleep 0.1
done
[ -n "${sidebar:-}" ] || fail_test 'live1 sidebar did not become ready'

ai_pane="$(tmuxc list-panes -t '=live1:' -F '#{pane_id}|#{pane_current_command}' |
    awk -F'|' '$2 == "opencode" { print $1; exit }')"
[ -n "$ai_pane" ] || fail_test 'live1 opencode-shaped pane was not detected'

screen_one="$(tmuxc capture-pane -p -J -t "$ai_pane" -S -4 | cksum | awk '{print $1}')"
sleep 0.4
screen_two="$(tmuxc capture-pane -p -J -t "$ai_pane" -S -4 | cksum | awk '{print $1}')"
[ "$screen_one" != "$screen_two" ] || fail_test 'opencode-shaped fullscreen screen did not redraw'

tmuxc select-pane -t "$sidebar"
tmuxc send-keys -t "$sidebar" Down Enter
switch_deadline=$(( $(date +%s) + 8 ))
while [ "$(date +%s)" -lt "$switch_deadline" ] && [ "$(client_session)" != live2 ]; do
    sleep 0.1
done
[ "$(client_session)" = live2 ] || fail_test 'Enter did not switch to live2'

sidebar="$(sidebar_for live2)"
[ -n "$sidebar" ] || fail_test 'live2 sidebar missing after Enter switch'
# Let the target window's layout handover finish before beginning the activity
# observation window.  This keeps transition geometry reconciliation separate
# from the observer's no-full-render assertion.
sleep 2
debug_start_line="$(wc -l < "$DEBUG_FILE" 2>/dev/null || printf '0')"

gradient_samples=0
for sample in $(seq 1 20); do
    sleep 0.15
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
    [ "$live1_line" -ge 0 ] || fail_test 'non-selected live1 row missing after Enter'
    colors="$(grep -o '38;5;' <<< "${raw_lines[$live1_line]}" | wc -l | tr -d ' ' || true)"
    [ "$colors" -ge 1 ] || fail_test "non-selected live1 gradient stopped at sample $sample/20"
    gradient_samples=$((gradient_samples + 1))
done

# Both presenters log into DEBUG_FILE; only the attached live2 presenter is
# under test here.  The detached live1 presenter repaints once after the
# client leaves it, which is a handover artefact, not AI activity.
activity_full_renders="$(tail -n "+$((debug_start_line + 1))" "$DEBUG_FILE" 2>/dev/null |
    { grep "pane=$sidebar " || true; } | { grep -c 'render_full start' || true; })"
[ "$activity_full_renders" -eq 0 ] ||
    fail_test "AI activity triggered $activity_full_renders full sidebar render(s)"

printf 'PASS: opencode-shaped fullscreen redraw continues after Enter switch\n'
printf 'PASS: non-selected session gradient stayed visible for %s/20 samples\n' "$gradient_samples"
printf 'PASS: AI activity triggered no full sidebar render\n'
printf 'SUMMARY: pass=2 xfail=0 fail=0\n'
