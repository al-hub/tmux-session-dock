#!/usr/bin/env bash
# Hot/Cold Path Session Switch Transaction Service Module
set -euo pipefail

sidebar_switch_execute_hot() {
    local client_tty="$1" target_session="$2" target_window="${3:-}" sidebar_pane="${4:-}" width="${5:-}" sub_pane="${6:-}" sub_height="${7:-12}"
    if [ -z "$target_session" ]; then
        return 1
    fi
    local target_win="$target_window"
    if [ -z "$target_win" ] && [ -n "$sidebar_pane" ]; then
        target_win="$(sidebar_tmux_cmd display-message -p -t "$sidebar_pane" '#{window_id}' 2>/dev/null || true)"
    fi
    if [ -z "$target_win" ] && [ -n "$target_session" ]; then
        target_win="$(sidebar_tmux_cmd display-message -p -t "=$target_session:" '#{window_id}' 2>/dev/null || true)"
    fi

    if [ -n "$target_win" ]; then
        sidebar_port_publish_marker_handover "$target_win" "$target_session"
    fi
    if [ -n "$sidebar_pane" ]; then
        sidebar_port_notify_presenter_wake "$sidebar_pane"
    elif [ -n "$target_win" ]; then
        sidebar_port_notify_presenter_wake "$target_win"
    fi

    local target_spec="=$target_session:"
    if [ -n "$sub_pane" ] && [ -n "$sidebar_pane" ] && declare -f subpane_hub_atomic_migrate >/dev/null 2>&1; then
        local sub_win
        sub_win="$(sidebar_tmux_cmd display-message -p -t "$sub_pane" '#{window_id}' 2>/dev/null || true)"
        if [ -n "$sub_win" ] && [ "$sub_win" != "$target_win" ]; then
            # Land the client on the target first - sidebar and work panes
            # already exist there - then let the one hub builder move the whole
            # leased stack in slot order. The builder owns the lease, the
            # per-slot heights and the geometry. (The switch path used to carry
            # its own join arithmetic that joined every slot to the sidebar and
            # reversed the stack at position bottom.)
            if [ -n "$client_tty" ]; then
                sidebar_tmux_cmd switch-client -c "$client_tty" -t "$target_spec" \; select-pane -t "$sidebar_pane" 2>/dev/null || return 1
            else
                sidebar_tmux_cmd select-pane -t "$sidebar_pane" 2>/dev/null || true
            fi
            if declare -f set_sidebar_layout_hook_guard >/dev/null 2>&1; then
                set_sidebar_layout_hook_guard 500
            fi
            # The client is already switched: a builder failure is traced, never
            # reported to the caller as a refused switch.
            if ! subpane_hub_atomic_migrate "$sidebar_pane" "$sub_height" >/dev/null 2>&1; then
                if declare -f trace_event >/dev/null 2>&1; then
                    trace_event "switch.subpane.migrate.failed window=$target_win sidebar=$sidebar_pane"
                fi
            fi
            sidebar_tmux_cmd select-pane -t "$sidebar_pane" 2>/dev/null || true
            return 0
        fi
    fi
    if [ -n "$sidebar_pane" ]; then
        if [ -n "$client_tty" ]; then
            sidebar_tmux_cmd switch-client -c "$client_tty" -t "$target_spec" \; select-pane -t "$sidebar_pane" 2>/dev/null
        else
            sidebar_tmux_cmd select-pane -t "$sidebar_pane" 2>/dev/null || true
        fi
    else
        sidebar_port_switch_client "$client_tty" "$target_session"
    fi
}

sidebar_switch_reconcile_cold() {
    local target_session="$1" target_window="$2"
    # Cold repair path helper for missing or degraded sidebar pane
    return 0
}
