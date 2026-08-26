#!/usr/bin/env bash
# Coordinator Event Bus & State Lifecycle Manager Module
set -euo pipefail

sidebar_coordinator_init() {
    local session_id="${1:-global}"
    echo "INIT_OK"
}

sidebar_coordinator_dispatch_event() {
    local event_type="$1" payload="$2"
    case "$event_type" in
        "SWITCH_REQUEST")
            echo "HANDLED_SWITCH"
            ;;
        "RESIZE_EVENT")
            echo "HANDLED_RESIZE"
            ;;
        *)
            echo "UNKNOWN_EVENT"
            ;;
    esac
}

# A Presenter Window has one marker slot, so a newer settled handover
# deliberately supersedes an unflushed older frame. The coordinator owns both
# that Last-Writer-Wins queue and the only render dispatch for its intents.
transition_coordinator_queue_handover_render() {
    local intent="$1" target="$2" old_current="$3" old_selected_index="$4" old_selected_session="$5"
    [ "$intent" != none ] || return 0
    if [ "${handover_render_intent:-none}" != none ]; then
        trace_event "handover.render.coalesce previous_target=${handover_render_target:-none} target=$target"
    fi
    handover_render_generation=$(( ${handover_render_generation:-0} + 1 ))
    handover_render_intent="$intent"
    handover_render_target="$target"
    handover_render_old_current="$old_current"
    handover_render_old_selected_index="$old_selected_index"
    handover_render_old_selected_session="$old_selected_session"
    trace_event "handover.render.queue generation=$handover_render_generation target=$target intent=$intent"
}

transition_coordinator_flush_handover_render() {
    local intent="${handover_render_intent:-none}"
    [ "$intent" != none ] || return 0

    case "$intent" in
        delta)
            render_marker_delta "${handover_render_old_current:-}" \
                "${handover_render_old_selected_index:--1}" \
                "${handover_render_old_selected_session:-}"
            render_footer
            ;;
        full)
            request_full_render marker-handover-reconcile
            ;;
        deferred)
            if transition_commit_pending; then
                request_full_render enter-session-switch
            elif transition_is_active; then
                return 0
            else
                request_full_render marker-handover-reconcile
            fi
            ;;
    esac
    trace_event "handover.render.flush generation=${handover_render_generation:-0} target=${handover_render_target:-none} intent=$intent"
    handover_render_intent=none
    handover_render_target=""
}

selection_coordinator_align_current() {
    local target_curr="${1:-}"
    if [ "${#session_names[@]}" -eq 0 ]; then
        selected_session=""
        selected_index=-1
        return 0
    fi

    local candidate="${target_curr:-${selected_session:-${current_session:-}}}"
    local idx
    if [ -n "$candidate" ]; then
        for idx in "${!session_names[@]}"; do
            if [ "${session_names[$idx]}" = "$candidate" ]; then
                selected_session="${session_names[$idx]}"
                selected_index="$idx"
                return 0
            fi
        done
    fi

    # If candidate wasn't found, try current_session or selected_session
    if [ -n "${current_session:-}" ] && [ "${current_session:-}" != "$candidate" ]; then
        for idx in "${!session_names[@]}"; do
            if [ "${session_names[$idx]}" = "$current_session" ]; then
                selected_session="${session_names[$idx]}"
                selected_index="$idx"
                return 0
            fi
        done
    fi

    if [ -n "${selected_session:-}" ] && [ "${selected_session:-}" != "$candidate" ]; then
        for idx in "${!session_names[@]}"; do
            if [ "${session_names[$idx]}" = "$selected_session" ]; then
                selected_session="${session_names[$idx]}"
                selected_index="$idx"
                return 0
            fi
        done
    fi

    # Fallback to first session if not found or empty
    selected_session="${session_names[0]}"
    selected_index=0
}

selection_coordinator_compute_delta() {
    local -a changed_indexes=()
    local arg idx duplicate

    for arg in "$@"; do
        case "$arg" in
            ''|*[!0-9]*) continue ;;
        esac
        duplicate=false
        for idx in "${changed_indexes[@]}"; do
            if [ "$idx" -eq "$arg" ]; then
                duplicate=true
                break
            fi
        done
        if [ "$duplicate" = false ]; then
            changed_indexes+=("$arg")
        fi
    done

    if [ "${#changed_indexes[@]}" -gt 0 ]; then
        printf '%s\n' "${changed_indexes[@]}"
    fi
}
