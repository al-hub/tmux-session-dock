#!/usr/bin/env bash
# Verify public sidebar-width behavior. State-file corruption is setup only;
# persistence and archive isolation are asserted through visible pane geometry.

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd -P)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
SOCKET="dotfiles-width-persist-$$"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-width-persist.XXXXXX")"
HISTORY_DIR="$RUN_DIR/history"
HOME_DIR="$RUN_DIR/home"
STATE_DIR="$HOME_DIR/.local/state/dotfiles"
WIDTH_STATE_FILE="$STATE_DIR/tmux-sidebar-width"
TMUX=(tmux -L "$SOCKET" -f "$REPO_ROOT/dotfiles/tmux.conf")
KEEP_RUN_DIR="${KEEP_RUN_DIR:-false}"

mkdir -p "$HISTORY_DIR" "$STATE_DIR"
source "$REPO_ROOT/tests/lib/test_artifact_helper.sh"

cleanup() {
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        KEEP_RUN_DIR=true
        dump_test_failure_artifacts "$SOCKET" "$RUN_DIR"
    fi
    "${TMUX[@]}" kill-server >/dev/null 2>&1 || true
    [ "$KEEP_RUN_DIR" = true ] || rm -rf "$RUN_DIR"
}
trap cleanup EXIT

tmuxc() { HOME="$HOME_DIR" TMUX_SESSION_HISTORY_DIR="$HISTORY_DIR" "${TMUX[@]}" "$@"; }

sidebar_pane_for() {
    tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' |
        awk -F '|' '$2 == "dotfiles-session-sidebar" { print $1; exit }'
}

wait_for_width() {
    local pane_id="$1" expected="$2" attempt actual
    for attempt in $(seq 1 100); do
        actual="$(tmuxc display-message -p -t "$pane_id" '#{pane_width}' 2>/dev/null || true)"
        [ "$actual" = "$expected" ] && return 0
        sleep 0.05
    done
    echo "FAIL: expected visible sidebar width $expected, got ${actual:-absent}" >&2
    return 1
}

provision_session() {
    local session_name="$1" width="${2:-}" window_id pane_id
    tmuxc new-session -d -s "$session_name" -x 140 -y 50 -c "$REPO_ROOT" 'sleep 300'
    window_id="$(tmuxc display-message -p -t "=$session_name:" '#{window_id}')"
    tmuxc set-option -wq -t "$window_id" @dotfiles_sidebar_managed 1
    if [ -n "$width" ]; then
        tmuxc run-shell "$LAUNCHER --ensure-sidebar-window '$window_id' '$width'"
    else
        tmuxc run-shell "$LAUNCHER --ensure-sidebar-window '$window_id'"
    fi
    for _ in $(seq 1 100); do
        pane_id="$(sidebar_pane_for "$session_name")"
        [ -n "$pane_id" ] && { printf '%s\n' "$pane_id"; return 0; }
        sleep 0.05
    done
    echo "FAIL: sidebar was not provisioned for $session_name" >&2
    return 1
}

echo "=== [1/3] Corrupt persisted width falls back to a drawable pane ==="
printf 'not-a-width\n' > "$WIDTH_STATE_FILE"
fallback_pane="$(provision_session fallback)"
fallback_width="$(tmuxc display-message -p -t "$fallback_pane" '#{pane_width}')"
[ "$fallback_width" -ge 20 ] && [ "$fallback_width" -le 45 ] || {
    echo "FAIL: corrupt width state created unsupported visible width $fallback_width" >&2
    exit 1
}

echo "=== [2/3] User resize survives a server restart ==="
tmuxc resize-pane -t "$fallback_pane" -x 40
wait_for_width "$fallback_pane" 40
for _ in $(seq 1 100); do
    [ "$(tr -d '[:space:]' < "$WIDTH_STATE_FILE" 2>/dev/null || true)" = 40 ] && break
    sleep 0.05
done
tmuxc kill-server
sleep 0.2
tmuxc new-session -d -s anchor -x 140 -y 50 -c "$REPO_ROOT" 'sleep 300'
restart_pane="$(provision_session restarted)"
wait_for_width "$restart_pane" 40

echo "=== [3/3] Archive restore keeps the current user width ==="
tmuxc run-shell "$LAUNCHER --archive-session restarted false"
archive_path="$HISTORY_DIR/restarted.tsv"
[ -f "$archive_path" ] || { echo "FAIL: archive was not created" >&2; exit 1; }
tmuxc resize-pane -t "$restart_pane" -x 28
wait_for_width "$restart_pane" 28
tmuxc kill-session -t '=restarted:'
tmuxc run-shell "$LAUNCHER --restore-archive '$archive_path' op-width-test false"
tmuxc has-session -t '=restarted:' || { echo "FAIL: archived session was not restored" >&2; exit 1; }
restored_pane="$(sidebar_pane_for restarted)"
[ -n "$restored_pane" ] || { echo "FAIL: restored session has no sidebar" >&2; exit 1; }
wait_for_width "$restored_pane" 28

echo "PASS: visible width fallback, restart persistence, and archive isolation hold"
