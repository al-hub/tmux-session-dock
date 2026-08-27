#!/usr/bin/env bash
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
FAKE_AI="$TEST_DIR/fake-ai-thinking.sh"
SOCKET="gradient-enter-switch-$$"
TMP_DIR="$(mktemp -d)"
CONTROL_DIR="$TMP_DIR/control"
DEBUG_FILE="$TMP_DIR/debug.log"
mkdir -p "$CONTROL_DIR"
cp "$(command -v bash)" "$TMP_DIR/codex"

cleanup()
{
    kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    wait "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        rm -rf "$TMP_DIR" 2>/dev/null && return 0
        sleep 0.1
    done
}
trap cleanup EXIT INT TERM

tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
client_session() { tmuxc list-clients -F '#{client_tty}|#{session_name}' | awk -F'|' 'NF == 2 { print $2; exit }'; }
client_tty() { tmuxc list-clients -F '#{client_tty}' | head -n 1; }
sidebar_for() {
    tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' |
        awk -F'|' '$2 == "dotfiles-session-sidebar" { print $1; exit }'
}
strip_ansi() { sed -E $'s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g'; }

fail_test()
{
    printf 'FAIL: %s\n' "$1" >&2
    tmuxc list-clients -F '#{client_tty}|#{session_name}' >&2 || true
    tmuxc list-panes -a -F '#{session_name}|#{pane_id}|#{pane_title}|#{pane_current_command}' >&2 || true
    [ -f "$DEBUG_FILE" ] && tail -n 80 "$DEBUG_FILE" >&2 || true
    exit 1
}

sessions=(eg1 eg2 eg3 eg4 eg5 eg6)
for session in "${sessions[@]}"; do
    control="$CONTROL_DIR/$session"
    printf 'active\n' > "$control"
    tmuxc new-session -d -s "$session" -x 120 -y 35 \
        "'$TMP_DIR/codex' '$FAKE_AI' '$control'" >/dev/null
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 35 -t "=$session:" \
        "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$DEBUG_FILE' TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar"
done

attach_command="tmux -L '$SOCKET' attach-session -t '${sessions[0]}'"
coproc ATTACHED { script -qefc "$attach_command" --log-in "$TMP_DIR/input.log" --log-out "$TMP_DIR/output.log" >/dev/null 2>&1; }
CLIENT_PID="$ATTACHED_PID"

deadline=$(( $(date +%s) + 15 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    ready=0
    for session in "${sessions[@]}"; do
        pane="$(sidebar_for "$session")"
        [ -n "$pane" ] || continue
        tmuxc capture-pane -p -t "$pane" 2>/dev/null | grep -Fq sessions && ready=$((ready + 1))
    done
    [ "$ready" -eq 6 ] && break
    sleep 0.1
done
[ "$ready" -eq 6 ] || fail_test "all six session sidebars did not become ready"

check_current_sidebar_gradient()
{
    local expected_session="$1" pane frame_one frame_two plain names colors attempt sample full_samples
    pane="$(sidebar_for "$expected_session")"
    [ -n "$pane" ] || fail_test "sidebar missing after Enter switch to $expected_session"
    names=0
    for attempt in $(seq 1 20); do
        frame_one="$(tmuxc capture-pane -e -p -t "$pane" 2>/dev/null || true)"
        plain="$(strip_ansi <<< "$frame_one")"
        names="$(grep -o 'eg[1-6]' <<< "$plain" | sort -u | wc -l | tr -d ' ' || true)"
        [ "$names" -eq 6 ] && break
        sleep 0.05
    done
    [ "$names" -eq 6 ] || fail_test "expected six session rows after switch to $expected_session, got $names"
    colors="$(grep -o '38;5;' <<< "$frame_one" | wc -l | tr -d ' ' || true)"
    [ "$colors" -ge 6 ] || fail_test "gradient disappeared after Enter switch to $expected_session"
    full_samples=0
    for sample in $(seq 1 20); do
        sleep 0.05
        frame_two="$(tmuxc capture-pane -e -p -t "$pane" 2>/dev/null || true)"
        plain="$(strip_ansi <<< "$frame_two")"
        names="$(grep -o 'eg[1-6]' <<< "$plain" | sort -u | wc -l | tr -d ' ' || true)"
        colors="$(grep -o '38;5;' <<< "$frame_two" | wc -l | tr -d ' ' || true)"
        [ "$names" -eq 6 ] || continue
        full_samples=$((full_samples + 1))
        [ "$colors" -ge 6 ] || fail_test "gradient disappeared during post-Enter sample $sample on $expected_session"
    done
    [ "$full_samples" -ge 5 ] || fail_test "sidebar never stabilized for five gradient samples after Enter on $expected_session"
    [ "$frame_one" != "$frame_two" ] || fail_test "gradient stopped changing after Enter switch to $expected_session"
}

for index in 1 2 3 4 5 6; do
    target="${sessions[$((index - 1))]}"
    [ "$index" -eq 1 ] || {
        current="$(client_session)"
        sidebar="$(sidebar_for "$current")"
        tmuxc select-pane -t "$sidebar"
        tmuxc send-keys -t "$sidebar" Down Enter
        switch_deadline=$(( $(date +%s) + 8 ))
        while [ "$(date +%s)" -lt "$switch_deadline" ] && [ "$(client_session)" != "$target" ]; do
            sleep 0.1
        done
        [ "$(client_session)" = "$target" ] || fail_test "Enter did not switch to $target"
    }
    check_current_sidebar_gradient "$target"
    printf 'PASS: gradient survives Enter switch to %s\n' "$target"
done

printf 'SUMMARY: pass=6 xfail=0 fail=0\n'
