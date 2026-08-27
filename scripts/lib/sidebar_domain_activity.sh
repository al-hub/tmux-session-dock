#!/usr/bin/env bash
# Pure domain AI activity observer for tmux-session-dock (running / idle / gone)
# Zero tmux server dependency, zero I/O side-effects, fully unit testable

declare -gA _SIDEBAR_ACTIVITY_PID=()
declare -gA _SIDEBAR_ACTIVITY_STATE=()
declare -gA _SIDEBAR_ACTIVITY_ANIMATE=()
declare -gA _SIDEBAR_ACTIVITY_PANE=()
declare -gA _SIDEBAR_ACTIVITY_OBSERVATION=()
declare -gA _SIDEBAR_ACTIVITY_LAST_CHANGED_AT=()

# Evaluate one session-scoped AI activity observation.  Callers supply the
# tmux-derived liveness and opaque observation so this policy remains pure.
# The changed result signals an observable state transition, not every
# heartbeat; presenters can therefore redraw only rows whose gradient changes.
sidebar_domain_activity_observe() {
    local -n _out_state="$1"
    local -n _out_changed="$2"
    local session_name="${3:-}"
    local pane_id="${4:-}"
    local pane_pid="${5:-}"
    local alive="${6:-false}"
    local observation="${7:-}"
    local now="${8:-0}"
    local idle_timeout="${9:-0}"
    local previous_state="${_SIDEBAR_ACTIVITY_STATE[$session_name]:-gone}"
    local state="gone"
    local pane_replaced=false
    local observed_change=false

    case "$now" in ''|*[!0-9]*) now=0 ;; esac
    case "$idle_timeout" in ''|*[!0-9]*) idle_timeout=0 ;; esac

    if [ -n "$session_name" ] && [ "$alive" = true ] && [ -n "$pane_id" ]; then
        if [ "${_SIDEBAR_ACTIVITY_PANE[$session_name]:-}" != "$pane_id" ] ||
            [ "${_SIDEBAR_ACTIVITY_PID[$session_name]:-}" != "$pane_pid" ]; then
            pane_replaced=true
        fi

        if [ "$pane_replaced" = true ] ||
            [ "${_SIDEBAR_ACTIVITY_OBSERVATION[$session_name]+set}" != set ] ||
            [ "${_SIDEBAR_ACTIVITY_OBSERVATION[$session_name]}" != "$observation" ]; then
            observed_change=true
            _SIDEBAR_ACTIVITY_LAST_CHANGED_AT["$session_name"]="$now"
            _SIDEBAR_ACTIVITY_OBSERVATION["$session_name"]="$observation"
        fi

        _SIDEBAR_ACTIVITY_PANE["$session_name"]="$pane_id"
        _SIDEBAR_ACTIVITY_PID["$session_name"]="$pane_pid"

        local last_changed="${_SIDEBAR_ACTIVITY_LAST_CHANGED_AT[$session_name]:-$now}"
        if [ "$observed_change" = true ] || [ $((now - last_changed)) -lt "$idle_timeout" ]; then
            state="running"
        else
            state="idle"
        fi
    fi

    if [ -n "$session_name" ]; then
        _SIDEBAR_ACTIVITY_STATE["$session_name"]="$state"
        _SIDEBAR_ACTIVITY_ANIMATE["$session_name"]="$([ "$state" = running ] && printf true || printf false)"
        if [ "$state" = gone ]; then
            unset '_SIDEBAR_ACTIVITY_PANE["$session_name"]'
            unset '_SIDEBAR_ACTIVITY_OBSERVATION["$session_name"]'
            unset '_SIDEBAR_ACTIVITY_LAST_CHANGED_AT["$session_name"]'
            unset '_SIDEBAR_ACTIVITY_PID["$session_name"]'
        fi
    fi

    _out_state="$state"
    if [ "$previous_state" != "$state" ]; then
        _out_changed=true
    else
        _out_changed=false
    fi
}

sidebar_domain_activity_get_state()
{
    local session_name="${1:-}"
    printf '%s\n' "${_SIDEBAR_ACTIVITY_STATE[$session_name]:-gone}"
}

sidebar_domain_activity_get_animate()
{
    local session_name="${1:-}"
    printf '%s\n' "${_SIDEBAR_ACTIVITY_ANIMATE[$session_name]:-false}"
}

sidebar_domain_activity_reset_all()
{
    _SIDEBAR_ACTIVITY_PID=()
    _SIDEBAR_ACTIVITY_STATE=()
    _SIDEBAR_ACTIVITY_ANIMATE=()
    _SIDEBAR_ACTIVITY_PANE=()
    _SIDEBAR_ACTIVITY_OBSERVATION=()
    _SIDEBAR_ACTIVITY_LAST_CHANGED_AT=()
}
