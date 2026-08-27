#!/usr/bin/env bash
# Verify that a settled handover leaves the target Presenter Window drawable.

set -euo pipefail

SCENARIO_NAME="settled-presenter-content-regression"
TMUX_SESSION_LAUNCHER_TRACE=1
TMUX_SESSION_LAUNCHER_DEBUG=1
TMUX_INTERACTIVE_CREATE_PEER=false

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TEST_DIR/test-interactive-common.sh"

selected_session_name() {
    sidebar_selected_name | tr -d '\r' | awk '{ print $1 }'
}

switch_to_next_session() {
    local expected_session="$1" source_session target_window target_pane screen

    source_session="$(client_session)"
    focus_sidebar
    send_keys $'\033[B'
    wait_until "selection moved to $expected_session" "[ \"\$(selected_session_name)\" = '$expected_session' ]"
    [ "$(selected_session_name)" = "$expected_session" ] || {
        echo "FAIL: expected next selection $expected_session, got $(selected_session_name)" >&2
        return 1
    }

    target_window="$(tmuxc display-message -p -t "=$expected_session:" '#{window_id}')"
    send_keys $'\r'
    for _ in $(seq 1 3); do
        sleep 0.1
        grep -Eq "switch\\.begin .*target=$expected_session([[:space:]]|$)" "$TRACE_FILE" 2>/dev/null && break
        send_keys $'\r'
    done

    # The acknowledgement is transient and may be consumed before an external
    # observer samples it. Record it when visible, but use durable completion
    # and rendered content as the regression oracle.
    ack_observed=false
    for _ in $(seq 1 150); do
        if [ "$(tmuxc show-options -wqv -t "$target_window" @dotfiles_sidebar_selection_sync_ack 2>/dev/null || true)" = "$expected_session" ]; then
            ack_observed=true
            break
        fi
        sleep 0.002
    done
    test_log "selection-sync ack target=$expected_session observed=$ack_observed"
    wait_until "switch to $expected_session settled" "[ \"\$(client_session)\" = '$expected_session' ] && [ \"\$(tmuxc show-options -wqv -t '$target_window' @dotfiles_sidebar_ready 2>/dev/null || true)\" = 1 ] && tmuxc show-options -gqv @dotfiles_sidebar_transition | grep -Fq 'target=$expected_session;result=success'"

    target_pane="$(window_sidebar_pane_id "$target_window")"
    [ -n "$target_pane" ] || {
        echo "FAIL: target Presenter Window missing sidebar for $expected_session" >&2
        return 1
    }
    screen="$(tmuxc capture-pane -p -t "$target_pane")"
    printf '%s\n' "--- Settled Presenter: $expected_session ($target_pane) ---"
    printf '%s\n' "$screen"

    printf '%s' "$screen" | grep -Fq sessions || {
        echo "FAIL: settled Presenter for $expected_session is missing the session list" >&2
        return 1
    }
    printf '%s' "$screen" | grep -Fq "$expected_session" || {
        echo "FAIL: settled Presenter for $expected_session is missing its target row" >&2
        return 1
    }
}

echo "=== [1/3] Setting up an attached Presenter Window ==="
setup_interactive_test
wait_until "anchor sidebar ready" sidebar_ready

anchor_window="$(tmuxc display-message -p -t '=interactive-anchor:' '#{window_id}')"
anchor_pane="$(window_sidebar_pane_id "$anchor_window")"
sidebar_width="$(tmuxc display-message -p -t "$anchor_pane" '#{pane_width}')"

echo "=== [2/3] Creating warm multi-session topology with a Subpane ==="
for session_name in sess-alpha sess-beta sess-gamma sess-delta sess-epsilon; do
    tmuxc new-session -d -s "$session_name" -x 160 -y 50 -c "$REPO_ROOT" 'sleep 300'
    session_window="$(tmuxc display-message -p -t "=$session_name:" '#{window_id}')"
    tmuxc set-option -wq -t "$session_window" @dotfiles_sidebar_managed 1
    tmuxc run-shell "$LAUNCHER --ensure-sidebar-window '$session_window' $sidebar_width"
    wait_until "$session_name Presenter Window ready" "tmuxc show-options -wqv -t '$session_window' @dotfiles_sidebar_ready | grep -Fq 1"
    wait_until "$session_name Presenter pane alive" "pane=\$(window_sidebar_pane_id '$session_window'); [ -n \"\$pane\" ] && [ \"\$(tmuxc display-message -p -t \"\$pane\" '#{pane_dead}' 2>/dev/null || true)\" = 0 ]"
done

alpha_window="$(tmuxc display-message -p -t '=sess-alpha:' '#{window_id}')"
tmuxc run-shell "$LAUNCHER --toggle-subpane '$alpha_window'"

echo "=== [3/3] Verifying settled target Presenter content ==="
switch_to_next_session sess-alpha
switch_to_next_session sess-beta
switch_to_next_session sess-delta

echo "PASS: settled Presenter Windows retained their session lists and target rows"
