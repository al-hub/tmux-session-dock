#!/usr/bin/env bash
# ==============================================================================
# tests/tmux-single-sidebar/test-subpane-bug-detection.sh
# Reproduces and detects the 3 reported subpane multi-slot bugs without fixing them.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_SOCKET="dock-test-bugs-$$"
BIN_SCRIPT="$REPO_ROOT/scripts/tmux-session-dock"

cleanup() {
    tmux -L "$TEST_SOCKET" kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=========================================================================="
echo "🧪 SUBPANE MULTI-SLOT BUG DETECTION SUITE"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# Test 1: --ensure-sidebar-window exit code
# ------------------------------------------------------------------------------
echo ""
echo "=== [Test 1] Detecting '--ensure-sidebar-window' Exit Code ==="
tmux -L "$TEST_SOCKET" -f /dev/null new-session -d -s sess1 -n main -x 120 -y 40
win1="$(tmux -L "$TEST_SOCKET" display-message -p '#{window_id}')"

set +e
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" bash "$BIN_SCRIPT" --ensure-sidebar-window "$win1"
test1_exit=$?
set -e

if [ "$test1_exit" -ne 0 ]; then
    echo "🚨 [DETECTED BUG 1]: '--ensure-sidebar-window $win1' returned exit code $test1_exit (Expected 0)!"
else
    echo "ℹ️ [Test 1 PASS/NOT REPRODUCED]: '--ensure-sidebar-window $win1' returned 0."
fi

# ------------------------------------------------------------------------------
# Test 2: 'p' swap preserves vertical slot order (Slot 1 above Slot 2)
# ------------------------------------------------------------------------------
echo ""
echo "=== [Test 2] Detecting Slot Order Inversion on 'p' (Swap Position) ==="
main_pane="$(tmux -L "$TEST_SOCKET" display-message -p '#{pane_id}')"
sidebar_pane="$(tmux -L "$TEST_SOCKET" split-window -h -b -t "$main_pane" -l 34 -P -F '#{pane_id}')"
tmux -L "$TEST_SOCKET" select-pane -t "$sidebar_pane" -T "dotfiles-session-sidebar"
tmux -L "$TEST_SOCKET" set-option -p -q -t "$sidebar_pane" @dotfiles_sidebar_pane 1

# Configure 2 slots
tmux -L "$TEST_SOCKET" set-option -gq "@session-dock-subpane-count" 2
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$sidebar_pane" bash "$BIN_SCRIPT" --toggle-subpane

s1_pane="$(tmux -L "$TEST_SOCKET" list-panes -F '#{pane_id}|#{@dotfiles_subpane_slot}' | awk -F '|' '$2 == "1" { print $1 }')"
s2_pane="$(tmux -L "$TEST_SOCKET" list-panes -F '#{pane_id}|#{@dotfiles_subpane_slot}' | awk -F '|' '$2 == "2" { print $1 }')"

s1_top_init="$(tmux -L "$TEST_SOCKET" display-message -p -t "$s1_pane" '#{pane_top}')"
s2_top_init="$(tmux -L "$TEST_SOCKET" display-message -p -t "$s2_pane" '#{pane_top}')"
echo "Initial Bottom Positions: Slot 1 top=$s1_top_init, Slot 2 top=$s2_top_init"

# Swap to Top ('p')
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$sidebar_pane" bash "$BIN_SCRIPT" --swap-subpane-position

s1_top_swapped="$(tmux -L "$TEST_SOCKET" display-message -p -t "$s1_pane" '#{pane_top}')"
s2_top_swapped="$(tmux -L "$TEST_SOCKET" display-message -p -t "$s2_pane" '#{pane_top}')"
echo "Swapped Top Positions:   Slot 1 top=$s1_top_swapped, Slot 2 top=$s2_top_swapped"

if [ "$s1_top_swapped" -gt "$s2_top_swapped" ]; then
    echo "🚨 [DETECTED BUG 2]: Slot order was INVERTED! Slot 2 (top=$s2_top_swapped) is above Slot 1 (top=$s1_top_swapped)!"
else
    echo "ℹ️ [Test 2 PASS]: Slot 1 (top=$s1_top_swapped) is correctly above Slot 2 (top=$s2_top_swapped)."
fi

# ------------------------------------------------------------------------------
# Test 3: Session migration keeps all N slots (Dual stack persistence)
# ------------------------------------------------------------------------------
echo ""
echo "=== [Test 3] Detecting Subpane Stack Loss on Session Switch ==="
# Create second session sess2
tmux -L "$TEST_SOCKET" new-session -d -s sess2 -n main -x 120 -y 40
win2="$(tmux -L "$TEST_SOCKET" display-message -p -t "sess2:main" '#{window_id}')"
sess2_main_pane="$(tmux -L "$TEST_SOCKET" display-message -p -t "sess2:main" '#{pane_id}')"
sess2_sidebar="$(tmux -L "$TEST_SOCKET" split-window -h -b -t "$sess2_main_pane" -l 34 -P -F '#{pane_id}')"
tmux -L "$TEST_SOCKET" select-pane -t "$sess2_sidebar" -T "dotfiles-session-sidebar"
tmux -L "$TEST_SOCKET" set-option -p -q -t "$sess2_sidebar" @dotfiles_sidebar_pane 1

# Trigger session migration of active sidebar and subpanes to sess2
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" bash -c "
    source '$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh'
    source '$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh'
    ensure_sidebar_subpane_window '$win2' '$sess2_sidebar'
"

sess2_slots="$(tmux -L "$TEST_SOCKET" list-panes -t "$win2" -F '#{@dotfiles_sidebar_subpane}' | grep -c '1' || true)"
echo "Subpane slot count in sess2: $sess2_slots (Expected 2)"

if [ "$sess2_slots" -lt 2 ]; then
    echo "🚨 [DETECTED BUG 3]: Subpane stack was DROPPED! Found only $sess2_slots subpane(s) in sess2 instead of 2!"
else
    echo "ℹ️ [Test 3 PASS]: All $sess2_slots subpanes migrated to sess2."
fi

echo ""
echo "=========================================================================="
echo "Detection run complete."
echo "=========================================================================="
