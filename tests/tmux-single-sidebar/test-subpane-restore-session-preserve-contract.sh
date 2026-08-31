#!/usr/bin/env bash
# Regression contract test:
# When an archived session is opened/restored ('o' -> Enter in sidebar dock),
# the subpane lease MUST be migrated to the restored active session/window.
set -euo pipefail

TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"
SOCKET="test-subpane-restore-preserve-$$"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-restore-subpane.XXXXXX")"
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

# 1. Create a session to be archived (session_target)
tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" new-session -d -s session_target -n work 'sleep 60'
win_target_orig="$(tmux -L "$SOCKET" display-message -p -t session_target '#{window_id}')"
sidebar_port_split_sidebar_pane "$win_target_orig" 40

# Archive session_target and kill it
bash "$SCRIPT_DIR/scripts/tmux-session-dock" --archive-session session_target false >/dev/null 2>&1
tmux -L "$SOCKET" kill-session -t "=session_target:" 2>/dev/null || true

# 2. Start current active session (session_active) and enable subpanes
tmux -L "$SOCKET" new-session -d -s session_active -n work 'sleep 60'
win_active="$(tmux -L "$SOCKET" display-message -p -t session_active '#{window_id}')"

tmux -L "$SOCKET" set-option -g @dotfiles_sidebar_subpane_enabled 1
tmux -L "$SOCKET" set-option -g @session-dock-subpane-count 2

sidebar_port_split_sidebar_pane "$win_active" 40
launcher_active="$(sidebar_window_pane "$win_active" || true)"
ensure_sidebar_subpane_window "$win_active" "$launcher_active"

# Verify subpane is leased to win_active
lease_holder="$(subpane_hub_get_lease_holder)"
[ "$lease_holder" = "$win_active" ] || { echo "FAIL: expected win_active to hold subpane lease"; exit 1; }

# 3. Restore session_target from archive (what 'o' -> Enter does)
target_tsv="$HISTORY_DIR/session_target.tsv"
[ -f "$target_tsv" ] || { echo "FAIL: archive file missing at $target_tsv"; exit 1; }

# Trigger restore action (simulating user opening archived session from sidebar)
bash "$SCRIPT_DIR/scripts/tmux-session-dock" --restore-archive "$target_tsv" "op-restore-1" false >/dev/null 2>&1 || true

# 4. Assertions on restored session
win_target_restored="$(tmux -L "$SOCKET" display-message -p -t session_target '#{window_id}' 2>/dev/null || true)"
[ -n "$win_target_restored" ] || { echo "FAIL: session_target was not restored"; exit 1; }

lease_holder_after="$(subpane_hub_get_lease_holder)"
if [ "$lease_holder_after" != "$win_target_restored" ]; then
    echo "FAIL: subpane lease was not migrated to restored session! Expected '$win_target_restored', got '$lease_holder_after'"
    exit 1
fi

sub_count_target="$(tmux -L "$SOCKET" list-panes -t "$win_target_restored" -F '#{@dotfiles_sidebar_subpane}' | grep -c '^1$' || true)"
if [ "$sub_count_target" -ne 2 ]; then
    echo "FAIL: subpanes missing in restored session! Expected 2 subpanes, got $sub_count_target"
    exit 1
fi

echo "PASS: subpane lease correctly migrated to restored session"
