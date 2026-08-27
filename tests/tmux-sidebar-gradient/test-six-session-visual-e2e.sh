#!/usr/bin/env bash
set -euo pipefail
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
FAKE_AI="$TEST_DIR/fake-ai.sh"
SOCKET="gradient-six-session-$$"
TMP_DIR="$(mktemp -d)"
CONTROL_DIR="$TMP_DIR/control"
DEBUG_FILE="$TMP_DIR/debug.log"
FRAME_LOG="$TMP_DIR/sidebar.frames"
mkdir -p "$CONTROL_DIR"
cp "$(command -v bash)" "$TMP_DIR/codex"

cleanup()
{
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

tmuxc()
{
    tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"
}

fail_with_capture()
{
    printf 'FAIL: %s\n' "$1" >&2
    tmuxc list-sessions -F '#{session_name}|#{@dotfiles_sidebar_managed}' >&2 || true
    tmuxc list-panes -a -F '#{session_name}|#{pane_id}|#{pane_title}|#{pane_current_command}' >&2 || true
    [ -f "$FRAME_LOG" ] && tail -c 2000 "$FRAME_LOG" >&2 || true
    [ -f "$DEBUG_FILE" ] && tail -n 40 "$DEBUG_FILE" >&2 || true
    exit 1
}

sessions=(gradient-1 gradient-2 gradient-3 gradient-4 gradient-5 gradient-6)

for session in "${sessions[@]}"; do
    control="$CONTROL_DIR/$session"
    printf 'active\n' > "$control"
    tmuxc new-session -d -s "$session" -x 100 -y 30 \
        "'$TMP_DIR/codex' '$FAKE_AI' '$control'" >/dev/null
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
done

SIDEBAR_PANE="$(tmuxc split-window -d -P -F '#{pane_id}' -t '=gradient-1:' \
    -h -b -l 35 \
    "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$DEBUG_FILE' TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar")"
tmuxc select-pane -t "$SIDEBAR_PANE" -T dotfiles-session-sidebar
tmuxc select-pane -t "$SIDEBAR_PANE"
tmuxc pipe-pane -o -t "$SIDEBAR_PANE" "cat >> '$FRAME_LOG'"

deadline=$(( $(date +%s) + 15 ))
frame=''
while [ "$(date +%s)" -lt "$deadline" ]; do
    frame="$(cat "$FRAME_LOG" 2>/dev/null || true)"
    plain_frame="$(sed -E $'s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g' <<< "$frame")"
    if [ "$(grep -o 'gradient-[1-6]' <<< "$plain_frame" | sort -u | wc -l | tr -d ' ')" -eq 6 ]; then
        break
    fi
    sleep 0.1
done

[ -n "$frame" ] || fail_with_capture 'sidebar did not produce a capture'
visible_count="$(grep -o 'gradient-[1-6]' <<< "$plain_frame" | sort -u | wc -l | tr -d ' ')"
[ "$visible_count" -eq 6 ] || \
    fail_with_capture "expected six visible sessions, got $visible_count"

gradient_count="$(grep -o '38;5;' <<< "$frame" | wc -l | tr -d ' ')"
[ "$gradient_count" -ge 6 ] || \
    fail_with_capture "expected gradient ANSI output for all six rows, got $gradient_count cells"

frame_one="$frame"
sleep 0.2
frame_two="$(cat "$FRAME_LOG" 2>/dev/null || true)"
[ "${#frame_two}" -gt "${#frame_one}" ] || \
    fail_with_capture 'six-session sidebar capture did not change between animation frames'

printf 'PASS: six AI sessions are visible in the sidebar\n'
printf 'PASS: all six visible session rows contain gradient ANSI output\n'
printf 'PASS: six-session gradient capture changes between frames\n'
printf 'SUMMARY: pass=3 xfail=0 fail=0\n'
