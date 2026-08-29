#!/usr/bin/env bash
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
FAKE_AI="$TEST_DIR/fake-ai-fullscreen-redraw.sh"
SOCKET="gradient-six-empty-activity-enter-$$"
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
sidebar_for() { tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' | awk -F'|' '!done && $2 == "dotfiles-session-sidebar" { print $1; done = 1 }'; }
strip_ansi() { sed -E $'s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g'; }
fail_test() { printf 'FAIL: %s\n' "$1" >&2; [ -f "$DEBUG_FILE" ] && tail -n 80 "$DEBUG_FILE" >&2 || true; exit 1; }

sessions=(sw1 sw2 sw3 sw4 sw5 sw6)
for index in "${!sessions[@]}"; do
    session="${sessions[$index]}"
    control="$CONTROL_DIR/$session"
    printf 'active\n' > "$control"
    tmuxc new-session -d -s "$session" -x 120 -y 35 "'$TMP_DIR/codex' '$FAKE_AI' '$control' '$index'" >/dev/null
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
    if [ "$index" -eq 0 ]; then
        tmuxc split-window -d -h -b -l 35 -t "=$session:" "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$DEBUG_FILE' TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar"
    fi
done

coproc ATTACHED { script -qefc "tmux -L '$SOCKET' attach-session -t sw1" --log-in "$TMP_DIR/input.log" --log-out "$TMP_DIR/output.log" >/dev/null 2>&1; }
CLIENT_PID="$ATTACHED_PID"
deadline=$(( $(date +%s) + 15 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    sidebar="$(sidebar_for sw1)"
    [ -n "$sidebar" ] && tmuxc capture-pane -p -t "$sidebar" 2>/dev/null | grep -Fq sessions && ready=1
    [ "${ready:-0}" -eq 1 ] && break
    sleep 0.1
done
[ "${ready:-0}" -eq 1 ] || fail_test 'fullscreen-redraw sidebar did not become ready'

for session in "${sessions[@]}"; do
    ai_pane="$(tmuxc list-panes -t "=$session:" -F '#{pane_id}|#{pane_current_command}' | awk -F'|' '!done && $2 == "codex" { print $1; done = 1 }')"
    [ -n "$ai_pane" ] || fail_test "$session AI pane was not detected"
    before="$(tmuxc capture-pane -p -J -t "$ai_pane" -S -4 | cksum | awk '{print $1}')"
    changed=0
    for sample in $(seq 1 8); do
        sleep 0.1
        after="$(tmuxc capture-pane -p -J -t "$ai_pane" -S -4 | cksum | awk '{print $1}')"
        [ "$before" != "$after" ] && changed=1 && break
        before="$after"
    done
    [ "$changed" -eq 1 ] || fail_test "$session AI screen did not redraw"
    signature_one="$(tmuxc display-message -p -t "$ai_pane" '#{pane_activity}:#{history_size}:#{cursor_y}:#{cursor_x}')"
    sleep 0.4
    signature_two="$(tmuxc display-message -p -t "$ai_pane" '#{pane_activity}:#{history_size}:#{cursor_y}:#{cursor_x}')"
    [ "$signature_one" = "$signature_two" ] || fail_test "$session pane signature changed"
done

sample_gradients() {
    local current="$1" pane frame plain session line colors line_index index
    pane="$(sidebar_for "$current")"
    [ -n "$pane" ] || fail_test "sidebar missing after switch to $current"
    frame="$(tmuxc capture-pane -e -p -t "$pane" 2>/dev/null || true)"
    plain="$(strip_ansi <<< "$frame")"
    mapfile -t raw_lines <<< "$frame"
    mapfile -t plain_lines <<< "$plain"
    for session in "${sessions[@]}"; do
        line_index=-1
        for index in "${!plain_lines[@]}"; do
            if [[ "${plain_lines[$index]}" == *"$session"* ]]; then
                line_index="$index"
                break
            fi
        done
        [ "$line_index" -ge 0 ] || fail_test "$session row missing after switch to $current"
        colors="$(grep -o '38;5;' <<< "${raw_lines[$line_index]}" | wc -l | tr -d ' ' || true)"
        if [ "$colors" -ge 1 ]; then
            gradient_seen["$session"]=1
        fi
    done
}

for index in $(seq 0 4); do
    current="${sessions[$index]}"
    target="${sessions[$((index + 1))]}"
    sidebar="$(sidebar_for "$current")"
    tmuxc select-pane -t "$sidebar"
    tmuxc send-keys -t "$sidebar" Down Enter
    switch_deadline=$(( $(date +%s) + 8 ))
    while [ "$(date +%s)" -lt "$switch_deadline" ] && [ "$(client_session)" != "$target" ]; do sleep 0.1; done
    [ "$(client_session)" = "$target" ] || fail_test "Enter did not switch to $target"
    # Wait for the target presenter's handover frame (its own row marked
    # current) before sampling; the render sequence before it clears rows.
    handover_deadline=$(( $(date +%s) + 8 ))
    settled_plain=""
    while [ "$(date +%s)" -lt "$handover_deadline" ]; do
        plain_now="$(tmuxc capture-pane -p -t "$(sidebar_for "$target")" 2>/dev/null || true)"
        if grep -Eq "^>[^a-z]*$target" <<< "$plain_now" && [ "$plain_now" = "$settled_plain" ]; then
            break
        fi
        settled_plain="$plain_now"
        sleep 0.3
    done
    sleep 0.5
        declare -A gradient_seen=()
        for sample in $(seq 1 12); do
            sample_gradients "$target"
            sleep 0.2
        done
        for session in "${sessions[@]}"; do
            [ "${gradient_seen[$session]:-0}" -eq 1 ] || fail_test "$session never showed gradient after switch to $target"
        done
    printf 'PASS: six fullscreen-redraw gradients survive Enter switch to %s\n' "$target"
done

printf 'SUMMARY: pass=5 xfail=0 fail=0\n'
