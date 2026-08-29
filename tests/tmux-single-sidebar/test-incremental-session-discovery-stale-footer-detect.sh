#!/usr/bin/env bash
# ==============================================================================
# tests/tmux-single-sidebar/test-incremental-session-discovery-stale-footer-detect.sh
#
# Verify that a pre-warmed Presenter discovers a session created after it.
# Footer cleanup has a separate settled-Presenter oracle.
# ==============================================================================

set -euo pipefail

SCENARIO_NAME="incremental-discovery-stale-footer"
TMUX_INTERACTIVE_CREATE_PEER=false

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TEST_DIR/../lib/interactive_common.sh"

echo "=== [1/3] Setting up interactive client on interactive-anchor ==="
setup_interactive_test
wait_until "anchor sidebar ready" sidebar_ready

anchor_win="$(tmuxc display-message -p -t '=interactive-anchor:' '#{window_id}')"
anchor_sb="$(tmuxc list-panes -t "$anchor_win" -F '#{pane_id}|#{pane_title}' | awk -F '|' '!done && $2 == "dotfiles-session-sidebar" { print $1; done = 1 }')"
initial_width="$(tmuxc display-message -p -t "$anchor_sb" '#{pane_width}')"

echo "=== [2/3] Creating sess-beta with a pre-warmed Presenter ==="
tmuxc new-session -d -s sess-beta -x 160 -y 40 -c "$REPO_ROOT" 'sleep 300'
beta_win="$(tmuxc display-message -p -t '=sess-beta:' '#{window_id}')"
tmuxc set-option -wq -t "$beta_win" @dotfiles_sidebar_managed 1
tmuxc run-shell "$LAUNCHER --ensure-sidebar-window '$beta_win' $initial_width"

wait_until "sess-beta visible on anchor" "[ -n \"\$(sidebar_row_for 'sess-beta')\" ]"

echo "=== [3/3] Creating sess-gamma after sess-beta is warm ==="
tmuxc new-session -d -s sess-gamma -x 160 -y 40 -c "$REPO_ROOT" 'sleep 300'
gamma_win="$(tmuxc display-message -p -t '=sess-gamma:' '#{window_id}')"
tmuxc set-option -wq -t "$gamma_win" @dotfiles_sidebar_managed 1
# Do not run ensure-sidebar-window manually on gamma so it mirrors real user/tmux hook lifecycle
wait_until "sess-gamma visible on anchor" "[ -n \"\$(sidebar_row_for 'sess-gamma')\" ]"
target="$(switch_to_next_sidebar_selection)"
[ "$target" = sess-beta ] || {
    echo "HARNESS_ERROR_INPUT: expected next selection sess-beta, got $target" >&2
    exit 2
}
wait_for_settled_presenter_screen "$beta_win" sess-beta
beta_screen="$PRESENTER_SCREEN_RESULT"
gamma_rows="$(presenter_screen_session_rows "$beta_screen" sess-gamma)"
[ "$gamma_rows" -eq 1 ] || {
    echo "PRODUCT_FAIL_INCREMENTAL_DISCOVERY: sess-gamma visible_rows=$gamma_rows" >&2
    printf '%s\n' "$beta_screen" >&2
    exit 1
}

echo "PASS: pre-warmed sess-beta Presenter discovered sess-gamma exactly once"
