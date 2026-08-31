#!/usr/bin/env bash
# Regression contract test:
# When deleting a session that currently holds the subpane lease ('d' key in dock),
# the subpanes MUST be safely migrated to the surviving fallback session before
# the target session is killed, so that subpane terminal processes/content are NOT reset.
set -euo pipefail

TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"
SOCKET="test-subpane-del-preserve-$$"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-del-subpane-content.XXXXXX")"
HISTORY_DIR="$RUN_DIR/history"
mkdir -p "$HISTORY_DIR" "$RUN_DIR/home"

cleanup() {
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    rm -rf "$RUN_DIR"
}
trap cleanup EXIT

export TMUX="$SOCKET"
export TMUX_SESSION_LAUNCHER_LOCK_ROOT="$RUN_DIR"
export TMUX_SESSION_HISTORY_DIR="$HISTORY_DIR"
export HOME="$RUN_DIR/home"
export SCRIPT_PATH="$SCRIPT_DIR/scripts/tmux-session-dock"

source "$SCRIPT_DIR/scripts/lib/sidebar_domain.sh"
source "$SCRIPT_DIR/scripts/lib/sidebar_port_tmux.sh"
source "$SCRIPT_DIR/scripts/lib/sidebar_subpane_hub.sh"

# 1. Start surviving session (session_survivor) and session to delete (session_victim)
tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" new-session -d -s session_survivor -n work 'sleep 300'
win_survivor="$(tmux -L "$SOCKET" display-message -p -t session_survivor '#{window_id}')"

tmux -L "$SOCKET" new-session -d -s session_victim -n work 'sleep 300'
win_victim="$(tmux -L "$SOCKET" display-message -p -t session_victim '#{window_id}')"

tmux -L "$SOCKET" set-option -g @dotfiles_sidebar_subpane_enabled 1
tmux -L "$SOCKET" set-option -g @session-dock-subpane-count 2

# Provision sidebars
sidebar_port_split_sidebar_pane "$win_survivor" 40
launcher_survivor="$(sidebar_window_pane "$win_survivor" || true)"

sidebar_port_split_sidebar_pane "$win_victim" 40
launcher_victim="$(sidebar_window_pane "$win_victim" || true)"

# 2. Attach subpanes to session_victim
ensure_sidebar_subpane_window "$win_victim" "$launcher_victim" true

sub_pane1_before="$(subpane_hub_registered_pane 1 || true)"
sub_pid1_before="$(tmux -L "$SOCKET" display-message -p -t "$sub_pane1_before" '#{pane_pid}' 2>/dev/null || true)"
[ -n "$sub_pane1_before" ] || { echo "FAIL: sub_pane1 not found"; exit 1; }

# Write unique marker into subpane 1
tmux -L "$SOCKET" send-keys -t "$sub_pane1_before" 'echo "PRESERVED_UNIQUE_SECRET_DATA_98765"' C-m
sleep 0.5

content_before="$(tmux -L "$SOCKET" capture-pane -p -t "$sub_pane1_before")"
if ! echo "$content_before" | grep -q "PRESERVED_UNIQUE_SECRET_DATA_98765"; then
    echo "FAIL: marker text not present in subpane before delete"
    exit 1
fi

# 3. Delete session_victim (which holds the subpanes)
bash "$SCRIPT_DIR/scripts/tmux-session-dock" --delete-session-after-archive session_victim false >/dev/null 2>&1 || true
sleep 0.5

# 4. Assertions on surviving session
sub_pane1_after="$(subpane_hub_registered_pane 1 2>/dev/null || true)"
[ -n "$sub_pane1_after" ] || { echo "FAIL: subpane 1 lost after session delete"; exit 1; }

sub_pid1_after="$(tmux -L "$SOCKET" display-message -p -t "$sub_pane1_after" '#{pane_pid}' 2>/dev/null || true)"

# 4a. Process PID must be identical (no respawn/recreate)
if [ "$sub_pid1_before" != "$sub_pid1_after" ]; then
    echo "FAIL: subpane process was KILLED and RECREATED! PID before='$sub_pid1_before', after='$sub_pid1_after'"
    exit 1
fi

# 4b. Content must be preserved
content_after="$(tmux -L "$SOCKET" capture-pane -p -t "$sub_pane1_after" 2>/dev/null || true)"
if ! echo "$content_after" | grep -q "PRESERVED_UNIQUE_SECRET_DATA_98765"; then
    echo "FAIL: subpane content was RESET after session delete!"
    exit 1
fi

# 4c. Lease holder must be the surviving window
lease_holder_after="$(subpane_hub_get_lease_holder)"
if [ "$lease_holder_after" != "$win_survivor" ]; then
    echo "FAIL: subpane lease was not migrated to surviving window! Expected '$win_survivor', got '$lease_holder_after'"
    exit 1
fi

echo "PASS: subpane content and process preserved across session deletion"
