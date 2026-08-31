#!/usr/bin/env bash
# Regression contract test:
# Creating a new session in the background (via 'c' key in dock) must NOT steal
# the subpane lease from the currently active session/window.
set -euo pipefail

TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"
SOCKET="test-subpane-create-preserve-$$"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; }
trap cleanup EXIT

# 1. Start tmux server with session_a
tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" new-session -d -s session_a -n work 'sleep 60'
win_a="$(tmux -L "$SOCKET" display-message -p -t session_a '#{window_id}')"

export TMUX="$SOCKET"
export TMUX_SESSION_LAUNCHER_LOCK_ROOT="/tmp"
export SCRIPT_PATH="$SCRIPT_DIR/scripts/tmux-session-dock"
source "$SCRIPT_DIR/scripts/lib/sidebar_domain.sh"
source "$SCRIPT_DIR/scripts/lib/sidebar_port_tmux.sh"
source "$SCRIPT_DIR/scripts/lib/sidebar_subpane_hub.sh"

# Enable subpane globally (2 slots)
tmux -L "$SOCKET" set-option -g @dotfiles_sidebar_subpane_enabled 1
tmux -L "$SOCKET" set-option -g @session-dock-subpane-count 2

# Provision sidebar and subpane on session_a
sidebar_port_split_sidebar_pane "$win_a" 40
launcher_a="$(sidebar_window_pane "$win_a" || true)"
[ -n "$launcher_a" ] || { echo "FAIL: launcher_a not created"; exit 1; }

ensure_sidebar_subpane_window "$win_a" "$launcher_a"

# Verify subpane is leased to win_a
lease_holder="$(subpane_hub_get_lease_holder)"
[ "$lease_holder" = "$win_a" ] || { echo "FAIL: expected win_a ($win_a) to hold subpane lease, got '$lease_holder'"; exit 1; }

sub_count_a="$(tmux -L "$SOCKET" list-panes -t "$win_a" -F '#{@dotfiles_sidebar_subpane}' | grep -c '^1$' || true)"
[ "$sub_count_a" -eq 2 ] || { echo "FAIL: expected 2 subpanes in win_a, got $sub_count_a"; exit 1; }

# 2. Simulate creating a new session in background (what 'c' / tui_new_session does)
tmux -L "$SOCKET" new-session -d -s session_b -c "$HOME"
win_b="$(tmux -L "$SOCKET" display-message -p -t session_b '#{window_id}')"

# Run ensure-sidebar-session on the new background session
bash "$SCRIPT_DIR/scripts/tmux-session-dock" --ensure-sidebar-session session_b >/dev/null 2>&1 || true

# 3. Assert that win_a STILL holds the subpane lease and subpanes are not stolen
lease_holder_after="$(subpane_hub_get_lease_holder)"
if [ "$lease_holder_after" != "$win_a" ]; then
    echo "FAIL: subpane lease was stolen by background session! Expected '$win_a', but got '$lease_holder_after'"
    exit 1
fi

sub_count_a_after="$(tmux -L "$SOCKET" list-panes -t "$win_a" -F '#{@dotfiles_sidebar_subpane}' | grep -c '^1$' || true)"
if [ "$sub_count_a_after" -ne 2 ]; then
    echo "FAIL: subpanes vanished from win_a after creating session_b! Expected 2 subpanes, got $sub_count_a_after"
    exit 1
fi

echo "PASS: subpane lease preserved on active window during background session creation"
