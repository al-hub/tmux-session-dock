#!/usr/bin/env bash
# ==============================================================================
# tests/tmux-single-sidebar/test-subpane-height-preservation.sh
# Tests whether individual custom heights of subpanes are preserved across:
# 1) Top/Bottom position swap ('p')
# 2) Session migration (switch-client / window change)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_SOCKET="dock-test-height-$$"
BIN_SCRIPT="$REPO_ROOT/scripts/tmux-session-dock"

cleanup() {
    tmux -L "$TEST_SOCKET" kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=========================================================================="
echo "🧪 SUBPANE INDIVIDUAL HEIGHT PRESERVATION TEST SUITE"
echo "=========================================================================="

# 1. Initialize session with 2 subpane slots
tmux -L "$TEST_SOCKET" -f /dev/null new-session -d -s sess1 -n main -x 120 -y 50
win1="$(tmux -L "$TEST_SOCKET" display-message -p '#{window_id}')"
main_pane="$(tmux -L "$TEST_SOCKET" display-message -p '#{pane_id}')"
sidebar_pane="$(tmux -L "$TEST_SOCKET" split-window -h -b -t "$main_pane" -l 34 -P -F '#{pane_id}')"
tmux -L "$TEST_SOCKET" select-pane -t "$sidebar_pane" -T "dotfiles-session-sidebar"
tmux -L "$TEST_SOCKET" set-option -p -q -t "$sidebar_pane" @dotfiles_sidebar_pane 1

# Configure 2 slots
tmux -L "$TEST_SOCKET" set-option -gq "@session-dock-subpane-count" 2
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$sidebar_pane" bash "$BIN_SCRIPT" --toggle-subpane

s1_pane="$(tmux -L "$TEST_SOCKET" list-panes -F '#{pane_id}|#{@dotfiles_subpane_slot}' | awk -F '|' '$2 == "1" { print $1 }')"
s2_pane="$(tmux -L "$TEST_SOCKET" list-panes -F '#{pane_id}|#{@dotfiles_subpane_slot}' | awk -F '|' '$2 == "2" { print $1 }')"

# Custom Slot 1 = 9 lines, Custom Slot 2 = 16 lines
CUSTOM_H1=9
CUSTOM_H2=16
tmux -L "$TEST_SOCKET" resize-pane -t "$sidebar_pane" -y 23
tmux -L "$TEST_SOCKET" resize-pane -t "$s1_pane" -y "$CUSTOM_H1"

h1_before="$(tmux -L "$TEST_SOCKET" display-message -p -t "$s1_pane" '#{pane_height}')"
h2_before="$(tmux -L "$TEST_SOCKET" display-message -p -t "$s2_pane" '#{pane_height}')"
echo ""
echo "=== [Setup] User resized subpanes manually ==="
echo "Slot 1 pane=$s1_pane height=$h1_before (Expected $CUSTOM_H1)"
echo "Slot 2 pane=$s2_pane height=$h2_before (Expected $CUSTOM_H2)"

# ------------------------------------------------------------------------------
# Test 1: Height preservation across Top/Bottom swap ('p')
# ------------------------------------------------------------------------------
echo ""
echo "=== [Test 1] Checking Heights across 'p' (Swap Position) ==="
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$sidebar_pane" bash "$BIN_SCRIPT" --swap-subpane-position

h1_after_swap="$(tmux -L "$TEST_SOCKET" display-message -p -t "$s1_pane" '#{pane_height}')"
h2_after_swap="$(tmux -L "$TEST_SOCKET" display-message -p -t "$s2_pane" '#{pane_height}')"
echo "After Swap: Slot 1 height=$h1_after_swap, Slot 2 height=$h2_after_swap"

if [ "$h1_after_swap" -ne "$CUSTOM_H1" ] || [ "$h2_after_swap" -ne "$CUSTOM_H2" ]; then
    echo "🚨 [DETECTED BUG 1]: Individual heights NOT preserved on swap!"
    echo "   Expected Slot 1 = $CUSTOM_H1, got $h1_after_swap"
    echo "   Expected Slot 2 = $CUSTOM_H2, got $h2_after_swap"
else
    echo "ℹ️ [Test 1 PASS]: Heights preserved on swap."
fi

# ------------------------------------------------------------------------------
# Test 2: Height preservation across session migration
# ------------------------------------------------------------------------------
echo ""
echo "=== [Test 2] Checking Heights across Session Migration ==="
# Reset back to custom heights if needed
tmux -L "$TEST_SOCKET" resize-pane -t "$sidebar_pane" -y 23
tmux -L "$TEST_SOCKET" resize-pane -t "$s1_pane" -y "$CUSTOM_H1"

# Create sess2 and trigger migration
tmux -L "$TEST_SOCKET" new-session -d -s sess2 -n main -x 120 -y 50
win2="$(tmux -L "$TEST_SOCKET" display-message -p -t "sess2:main" '#{window_id}')"
sess2_main_pane="$(tmux -L "$TEST_SOCKET" display-message -p -t "sess2:main" '#{pane_id}')"
sess2_sidebar="$(tmux -L "$TEST_SOCKET" split-window -h -b -t "$sess2_main_pane" -l 34 -P -F '#{pane_id}')"
tmux -L "$TEST_SOCKET" select-pane -t "$sess2_sidebar" -T "dotfiles-session-sidebar"
tmux -L "$TEST_SOCKET" set-option -p -q -t "$sess2_sidebar" @dotfiles_sidebar_pane 1

TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" bash -c "
    source '$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh'
    source '$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh'
    ensure_sidebar_subpane_window '$win2' '$sess2_sidebar'
"

s1_mig_pane="$(tmux -L "$TEST_SOCKET" list-panes -t "$win2" -F '#{pane_id}|#{@dotfiles_subpane_slot}' | awk -F '|' '$2 == "1" { print $1 }')"
s2_mig_pane="$(tmux -L "$TEST_SOCKET" list-panes -t "$win2" -F '#{pane_id}|#{@dotfiles_subpane_slot}' | awk -F '|' '$2 == "2" { print $1 }')"

h1_after_mig="$(tmux -L "$TEST_SOCKET" display-message -p -t "$s1_mig_pane" '#{pane_height}')"
h2_after_mig="$(tmux -L "$TEST_SOCKET" display-message -p -t "$s2_mig_pane" '#{pane_height}')"
echo "After Migration: Slot 1 ($s1_mig_pane) height=$h1_after_mig, Slot 2 ($s2_mig_pane) height=$h2_after_mig"

if [ "$h1_after_mig" -ne "$CUSTOM_H1" ] || [ "$h2_after_mig" -ne "$CUSTOM_H2" ]; then
    echo "🚨 [DETECTED BUG 2]: Individual heights NOT preserved on session migration!"
    echo "   Expected Slot 1 = $CUSTOM_H1, got $h1_after_mig"
    echo "   Expected Slot 2 = $CUSTOM_H2, got $h2_after_mig"
else
    echo "ℹ️ [Test 2 PASS]: Heights preserved on session migration."
fi

# ------------------------------------------------------------------------------
# Test 3: Live Mouse Resize Hook Simulation (remember_sidebar_subpane_height)
# ------------------------------------------------------------------------------
echo ""
echo "=== [Test 3] Checking Live Mouse Resize Hook Simulation ==="
NEW_H1=12
NEW_H2=18
# Simulate user dragging mouse borders in sess2 where subpanes are attached
tmux -L "$TEST_SOCKET" resize-pane -t "$sess2_sidebar" -y 18
tmux -L "$TEST_SOCKET" resize-pane -t "$s1_mig_pane" -y "$NEW_H1"

# Trigger tmux hook that runs on resize
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" bash -c "
    source '$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh'
    source '$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh'
    remember_sidebar_subpane_height_for_window '$win2'
"

saved_slot1="$(tmux -L "$TEST_SOCKET" show-option -gqv "@dotfiles_subpane_slot_1_height")"
saved_slot2="$(tmux -L "$TEST_SOCKET" show-option -gqv "@dotfiles_subpane_slot_2_height")"
saved_total="$(tmux -L "$TEST_SOCKET" show-option -gqv "@dotfiles_sidebar_subpane_height")"

echo "After Mouse Resize Hook:"
echo "  Slot 1 Saved Height = $saved_slot1 (Expected $NEW_H1)"
echo "  Slot 2 Saved Height = $saved_slot2 (Expected $NEW_H2)"
echo "  Total Saved Height  = $saved_total (Expected $((NEW_H1 + NEW_H2)))"

if [ "$saved_slot1" -ne "$NEW_H1" ] || [ "$saved_slot2" -ne "$NEW_H2" ] || [ "$saved_total" -ne "$((NEW_H1 + NEW_H2))" ]; then
    echo "🚨 [DETECTED BUG 3]: remember_sidebar_subpane_height_for_window failed to snapshot all slots!"
    exit 1
else
    echo "ℹ️ [Test 3 PASS]: Live mouse resize hook successfully snapshot all slot heights."
fi

# Further verify that swap and migration now respect the new heights (12, 18)
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$sess2_sidebar" bash "$BIN_SCRIPT" --swap-subpane-position
h1_test3_swap="$(tmux -L "$TEST_SOCKET" display-message -p -t "$s1_mig_pane" '#{pane_height}')"
h2_test3_swap="$(tmux -L "$TEST_SOCKET" display-message -p -t "$s2_mig_pane" '#{pane_height}')"
echo "After Swap with New Heights: Slot 1=$h1_test3_swap, Slot 2=$h2_test3_swap"

if [ "$h1_test3_swap" -ne "$NEW_H1" ] || [ "$h2_test3_swap" -ne "$NEW_H2" ]; then
    echo "🚨 [DETECTED BUG 3.1]: Swap failed to preserve dynamically resized heights!"
    exit 1
else
    echo "ℹ️ [Test 3.1 PASS]: Dynamically resized heights preserved on swap."
fi

echo ""
echo "=========================================================================="
echo "Height preservation test complete."
echo "=========================================================================="
