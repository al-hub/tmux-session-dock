#!/usr/bin/env bash
# Shared helpers for the sidebar-width contract tests.
# Expects the caller to define: TMUX (array), HOME_DIR, HISTORY_DIR, LAUNCHER,
# REPO_ROOT, WIDTH_STATE_FILE.

tmuxc() { HOME="$HOME_DIR" TMUX_SESSION_HISTORY_DIR="$HISTORY_DIR" "${TMUX[@]}" "$@"; }

sidebar_pane_for() {
    tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' |
        awk -F '|' '$2 == "dotfiles-session-sidebar" { print $1; exit }'
}

# Poll until the pane shows the expected width. Timeout is a FAIL.
wait_for_width() {
    local pane_id="$1" expected="$2" attempt actual
    for attempt in $(seq 1 100); do
        actual="$(tmuxc display-message -p -t "$pane_id" '#{pane_width}' 2>/dev/null || true)"
        [ "$actual" = "$expected" ] && return 0
        sleep 0.05
    done
    echo "FAIL: expected visible sidebar width $expected, got ${actual:-absent}" >&2
    return 1
}

# Poll until the persisted width file holds the expected value. Timeout is a FAIL.
wait_for_persisted_width() {
    local expected="$1" attempt actual
    for attempt in $(seq 1 100); do
        actual="$(tr -d '[:space:]' < "$WIDTH_STATE_FILE" 2>/dev/null || true)"
        [ "$actual" = "$expected" ] && return 0
        sleep 0.05
    done
    echo "FAIL: expected persisted sidebar width $expected, got '${actual:-absent}'" >&2
    return 1
}

# Wait until provisioning has finished moving the pane: width unchanged for
# 1.5s of consecutive polls. User interaction in these tests starts only after
# this, so the oracle measures the user's action, not provisioning churn.
wait_for_settled_width() {
    local pane_id="$1" stable=0 last="" cur
    while [ "$stable" -lt 15 ]; do
        cur="$(tmuxc display-message -p -t "$pane_id" '#{pane_width}' 2>/dev/null || true)"
        if [ -n "$cur" ] && [ "$cur" = "$last" ]; then stable=$((stable + 1)); else stable=0; fi
        last="$cur"
        sleep 0.1
    done
}

# Create a session, mark it managed, provision its sidebar; print the sidebar pane id.
provision_session() {
    local session_name="$1" width="${2:-}" window_id pane_id
    tmuxc new-session -d -s "$session_name" -x 140 -y 50 -c "$REPO_ROOT" 'sleep 300'
    window_id="$(tmuxc display-message -p -t "=$session_name:" '#{window_id}')"
    tmuxc set-option -wq -t "$window_id" @dotfiles_sidebar_managed 1
    if [ -n "$width" ]; then
        tmuxc run-shell "$LAUNCHER --ensure-sidebar-window '$window_id' '$width'"
    else
        tmuxc run-shell "$LAUNCHER --ensure-sidebar-window '$window_id'"
    fi
    for _ in $(seq 1 100); do
        pane_id="$(sidebar_pane_for "$session_name")"
        [ -n "$pane_id" ] && { printf '%s\n' "$pane_id"; return 0; }
        sleep 0.05
    done
    echo "FAIL: sidebar was not provisioned for $session_name" >&2
    return 1
}
