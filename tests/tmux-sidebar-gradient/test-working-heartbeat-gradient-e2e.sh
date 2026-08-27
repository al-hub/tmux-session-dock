#!/usr/bin/env bash
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
FAKE_AI="$TEST_DIR/fake-ai-heartbeat.sh"
SOCKET="gradient-working-heartbeat-$$"
TMP_DIR="$(mktemp -d)"
CONTROL_DIR="$TMP_DIR/control"
HEARTBEAT_DIR="$TMP_DIR/heartbeat"
DEBUG_FILE="$TMP_DIR/debug.log"
mkdir -p "$CONTROL_DIR" "$HEARTBEAT_DIR"
cp "$(command -v bash)" "$TMP_DIR/codex"

cleanup() { kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true; tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM
tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
client_session() { tmuxc list-clients -F '#{session_name}' | head -n 1; }
sidebar_for() { tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' | awk -F'|' '$2 == "dotfiles-session-sidebar" { print $1; exit }'; }
strip_ansi() { sed -E $'s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g'; }
fail_test() { printf 'FAIL: %s\n' "$1" >&2; tmuxc list-panes -a -F '#{session_name}|#{pane_id}|#{pane_title}|#{pane_current_command}|#{pane_pid}' >&2 || true; [ -f "$DEBUG_FILE" ] && tail -n 60 "$DEBUG_FILE" >&2 || true; exit 1; }

for session in work1 work2; do
    control="$CONTROL_DIR/$session"
    heartbeat="$HEARTBEAT_DIR/$session"
    printf 'active\n' > "$control"
    tmuxc new-session -d -s "$session" -x 100 -y 30 "'$TMP_DIR/codex' '$FAKE_AI' '$control' '$heartbeat'" >/dev/null
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 35 -t "=$session:" "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$DEBUG_FILE' TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar"
done

coproc ATTACHED { script -qefc "tmux -L '$SOCKET' attach-session -t work1" --log-in "$TMP_DIR/input.log" --log-out "$TMP_DIR/output.log" >/dev/null 2>&1; }
CLIENT_PID="$ATTACHED_PID"

deadline=$(( $(date +%s) + 12 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -s "$HEARTBEAT_DIR/work1" ] && [ -s "$HEARTBEAT_DIR/work2" ] && break
    sleep 0.1
done
[ -s "$HEARTBEAT_DIR/work1" ] || fail_test 'work1 heartbeat did not start'
[ -s "$HEARTBEAT_DIR/work2" ] || fail_test 'work2 heartbeat did not start'

heartbeat_before="$(cat "$HEARTBEAT_DIR/work1")"
sleep 0.3
heartbeat_after="$(cat "$HEARTBEAT_DIR/work1")"
[ "$heartbeat_before" != "$heartbeat_after" ] || fail_test 'work1 heartbeat did not advance while AI process was working'

pane_work1="$(tmuxc list-panes -t '=work1:' -F '#{pane_id}|#{pane_current_command}|#{pane_pid}' | awk -F'|' '$2 == "codex" { print; exit }')"
[ -n "$pane_work1" ] || fail_test 'work1 AI process is not visible as codex'
ai_pid="${pane_work1##*|}"
kill -0 "$ai_pid" 2>/dev/null || fail_test 'work1 AI process is not alive'

sidebar="$(sidebar_for work1)"
tmuxc select-pane -t "$sidebar"
tmuxc send-keys -t "$sidebar" Down Enter
switch_deadline=$(( $(date +%s) + 8 ))
while [ "$(date +%s)" -lt "$switch_deadline" ] && [ "$(client_session)" != work2 ]; do sleep 0.1; done
[ "$(client_session)" = work2 ] || fail_test 'Enter did not switch to work2'

heartbeat_before="$(cat "$HEARTBEAT_DIR/work1")"
sleep 0.3
heartbeat_after="$(cat "$HEARTBEAT_DIR/work1")"
[ "$heartbeat_before" != "$heartbeat_after" ] || fail_test 'non-selected work1 AI heartbeat stopped after switching to work2'
kill -0 "$ai_pid" 2>/dev/null || fail_test 'non-selected work1 AI process stopped after switching to work2'
sleep 1.3
heartbeat_before="$(cat "$HEARTBEAT_DIR/work1")"
sleep 0.3
heartbeat_after="$(cat "$HEARTBEAT_DIR/work1")"
[ "$heartbeat_before" != "$heartbeat_after" ] || fail_test 'non-selected work1 AI heartbeat stopped during sustained post-switch work'
kill -0 "$ai_pid" 2>/dev/null || fail_test 'non-selected work1 AI process stopped during sustained post-switch work'

sidebar="$(sidebar_for work2)"
frame="$(tmuxc capture-pane -e -p -t "$sidebar" 2>/dev/null || true)"
plain="$(strip_ansi <<< "$frame")"
grep -Fq work1 <<< "$plain" || fail_test 'non-selected work1 row is missing after switch'
mapfile -t raw_lines <<< "$frame"
mapfile -t plain_lines <<< "$plain"
work1_line=-1
for line_index in "${!plain_lines[@]}"; do
    if [[ "${plain_lines[$line_index]}" == *work1* ]]; then
        work1_line="$line_index"
        break
    fi
done
[ "$work1_line" -ge 0 ] || fail_test 'could not locate work1 row after switch'
colors="$(grep -o '38;5;' <<< "${raw_lines[$work1_line]}" | wc -l | tr -d ' ' || true)"
[ "$colors" -ge 1 ] || fail_test 'working non-selected work1 row has no gradient after switch'

printf 'PASS: independent work1 heartbeat advances before switching\n'
printf 'PASS: work1 AI process remains alive after becoming non-selected\n'
printf 'PASS: non-selected working session retains gradient after Enter switch\n'
printf 'SUMMARY: pass=3 xfail=0 fail=0\n'
