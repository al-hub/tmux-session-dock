#!/usr/bin/env bash
# Pure domain AI activity observer for tmux-session-dock
# (running / awaiting / idle / gone)
# Zero tmux server dependency, zero I/O side-effects, fully unit testable

declare -gA _SIDEBAR_ACTIVITY_PID=()
declare -gA _SIDEBAR_ACTIVITY_STATE=()
declare -gA _SIDEBAR_ACTIVITY_ANIMATE=()
declare -gA _SIDEBAR_ACTIVITY_PANE=()
declare -gA _SIDEBAR_ACTIVITY_OBSERVATION=()
declare -gA _SIDEBAR_ACTIVITY_LAST_CHANGED_AT=()
# True once a session has been observed changing for real. The very first
# observation of a session always looks like a change (the maps are empty), so
# without this flag every session would appear to have been running and then to
# have stopped - painting a false "awaiting" on each one whenever an observer
# starts.
declare -gA _SIDEBAR_ACTIVITY_SEEN=()
# True once a session has been observed changing for real, i.e. on some
# observation after the first. Only such a session can have "stopped"; one that
# has merely been sighted has nothing to announce.
declare -gA _SIDEBAR_ACTIVITY_MOVED=()
# The stop the user has already witnessed, keyed by the moment that stop began.
# A stop is announced once: leaving the session again must not re-raise the
# same one, and only fresh activity (which moves the timestamp) can.
declare -gA _SIDEBAR_ACTIVITY_ACKED_AT=()

# How long a session must stay unchanged before its stop is worth reporting, and
# the bounds a user-supplied value is held to.
SIDEBAR_AWAITING_AFTER_MS_MIN=1000
SIDEBAR_AWAITING_AFTER_MS_MAX=300000
SIDEBAR_AWAITING_AFTER_MS_DEFAULT=30000

# Clamp a user-supplied threshold; result in sidebar_awaiting_after_ms_result.
sidebar_awaiting_after_ms_result=0
sidebar_domain_activity_await_after() {
    local ms="${1:-}"
    case "$ms" in
        ''|*[!0-9]*) ms="$SIDEBAR_AWAITING_AFTER_MS_DEFAULT" ;;
    esac
    [ "$ms" -lt "$SIDEBAR_AWAITING_AFTER_MS_MIN" ] && ms="$SIDEBAR_AWAITING_AFTER_MS_MIN"
    [ "$ms" -gt "$SIDEBAR_AWAITING_AFTER_MS_MAX" ] && ms="$SIDEBAR_AWAITING_AFTER_MS_MAX"
    sidebar_awaiting_after_ms_result="$ms"
}

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
    # Seconds a stop must persist before it is reported as awaiting. 0 disables
    # awaiting entirely, which is how a presenter observing locally (no shared
    # observer) avoids publishing a verdict its neighbours cannot agree with.
    local await_after="${10:-0}"
    # True when a client is currently on this session: the user is here, so a
    # stop needs no announcement.
    local acknowledged="${11:-false}"
    local previous_state="${_SIDEBAR_ACTIVITY_STATE[$session_name]:-gone}"
    local state="gone"
    local pane_replaced=false
    local observed_change=false

    case "$now" in ''|*[!0-9]*) now=0 ;; esac
    case "$idle_timeout" in ''|*[!0-9]*) idle_timeout=0 ;; esac
    case "$await_after" in ''|*[!0-9]*) await_after=0 ;; esac

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

        local first_sighting=false
        if [ "${_SIDEBAR_ACTIVITY_SEEN[$session_name]:-}" != true ]; then
            first_sighting=true
            _SIDEBAR_ACTIVITY_SEEN["$session_name"]=true
        elif [ "$observed_change" = true ]; then
            _SIDEBAR_ACTIVITY_MOVED["$session_name"]=true
        fi

        local last_changed="${_SIDEBAR_ACTIVITY_LAST_CHANGED_AT[$session_name]:-$now}"
        if [ "$acknowledged" = true ]; then
            _SIDEBAR_ACTIVITY_ACKED_AT["$session_name"]="$last_changed"
        fi
        if [ "$observed_change" = true ] || [ $((now - last_changed)) -lt "$idle_timeout" ]; then
            state="running"
        elif [ "$await_after" -gt 0 ] && [ "$acknowledged" != true ] &&
            [ "${_SIDEBAR_ACTIVITY_MOVED[$session_name]:-}" = true ] &&
            [ "${_SIDEBAR_ACTIVITY_ACKED_AT[$session_name]:-}" != "$last_changed" ] &&
            [ $((now - last_changed)) -ge "$await_after" ]; then
            # Stopped long enough to be worth reporting, and nobody has been
            # here since. Stays awaiting until the user arrives or the AI moves
            # again - a clock never clears it, because a clock cannot know
            # whether the user saw anything.
            state="awaiting"
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
            unset '_SIDEBAR_ACTIVITY_SEEN["$session_name"]'
            unset '_SIDEBAR_ACTIVITY_ACKED_AT["$session_name"]'
            unset '_SIDEBAR_ACTIVITY_MOVED["$session_name"]'
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
    _SIDEBAR_ACTIVITY_SEEN=()
    _SIDEBAR_ACTIVITY_ACKED_AT=()
    _SIDEBAR_ACTIVITY_MOVED=()
}
