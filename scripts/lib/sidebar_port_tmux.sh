#!/usr/bin/env bash
# Typed Tmux Port & Adapter Isolation Module
set -euo pipefail

# Sidebar pane identity.  Defined here (the first tmux-facing module) so the
# port functions below and the lib-only test harnesses share one definition.
SIDEBAR_TITLE="dotfiles-session-sidebar"
SIDEBAR_WINDOW_PANE_OPTION="@dotfiles_sidebar_pane_id"
SIDEBAR_WINDOW_READY_OPTION="@dotfiles_sidebar_ready"

# The core entrypoint defines the real tracer; lib-only harnesses get a no-op.
declare -f trace_event >/dev/null 2>&1 || eval 'trace_event() { :; }'

if ! declare -f sidebar_tmux_cmd >/dev/null 2>&1; then
    sidebar_tmux_cmd() {
        if [ "${TMUX_SESSION_LAUNCHER_TRACE:-0}" = "1" ] && declare -f trace_event >/dev/null 2>&1; then
            case "${1:-}" in
                set-option|set-window-option|set|setw|set-environment|setenv|select-pane|select-window|select-layout|resize-pane|resize-window|rename-window|rename-session|set-hook|refresh-client|switch-client|join-pane|break-pane|swap-pane|kill-pane|split-window|respawn-pane|send-keys)
                    local tmux_write_caller="${FUNCNAME[1]:-main}"
                    [ "$tmux_write_caller" = tmux ] && tmux_write_caller="${FUNCNAME[2]:-main}"
                    trace_event "tmux.write caller=$tmux_write_caller args=$*" ;;
            esac
        fi
        if [ -n "${TMUX_SESSION_LAUNCHER_SOCKET:-}" ]; then
            # A socket *path* (hooks and run-shell inherit TMUX=/path,pid,idx
            # style values) needs -S; a bare name is a -L socket name.
            case "$TMUX_SESSION_LAUNCHER_SOCKET" in
                */*) command tmux -S "$TMUX_SESSION_LAUNCHER_SOCKET" "$@" ;;
                *) command tmux -L "$TMUX_SESSION_LAUNCHER_SOCKET" "$@" ;;
            esac
            return $?
        fi
        local tmux_socket="${TMUX:-}"
        tmux_socket="${tmux_socket%%,*}"
        if [ -n "$tmux_socket" ] && [ -S "$tmux_socket" ]; then
            command tmux -S "$tmux_socket" "$@"
        elif [ -n "$tmux_socket" ] && [ -S "/tmp/tmux-$(id -u 2>/dev/null || echo 1000)/$tmux_socket" ]; then
            command tmux -S "/tmp/tmux-$(id -u 2>/dev/null || echo 1000)/$tmux_socket" "$@"
        elif [ -n "$tmux_socket" ] && [[ "$tmux_socket" != *"/"* ]]; then
            command tmux -L "$tmux_socket" "$@"
        else
            command tmux "$@"
        fi
    }
fi

# What is true of ONE named client?  `display-message -c` cannot answer it and
# never could: tmux 3.2a rejects `-p -c` outright (usage, rc=1), and 3.4 accepts
# it but uses -c only to choose where a message is shown - the format is
# resolved against the most recently used session, so a client that has just
# switched still reports the session it left, and two clients on two sessions
# both report the same one.  list-clients formats once per client on every
# version, so ask it and pick our own row.  Returns 1 when that client is gone,
# which is a different answer from "the session is empty" and callers rely on
# it to fall back.
sidebar_client_field() {
    local client_tty="${1:-}" fmt="${2:-}" out
    [ -n "$client_tty" ] && [ -n "$fmt" ] || return 1
    out="$(sidebar_tmux_cmd list-clients -F "#{client_tty}|$fmt" 2>/dev/null |
        awk -F '|' -v tty="$client_tty" '!done && $1 == tty { sub(/^[^|]*\|/, ""); print; done = 1 }')"
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

sidebar_port_get_current_session() {
    sidebar_tmux_cmd display-message -p '#S' 2>/dev/null || echo ""
}

sidebar_port_get_current_path() {
    sidebar_tmux_cmd display-message -p '#{pane_current_path}' 2>/dev/null || echo ""
}

sidebar_port_switch_client() {
    local client_tty="${1:-}" target_session="${2:-}"
    [ -n "$target_session" ] || return 1
    if [ -n "$client_tty" ]; then
        sidebar_tmux_cmd switch-client -c "$client_tty" -t "=$target_session:" 2>/dev/null || true
    else
        sidebar_tmux_cmd switch-client -t "=$target_session:" 2>/dev/null || true
    fi
}

sidebar_port_session_exists() {
    local target="${1:-}"
    [ -n "$target" ] || return 1
    sidebar_tmux_cmd has-session -t "=$target:" >/dev/null 2>&1
}

sidebar_port_mark_session_managed() {
    local session="${1:-}"
    [ -n "$session" ] || return 1
    local opt="${SIDEBAR_MANAGED_OPTION:-@dotfiles_sidebar_managed}"
    sidebar_tmux_cmd set-option -t "=$session:" "$opt" 1 2>/dev/null || true
}

sidebar_port_session_is_managed() {
    local session="${1:-}"
    [ -n "$session" ] || return 1
    local opt="${SIDEBAR_MANAGED_OPTION:-@dotfiles_sidebar_managed}"
    [ "$(sidebar_tmux_cmd show-option -qv -t "=$session:" "$opt" 2>/dev/null || true)" = "1" ]
}

sidebar_port_publish_marker_handover() {
    local window_id="${1:-}" target_session="${2:-}"
    [ -n "$window_id" ] || return 1
    [ -n "$target_session" ] || return 1
    # Handover flags are tmux environment variables (a set-option would make
    # the server redraw every attached client); one client call sets both.
    local scope="${window_id//[^A-Za-z0-9]/_}"
    sidebar_tmux_cmd set-environment -gh "DOTFILES_SIDEBAR_TARGET_MARKER_${scope}" "$target_session" \; \
        set-environment -gh "DOTFILES_SIDEBAR_SELECTION_SYNC_${scope}" "$target_session" 2>/dev/null || true
}

sidebar_port_notify_presenter_wake() {
    local target="${1:-}"
    [ -n "$target" ] || return 0
    local pane_pid=""
    pane_pid="$(sidebar_tmux_cmd display-message -p -t "$target" '#{pane_pid}' 2>/dev/null || true)"
    if [ -z "$pane_pid" ] && declare -f sidebar_window_pane >/dev/null 2>&1; then
        local sb_pane
        sb_pane="$(sidebar_window_pane "$target" 2>/dev/null || true)"
        if [ -n "$sb_pane" ]; then
            pane_pid="$(sidebar_tmux_cmd display-message -p -t "$sb_pane" '#{pane_pid}' 2>/dev/null || true)"
        fi
    fi
    if [ -n "$pane_pid" ] && [ "$pane_pid" -gt 0 ] 2>/dev/null && kill -0 "$pane_pid" 2>/dev/null; then
        kill -WINCH "$pane_pid" 2>/dev/null || kill -SIGWINCH "$pane_pid" 2>/dev/null || true
    fi
    return 0
}

sidebar_tmux_list_user_sessions() {
    local tab="$(printf '\t')"
    local default_fmt="#{session_name}${tab}#{session_created}${tab}#{session_activity}"
    local format="${1:-$default_fmt}"
    sidebar_tmux_cmd list-sessions -F "$format" 2>/dev/null |
        awk -F "$tab" '$1 != "dotfiles-subpane-hub" { print $0 }'
}

# The sidebar pane of a window: the pane carrying the sidebar title (or the
# @dotfiles_sidebar_pane mark).  When no such pane exists any stored pane
# metadata is stale and is cleared here, together with the in-process
# readiness cache the switch path keeps per window.
sidebar_window_pane() {
    local window_id="${1:-}" actual_pane stored_pane
    [ -n "$window_id" ] || return 0
    actual_pane="$(sidebar_tmux_cmd list-panes -t "$window_id" -F '#{pane_id}|#{@dotfiles_sidebar_pane}|#{pane_title}' 2>/dev/null |
        awk -F '|' -v title="$SIDEBAR_TITLE" '$2 == "1" || $3 == title { print $1; exit }' || true)"
    if [ -z "$actual_pane" ]; then
        local win_clean="${window_id//[^a-zA-Z0-9_]/_}"
        printf -v "_cache_window_ready_${win_clean}" '0'
        printf -v "_cache_window_pane_${win_clean}" ''
        stored_pane="$(sidebar_tmux_cmd show-option -wqv -t "$window_id" "$SIDEBAR_WINDOW_PANE_OPTION" 2>/dev/null || true)"
        if [ -n "$stored_pane" ]; then
            sidebar_tmux_cmd set-option -wq -t "$window_id" "$SIDEBAR_WINDOW_PANE_OPTION" "" 2>/dev/null || true
            sidebar_tmux_cmd set-option -wq -t "$window_id" "$SIDEBAR_WINDOW_READY_OPTION" 0 2>/dev/null || true
            trace_event "sidebar.stale-metadata window=$window_id stored_pane=$stored_pane ready=0 reason=pane-missing"
        fi
        return 0
    fi
    printf '%s\n' "$actual_pane"
}

sidebar_window_subpane() {
    local window_id="${1:-}"
    [ -n "$window_id" ] || return 0
    local sub_title="${SIDEBAR_SUBPANE_TITLE:-dotfiles-sidebar-subpane}"
    sidebar_tmux_cmd list-panes -t "$window_id" -F '#{pane_id}|#{@dotfiles_sidebar_subpane}|#{pane_title}' 2>/dev/null |
        awk -F '|' -v title="$sub_title" '$2 == "1" || $3 == title { print $1; exit }'
}

sidebar_port_is_subpane() {
    local pane_id="${1:-}"
    [ -n "$pane_id" ] || return 1
    local opt
    opt="$(sidebar_tmux_cmd show-option -pqv -t "$pane_id" @dotfiles_sidebar_subpane 2>/dev/null || echo 0)"
    [ "$opt" = "1" ]
}

persist_sidebar_subpane_enabled() {
    return 0
}

read_persisted_sidebar_subpane_enabled() {
    return 1
}

sidebar_subpane_get_enabled() {
    local opt="${SIDEBAR_SUBPANE_OPTION:-@dotfiles_sidebar_subpane_enabled}"
    local enabled
    enabled="$(sidebar_tmux_cmd show-option -gqv "$opt" 2>/dev/null || true)"
    if [ "$enabled" = "1" ]; then
        printf '1\n'
        return 0
    fi
    printf '0\n'
    return 0
}

persist_sidebar_subpane_height() {
    local height="$1" state_dir tmp_file
    case "$height" in ''|*[!0-9]*) return 1 ;; esac
    local state_file="${SIDEBAR_SUBPANE_HEIGHT_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/tmux-sidebar-subpane-height}"
    state_dir="$(dirname "$state_file")"
    mkdir -p "$state_dir" 2>/dev/null || return 1
    tmp_file="$(mktemp "$state_dir/.tmux-sidebar-subpane-height.XXXXXX" 2>/dev/null || true)"
    [ -n "$tmp_file" ] || return 1
    if ! printf '%s\n' "$height" > "$tmp_file"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    if ! mv -f -- "$tmp_file" "$state_file"; then
        rm -f -- "$tmp_file"
        return 1
    fi
}

read_persisted_sidebar_subpane_height() {
    local state_file="${SIDEBAR_SUBPANE_HEIGHT_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/tmux-sidebar-subpane-height}"
    local height
    [ -r "$state_file" ] || return 1
    IFS= read -r height < "$state_file" || true
    case "$height" in
        ''|*[!0-9]*) return 1 ;;
        *)
            if [ "$height" -ge 4 ] 2>/dev/null; then
                printf '%s\n' "$height"
                return 0
            fi
            return 1
            ;;
    esac
}

sidebar_subpane_get_height() {
    local opt="${SIDEBAR_SUBPANE_HEIGHT_OPTION:-@dotfiles_sidebar_subpane_height}"
    local height
    height="$(sidebar_tmux_cmd show-option -gqv "$opt" 2>/dev/null || true)"
    if [ -n "$height" ] && [ "$height" -ge 4 ] 2>/dev/null; then
        printf '%s\n' "$height"
        return 0
    fi
    height="$(read_persisted_sidebar_subpane_height || true)"
    if [ -n "$height" ] && [ "$height" -ge 4 ] 2>/dev/null; then
        sidebar_tmux_cmd set-option -gq "$opt" "$height" 2>/dev/null || true
        printf '%s\n' "$height"
        return 0
    fi
    return 1
}

persist_sidebar_subpane_position() {
    return 0
}

read_persisted_sidebar_subpane_position() {
    return 1
}

sidebar_layout_hook_guard_active() {
    local guard
    if [ $# -ge 1 ]; then
        guard="$1"
    else
        guard="$(sidebar_tmux_cmd show-environment -gh "${SIDEBAR_LAYOUT_HOOK_GUARD_ENV:-DOTFILES_SIDEBAR_LAYOUT_HOOK_GUARD}" 2>/dev/null || true)"
        case "$guard" in -*) guard="" ;; *) guard="${guard#*=}" ;; esac
    fi
    case "$guard" in
        ''|*[!0-9]*) return 1 ;;
    esac
    local now
    now="$(date +%s%N)"
    if [ "$guard" -gt "$now" ]; then
        return 0
    fi
    return 1
}

remember_sidebar_subpane_height_for_window() {
    local window_id="${1:-}"
    [ -n "$window_id" ] || return 0
    if declare -f transition_is_active >/dev/null 2>&1 && transition_is_active; then
        return 0
    fi
    local win_sess
    win_sess="$(sidebar_tmux_cmd display-message -p -t "$window_id" '#{session_name}' 2>/dev/null || true)"
    if declare -f is_infrastructure_session >/dev/null 2>&1 && is_infrastructure_session "$win_sess"; then
        return 0
    fi

    if declare -f subpane_hub_snapshot_user_intent >/dev/null 2>&1; then
        subpane_hub_snapshot_user_intent "$window_id" >/dev/null
        return $?
    fi

    local sub_panes=()
    if declare -f subpane_hub_get_window_subpanes >/dev/null 2>&1; then
        while IFS= read -r p_id; do
            [ -n "$p_id" ] || continue
            sub_panes+=("$p_id")
        done < <(subpane_hub_get_window_subpanes "$window_id")
    fi

    if [ "${#sub_panes[@]}" -eq 0 ]; then
        local sub_pane
        sub_pane="$(sidebar_window_subpane "$window_id" || true)"
        [ -n "$sub_pane" ] || return 0
        sub_panes=("$sub_pane")
    fi

    local total_h=0 idx=0
    for p in "${sub_panes[@]}"; do
        local h
        h="$(sidebar_tmux_cmd display-message -p -t "$p" '#{pane_height}' 2>/dev/null || true)"
        if [ -n "$h" ] && [ "$h" -ge 2 ] 2>/dev/null; then
            sidebar_tmux_cmd set-option -gq "@dotfiles_subpane_slot_$((idx + 1))_height" "$h" 2>/dev/null || true
            total_h=$((total_h + h))
        fi
        idx=$((idx + 1))
    done

    if [ "$total_h" -ge 4 ] 2>/dev/null; then
        local opt="${SIDEBAR_SUBPANE_HEIGHT_OPTION:-@dotfiles_sidebar_subpane_height}"
        sidebar_tmux_cmd set-option -gq "$opt" "$total_h" 2>/dev/null || true
        persist_sidebar_subpane_height "$total_h" 2>/dev/null || true
    fi
}

sync_attached_subpane_user_intent() {
    local client_tty="${1:-}" source_win="${2:-}"
    [ -n "$source_win" ] || return 0
    local win_sess
    win_sess="$(sidebar_tmux_cmd display-message -p -t "$source_win" '#{session_name}' 2>/dev/null || true)"
    if declare -f is_infrastructure_session >/dev/null 2>&1 && is_infrastructure_session "$win_sess"; then
        return 0
    fi
    local win_h
    win_h="$(sidebar_tmux_cmd display-message -p -t "$source_win" '#{window_height}' 2>/dev/null || echo 0)"
    case "$win_h" in ''|*[!0-9]*) return 0 ;; esac
    # Precondition: Window height must be adequate for interactive attached display (>= 30 rows)
    # to avoid promoting unattached / headless 24-row default clipping as user intent.
    [ "$win_h" -ge 30 ] || return 0

    if declare -f subpane_hub_snapshot_user_intent >/dev/null 2>&1; then
        local snapshot_total
        snapshot_total="$(subpane_hub_snapshot_user_intent "$source_win" 2>/dev/null || true)"
        if [ -n "$snapshot_total" ] && [ "$snapshot_total" -ge 4 ] 2>/dev/null; then
            printf '%s\n' "$snapshot_total"
            return 0
        fi
    fi

    local sub_pane
    sub_pane="$(sidebar_window_subpane "$source_win" || true)"
    [ -n "$sub_pane" ] || return 0

    if declare -f sync_sidebar_subpane_position_for_window >/dev/null 2>&1; then
        sync_sidebar_subpane_position_for_window "$source_win" 2>/dev/null || true
    fi

    local live_h
    live_h="$(sidebar_tmux_cmd display-message -p -t "$sub_pane" '#{pane_height}' 2>/dev/null || echo 0)"
    case "$live_h" in ''|*[!0-9]*) return 0 ;; esac

    if [ "$live_h" -ge 4 ] && [ "$((win_h - live_h))" -ge 6 ]; then
        local opt="${SIDEBAR_SUBPANE_HEIGHT_OPTION:-@dotfiles_sidebar_subpane_height}"
        sidebar_tmux_cmd set-option -gq "$opt" "$live_h" 2>/dev/null || true
        persist_sidebar_subpane_height "$live_h" 2>/dev/null || true
        printf '%s\n' "$live_h"
        return 0
    fi
    return 0
}

sidebar_subpane_get_position() {
    local opt="${SIDEBAR_SUBPANE_POSITION_OPTION:-@dotfiles_sidebar_subpane_position}"
    local pos
    pos="$(sidebar_tmux_cmd show-option -gqv "$opt" 2>/dev/null || true)"
    case "$pos" in
        top|TOP) printf 'top\n' ;;
        *) printf 'bottom\n' ;;
    esac
}

sidebar_subpane_set_position() {
    local pos="${1:-bottom}"
    local opt="${SIDEBAR_SUBPANE_POSITION_OPTION:-@dotfiles_sidebar_subpane_position}"
    case "$pos" in
        top|TOP) pos="top" ;;
        *) pos="bottom" ;;
    esac
    sidebar_tmux_cmd set-option -gq "$opt" "$pos" 2>/dev/null || true
}

# The one place the pane-border-status row enters the dock geometry.
# SIDEBAR_DOCK_BORDER_EDGE (top|bottom|none) overrides the lookup - an escape
# hatch for a tmux build that does not charge the y=0 row.
sidebar_port_dock_border_edge() {   # <window>
    local window="${1:-}" status=""
    if [ -n "${SIDEBAR_DOCK_BORDER_EDGE:-}" ]; then
        sidebar_domain_dock_border_edge "$SIDEBAR_DOCK_BORDER_EDGE"
        return 0
    fi
    [ -n "$window" ] && status="$(sidebar_tmux_cmd show-options -wqv -t "$window" pane-border-status 2>/dev/null || true)"
    [ -n "$status" ] || status="$(sidebar_tmux_cmd show-options -gwqv pane-border-status 2>/dev/null || true)"
    sidebar_domain_dock_border_edge "$status"
}

# The hub builder lives in sidebar_subpane_hub.sh; callers that sourced only
# this port (tests, ad-hoc shells) get it here. The bundled dist inlines it.
_sidebar_port_ensure_hub() {
    declare -f subpane_hub_atomic_migrate >/dev/null 2>&1 && return 0
    local hub
    hub="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/sidebar_subpane_hub.sh"
    [ -r "$hub" ] || return 1
    # shellcheck disable=SC1090
    source "$hub"
}

sidebar_subpane_swap_position() {
    local window_id="${1:-}"
    [ -n "$window_id" ] || window_id="$(sidebar_tmux_cmd display-message -p '#{window_id}' 2>/dev/null || true)"
    [ -n "$window_id" ] || return 1

    remember_sidebar_subpane_height_for_window "$window_id"

    _sidebar_port_ensure_hub || return 1
    subpane_hub_swap_stack_position "$window_id"
    if declare -f save_sidebar_layout >/dev/null 2>&1; then
        save_sidebar_layout "$window_id" 2>/dev/null || true
    fi
    return 0
}

sync_sidebar_subpane_position_for_window() {
    local window_id="${1:-}"
    [ -n "$window_id" ] || window_id="$(sidebar_tmux_cmd display-message -p '#{window_id}' 2>/dev/null || true)"
    [ -n "$window_id" ] || return 0

    local launcher_pane sub_pane
    launcher_pane="$(sidebar_window_pane "$window_id" 2>/dev/null || true)"
    sub_pane="$(sidebar_window_subpane "$window_id" 2>/dev/null || true)"
    [ -n "$launcher_pane" ] && [ -n "$sub_pane" ] || return 0

    local l_top s_top
    l_top="$(sidebar_tmux_cmd display-message -p -t "$launcher_pane" '#{pane_top}' 2>/dev/null || true)"
    s_top="$(sidebar_tmux_cmd display-message -p -t "$sub_pane" '#{pane_top}' 2>/dev/null || true)"
    case "$l_top" in
        ''|*[!0-9]*) return 0 ;;
    esac
    case "$s_top" in
        ''|*[!0-9]*) return 0 ;;
    esac

    if [ "$s_top" -lt "$l_top" ]; then
        sidebar_subpane_set_position "top"
    elif [ "$s_top" -gt "$l_top" ]; then
        sidebar_subpane_set_position "bottom"
    fi
}

provision_sidebar_subpane() {
    local window_id="${1:-}" launcher_pane="${2:-}" height="${3:-}" cmd="${4:-}"
    [ -n "$launcher_pane" ] || return 1
    if [ -z "$height" ]; then
        local saved_h
        saved_h="$(sidebar_subpane_get_height || true)"
        if [ -n "$saved_h" ] && [ "$saved_h" -ge 4 ] 2>/dev/null; then
            height="$saved_h"
        else
            local total_h
            total_h="$(sidebar_tmux_cmd display-message -p -t "$window_id" '#{window_height}' 2>/dev/null || echo 40)"
            height="$(sidebar_subpane_default_height "$total_h")"
        fi
    fi

    # The hub builder is the only stack builder (joins for order, one layout
    # string for geometry); it prints the first slot pane like this did.
    _sidebar_port_ensure_hub || return 1
    subpane_hub_atomic_migrate "$launcher_pane" "$height"
}

destroy_sidebar_subpane() {
    local window_id="${1:-}"
    [ -n "$window_id" ] || return 0
    local win_sess
    win_sess="$(sidebar_tmux_cmd display-message -p -t "$window_id" '#{session_name}' 2>/dev/null || true)"
    if declare -f is_infrastructure_session >/dev/null 2>&1 && is_infrastructure_session "$win_sess"; then
        return 0
    fi
    remember_sidebar_subpane_height_for_window "$window_id"
    local sub_pane
    while IFS= read -r sub_pane; do
        [ -n "$sub_pane" ] || continue
        if declare -f subpane_hub_release_pane >/dev/null 2>&1; then
            subpane_hub_release_pane "$sub_pane"
        else
            sidebar_tmux_cmd kill-pane -t "$sub_pane" 2>/dev/null || true
        fi
    done < <(sidebar_tmux_cmd list-panes -t "$window_id" -F '#{pane_id}|#{@dotfiles_sidebar_subpane}' 2>/dev/null | awk -F '|' '$2 == "1" { print $1 }')
}

ensure_sidebar_subpane_window() {
    local window_id="${1:-}" launcher_pane="${2:-}" force="${3:-false}"
    [ -n "$window_id" ] || return 0
    local win_sess
    win_sess="$(sidebar_tmux_cmd display-message -p -t "$window_id" '#{session_name}' 2>/dev/null || true)"
    if declare -f is_infrastructure_session >/dev/null 2>&1 && is_infrastructure_session "$win_sess"; then
        return 0
    fi
    [ -n "$launcher_pane" ] || launcher_pane="$(sidebar_window_pane "$window_id" || true)"
    [ -n "$launcher_pane" ] || return 0

    local enabled
    enabled="$(sidebar_subpane_get_enabled)"

    if [ "$enabled" = "1" ]; then
        if [ "$force" != true ] && declare -f subpane_hub_get_lease_holder >/dev/null 2>&1; then
            local current_lease
            current_lease="$(subpane_hub_get_lease_holder 2>/dev/null || true)"
            if [ -n "$current_lease" ] && [ "$current_lease" != "$window_id" ]; then
                if sidebar_tmux_cmd display-message -p -t "$current_lease" '#{window_id}' >/dev/null 2>&1; then
                    local client_windows
                    client_windows="$(sidebar_tmux_cmd list-clients -F '#{window_id}' 2>/dev/null || true)"
                    if [ -n "$client_windows" ] && ! printf '%s\n' "$client_windows" | grep -qx "$window_id"; then
                        trace_event "subpane.ensure.skip reason=background-window window=$window_id lease_holder=$current_lease"
                        return 0
                    fi
                fi
            fi
        fi

        local expected_count=1
        if declare -f subpane_hub_get_count >/dev/null 2>&1; then
            expected_count="$(subpane_hub_get_count)"
        fi
        [ -n "$expected_count" ] || expected_count=1

        # Always run through canonical lease movement. Identity reconciliation
        # makes a correct target a no-op and removes duplicates before transfer.
        provision_sidebar_subpane "$window_id" "$launcher_pane" "" "" >/dev/null 2>&1
        return $?

    else
        local lease_holder=""
        if declare -f subpane_hub_get_lease_holder >/dev/null 2>&1; then
            lease_holder="$(subpane_hub_get_lease_holder 2>/dev/null || true)"
            if [ -n "$lease_holder" ] && declare -f subpane_hub_snapshot_user_intent >/dev/null 2>&1; then
                subpane_hub_snapshot_user_intent "$lease_holder" >/dev/null 2>&1 || true
            fi
        fi
        local sub_pane
        sub_pane="$(sidebar_window_subpane "$window_id" || true)"
        if [ -n "$sub_pane" ]; then
            destroy_sidebar_subpane "$window_id"
        fi
    fi
}

toggle_sidebar_subpane_global() {
    local target_window="${1:-${SIDEBAR_WINDOW_ID:-}}"
    local opt="${SIDEBAR_SUBPANE_OPTION:-@dotfiles_sidebar_subpane_enabled}"
    local current
    current="$(sidebar_subpane_get_enabled)"
    local next=1
    [ "$current" = "1" ] && next=0
    sidebar_tmux_cmd set-option -gq "$opt" "$next" 2>/dev/null || true
    persist_sidebar_subpane_enabled "$next" 2>/dev/null || true

    if [ "$next" = "1" ]; then
        local active_win="$target_window"
        if [ -n "$active_win" ] && declare -f is_infrastructure_session >/dev/null 2>&1 && is_infrastructure_session "$(sidebar_tmux_cmd display-message -p -t "$active_win" '#{session_name}' 2>/dev/null || true)"; then
            active_win=""
        fi
        if [ -z "$active_win" ] && [ -n "${TMUX_PANE:-}" ]; then
            active_win="$(sidebar_tmux_cmd display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null || true)"
            if [ -n "$active_win" ] && declare -f is_infrastructure_session >/dev/null 2>&1 && is_infrastructure_session "$(sidebar_tmux_cmd display-message -p -t "$active_win" '#{session_name}' 2>/dev/null || true)"; then
                active_win=""
            fi
        fi
        if [ -z "$active_win" ]; then
            local client_tty
            client_tty="$(sidebar_tmux_cmd show-option -gqv "@dotfiles_sidebar_owner_client" 2>/dev/null || true)"
            [ -n "$client_tty" ] || client_tty="$(sidebar_tmux_cmd list-clients -F '#{client_tty}' 2>/dev/null | head -n 1 || true)"
            if [ -n "$client_tty" ]; then
                active_win="$(sidebar_client_field "$client_tty" '#{window_id}' || true)"
            fi
        fi
        if [ -z "$active_win" ] || (declare -f is_infrastructure_session >/dev/null 2>&1 && is_infrastructure_session "$(sidebar_tmux_cmd display-message -p -t "$active_win" '#{session_name}' 2>/dev/null || true)"); then
            active_win="$(sidebar_tmux_cmd list-windows -a -F '#{window_id}|#{session_name}' 2>/dev/null | awk -F '|' '!/dotfiles-subpane-hub/ { print $1; exit }')"
        fi
        if [ -n "$active_win" ]; then
            ensure_sidebar_subpane_window "$active_win" ""
        fi
    else
        local sub_pane
        if declare -f subpane_hub_get_pane >/dev/null 2>&1; then
            sub_pane="$(subpane_hub_get_pane 2>/dev/null || true)"
            if [ -n "$sub_pane" ] && declare -f subpane_hub_release_pane >/dev/null 2>&1; then
                subpane_hub_release_pane "$sub_pane"
            fi
        fi
        local win_id sess_name
        while IFS='|' read -r win_id sess_name; do
            [ -n "$win_id" ] || continue
            if declare -f is_infrastructure_session >/dev/null 2>&1 && is_infrastructure_session "$sess_name"; then
                continue
            fi
            destroy_sidebar_subpane "$win_id"
        done < <(sidebar_tmux_cmd list-windows -a -F '#{window_id}|#{session_name}' 2>/dev/null || true)
    fi
}

# Test-harness primitive: split one titled sidebar pane into a window without
# the lifecycle machinery (locks, reconcile, respawn, layout restore) of the
# core provision_sidebar_window.  Not used by production code.
sidebar_port_split_sidebar_pane() {
    local window_id="${1:-}" width="${2:-30}" cmd="${3:-}" subpane_enabled="${4:-}"
    [ -n "$window_id" ] || return 1
    local win_sess
    win_sess="$(sidebar_tmux_cmd display-message -p -t "$window_id" '#{session_name}' 2>/dev/null || true)"
    if is_infrastructure_session "$win_sess"; then
        return 0
    fi
    local existing
    existing="$(sidebar_window_pane "$window_id" || true)"
    if [ -n "$existing" ]; then
        if [ "$subpane_enabled" = "0" ]; then
            :
        elif [ "$subpane_enabled" = "1" ] || [ "$(sidebar_subpane_get_enabled)" = "1" ]; then
            ensure_sidebar_subpane_window "$window_id" "$existing" || true
        fi
        return 0
    fi
    local work_pane
    work_pane="$(sidebar_tmux_cmd list-panes -t "$window_id" -F '#{pane_id}|#{pane_title}|#{@dotfiles_sidebar_subpane}' 2>/dev/null |
        awk -F '|' '$2 != "dotfiles-session-sidebar" && $2 != "dotfiles-sidebar-subpane" && $3 != "1" { print $1; exit }')"
    [ -n "$work_pane" ] || return 1
    if [ -z "$cmd" ]; then
        local launcher_bin="${TMUX_SESSION_DOCK_BIN:-${LAUNCHER:-}}"
        local base_dir
        base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd || echo "")"
        [ -n "$launcher_bin" ] && [ -x "$launcher_bin" ] || launcher_bin="$base_dir/dist/tmux-session-dock"
        [ -x "$launcher_bin" ] || launcher_bin="$base_dir/scripts/tmux-session-dock"
        [ -x "$launcher_bin" ] || launcher_bin="$base_dir/bin/tmux-session-dock"
        [ -x "$launcher_bin" ] || launcher_bin="tmux-session-dock"
        cmd="$launcher_bin --sidebar"
    fi
    local pane_id
    pane_id="$(sidebar_tmux_cmd split-window -P -F '#{pane_id}' -d -t "$work_pane" -h -f -b -l "$width" "$cmd" 2>/dev/null || true)"
    [ -n "$pane_id" ] || return 1
    sidebar_tmux_cmd select-pane -t "$pane_id" -T "dotfiles-session-sidebar" 2>/dev/null || true
    sidebar_tmux_cmd set-option -p -q -t "$pane_id" remain-on-exit on 2>/dev/null || true
    sidebar_tmux_cmd set-option -p -q -t "$pane_id" @dotfiles_sidebar_pane 1 2>/dev/null || true
    if [ "$subpane_enabled" = "0" ]; then
        :
    elif [ "$subpane_enabled" = "1" ] || [ "$(sidebar_subpane_get_enabled)" = "1" ]; then
        ensure_sidebar_subpane_window "$window_id" "$pane_id" || true
    fi
    printf '%s\n' "$pane_id"
}

destroy_sidebar_window() {
    local window_id="${1:-}"
    [ -n "$window_id" ] || return 0
    local sb_pane
    sb_pane="$(sidebar_tmux_cmd list-panes -t "$window_id" -F '#{pane_id}|#{pane_title}|#{@dotfiles_sidebar_pane}' 2>/dev/null |
        awk -F '|' '$2 == "dotfiles-session-sidebar" || $3 == "1" { print $1; exit }')"
    if [ -n "$sb_pane" ]; then
        sidebar_tmux_cmd kill-pane -t "$sb_pane" 2>/dev/null || true
    fi
}
