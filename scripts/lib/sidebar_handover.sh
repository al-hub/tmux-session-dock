#!/usr/bin/env bash
# Presenter handover policy. The caller supplies a settled local snapshot and
# applies the result through the transition coordinator.
set -euo pipefail

sidebar_handover_reset_result() {
    sidebar_handover_result="none"
    sidebar_handover_marker_action="preserve"
    sidebar_handover_render_intent="none"
}

# Decide the externally observable outcome of one Presenter Window handover.
# Arguments: target, target_exists, target_in_snapshot, transition_active,
# transition_committed, full_reconcile_required, view_mode.
sidebar_handover_decide() {
    local target="${1:-}" target_exists="${2:-false}" target_in_snapshot="${3:-false}"
    local transition_active="${4:-false}" transition_committed="${5:-false}"
    local full_reconcile_required="${6:-false}" view_mode="${7:-sessions}"

    sidebar_handover_reset_result
    [ -n "$target" ] || return 0

    if [ "$target_exists" != true ]; then
        sidebar_handover_result="discarded"
        sidebar_handover_marker_action="discard"
        sidebar_handover_render_intent="full"
        return 0
    fi

    if [ "$target_in_snapshot" != true ]; then
        sidebar_handover_result="retry"
        return 0
    fi

    sidebar_handover_result="settled"
    sidebar_handover_marker_action="consume"
    if [ "$view_mode" != sessions ] || [ "$full_reconcile_required" = true ]; then
        sidebar_handover_render_intent="full"
    else
        sidebar_handover_render_intent="delta"
    fi
    if [ "$transition_active" = true ] || [ "$transition_committed" = true ]; then
        sidebar_handover_render_intent="deferred"
    fi
}
