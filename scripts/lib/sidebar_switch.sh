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
        if [ -n "$target_win" ]; then
            # One hub builder moves the leased stack in slot order and declares
            # its geometry (the switch path used to carry its own join
            # arithmetic that joined every slot to the sidebar and reversed the
            # stack at position bottom).
            # Build BEFORE switching, in this process, exactly once. The
            # presenter running this code belongs to the window the client is
            # leaving and the active-window hooks recycle its pane right after
            # switch-client, so nothing multi-step may run here afterwards.
            # A window the client has never shown still has its detached size
            # and tmux would scale the stack when it first shows it: give the
            # target the client's current window size first (resize-window
            # marks the window manual; unset that so it keeps following the
            # client), then declare the geometry, then switch.
            if [ -n "$client_tty" ]; then
                local client_size
                client_size="$(sidebar_tmux_cmd list-clients -F '#{client_tty} #{window_width} #{window_height}' 2>/dev/null |
                    awk -v tty="$client_tty" '$1 == tty { print $2 " " $3; exit }')"
                if [[ $client_size =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
                    local target_size
                    target_size="$(sidebar_tmux_cmd display-message -p -t "$target_win" '#{window_width} #{window_height}' 2>/dev/null || true)"
                    if [ "$target_size" != "$client_size" ]; then
                        sidebar_tmux_cmd resize-window -t "$target_win" -x "${BASH_REMATCH[1]}" -y "${BASH_REMATCH[2]}" 2>/dev/null || true
                        sidebar_tmux_cmd set-option -wu -t "$target_win" window-size 2>/dev/null || true
                    fi
                fi
            fi
            if declare -f set_sidebar_layout_hook_guard >/dev/null 2>&1; then
                set_sidebar_layout_hook_guard 500
            fi
            if ! subpane_hub_atomic_migrate "$sidebar_pane" "$sub_height" >/dev/null 2>&1; then
                if declare -f trace_event >/dev/null 2>&1; then
                    trace_event "switch.subpane.migrate.failed window=$target_win sidebar=$sidebar_pane"
                fi
            fi
            if [ -n "$client_tty" ]; then
                sidebar_tmux_cmd switch-client -c "$client_tty" -t "$target_spec" \; select-pane -t "$sidebar_pane" 2>/dev/null || return 1
            else
                sidebar_tmux_cmd select-pane -t "$sidebar_pane" 2>/dev/null || true
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
