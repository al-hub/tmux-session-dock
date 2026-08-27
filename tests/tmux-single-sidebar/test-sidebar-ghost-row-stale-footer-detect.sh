#!/usr/bin/env bash
# Verify that consecutive session switches leave a settled Presenter without
# duplicate rows or a transient switch footer. The oracle is the visible pane,
# sampled twice after the attached client reaches its target session.

set -euo pipefail

SCENARIO_NAME="ghost-row-stale-footer-detect"
TMUX_INTERACTIVE_CREATE_PEER=false

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TEST_DIR/test-interactive-common.sh"

SESSIONS=(interactive-anchor sess-alpha sess-beta sess-gamma sess-delta sess-epsilon)

assert_settled_presenter() {
    local target="$1" target_window screen session_name rows
    target_window="$(tmuxc display-message -p -t "=$target:" '#{window_id}')"
    wait_for_settled_presenter_screen "$target_window" "$target"
    screen="$PRESENTER_SCREEN_RESULT"
    printf '%s\n' "$screen" > "$RUN_DIR/settled-$target-$step.screen"

    for session_name in "${SESSIONS[@]}"; do
        rows="$(presenter_screen_session_rows "$screen" "$session_name")"
        if [ "$rows" -ne 1 ]; then
            echo "PRODUCT_FAIL_PRESENTER: target=$target session=$session_name visible_rows=$rows" >&2
            return 1
        fi
    done
    if printf '%s\n' "$screen" | grep -Fq 'switching to'; then
        echo "PRODUCT_FAIL_STALE_FOOTER: target=$target" >&2
        return 1
    fi
}

echo "=== [1/3] Setting up attached Presenter Window ==="
setup_interactive_test
wait_until "anchor sidebar ready" sidebar_ready

anchor_window="$(tmuxc display-message -p -t '=interactive-anchor:' '#{window_id}')"
anchor_pane="$(window_sidebar_pane_id "$anchor_window")"
sidebar_width="$(tmuxc display-message -p -t "$anchor_pane" '#{pane_width}')"

echo "=== [2/3] Creating warm sessions with distinct geometry ==="
for session_name in sess-alpha sess-beta sess-gamma sess-delta sess-epsilon; do
    tmuxc new-session -d -s "$session_name" -x 160 -y 50 -c "$REPO_ROOT" 'sleep 300'
    session_window="$(tmuxc display-message -p -t "=$session_name:" '#{window_id}')"
    tmuxc set-option -wq -t "$session_window" @dotfiles_sidebar_managed 1
    tmuxc run-shell "$LAUNCHER --ensure-sidebar-window '$session_window' $sidebar_width"
    wait_until "$session_name Presenter ready" "tmuxc show-options -wqv -t '$session_window' @dotfiles_sidebar_ready | grep -Fq 1"
done
alpha_window="$(tmuxc display-message -p -t '=sess-alpha:' '#{window_id}')"
tmuxc run-shell "$LAUNCHER --toggle-subpane '$alpha_window'"

echo "=== [3/3] Checking 10 settled Presenter handovers ==="
step=0
for _ in $(seq 1 10); do
    step=$((step + 1))
    target="$(switch_to_next_sidebar_selection)"
    assert_settled_presenter "$target"
    echo "PASS: step=$step target=$target Presenter settled without stale rows or footer"
done

echo "PASS: 10 consecutive session handovers retained stable Presenter content"
