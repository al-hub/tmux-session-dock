#!/usr/bin/env bash
# ==============================================================================
# sidebar_ime.sh - IME focus hooks for tmux-session-dock
#
# Goal: the sidebar's letter shortcuts (j/k/c/r/d/o/h/a/s/p/q) must work even
# when the user types Korean (or another CJK language) in the work panes.
# Whenever the sidebar pane gains focus, the OS input method is switched to
# English/alphanumeric; optionally the previous mode is restored on leave.
#
# Setting (tmux option > persisted state file > default):
#   @session-dock-ime   off | on | restore     (default off)
#       on       sidebar focus -> English; leaving restores nothing
#       restore  sidebar focus -> remember mode, English; leaving -> restore
#
# Mechanism: tmux `pane-focus-in` / `pane-focus-out` hooks whose pane_title
# compare runs inside tmux (`if-shell -F`, no process, ~0.1 ms per event) and
# run the one-shot helper `tmux-session-dock-ime` only for the sidebar pane,
# whatever brought the focus there (Alt+s, Alt+arrows, mouse, session switch).
# Hooks need `focus-events on` and an attached focused client; headless
# servers (tests, CI) never fire them.
# ==============================================================================
set -euo pipefail

SIDEBAR_IME_OPTION="@session-dock-ime"
SIDEBAR_IME_HOOK_IN="pane-focus-in"
SIDEBAR_IME_HOOK_OUT="pane-focus-out"
SIDEBAR_IME_TITLE="dotfiles-session-sidebar"
SIDEBAR_IME_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles"
SIDEBAR_IME_STATE_FILE="$SIDEBAR_IME_STATE_DIR/tmux-sidebar-ime"

sidebar_ime_normalize()
{
    case "${1:-}" in
        restore) echo "restore" ;;
        on|1|true|yes|english) echo "on" ;;
        *) echo "off" ;;
    esac
}

# The helper script: installed copy first, then the checkout next to this code.
sidebar_ime_helper_path()
{
    local candidate here
    candidate="$HOME/.local/bin/tmux-session-dock-ime"
    [ -x "$candidate" ] && { echo "$candidate"; return 0; }
    here="${LAUNCHER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    for candidate in "$here/tmux-session-dock-ime" "$here/../scripts/tmux-session-dock-ime" "$here/../tmux-session-dock-ime"; do
        [ -x "$candidate" ] && { echo "$candidate"; return 0; }
    done
    return 1
}

sidebar_ime_backend_name()
{
    local helper
    helper="$(sidebar_ime_helper_path 2>/dev/null || true)"
    [ -n "$helper" ] || { echo "none"; return 0; }
    "$helper" backend 2>/dev/null || echo "none"
}

sidebar_ime_available()
{
    [ "$(sidebar_ime_backend_name)" != "none" ]
}

sidebar_ime_read_setting()
{
    # $1 option, $2 state file
    local value=""
    value="$(tmux show-option -gqv "$1" 2>/dev/null || true)"
    if [ -z "$value" ] && [ -r "$2" ]; then
        IFS= read -r value < "$2" || true
    fi
    printf '%s' "$value"
}

sidebar_ime_setting()
{
    sidebar_ime_normalize "$(sidebar_ime_read_setting "$SIDEBAR_IME_OPTION" "$SIDEBAR_IME_STATE_FILE")"
}

sidebar_ime_write_setting()
{
    # $1 option, $2 state file, $3 value
    tmux set-option -gq "$1" "$3" 2>/dev/null || true
    if mkdir -p "$SIDEBAR_IME_STATE_DIR" 2>/dev/null; then
        printf '%s\n' "$3" > "$2" 2>/dev/null || true
    fi
}

sidebar_ime_hook_command()
{
    # $1 = helper invocation. The title compare runs inside tmux; only a match
    # forks the helper. run-shell -b keeps the focus change non-blocking.
    printf "if-shell -F '#{==:#{pane_title},%s}' 'run-shell -b \"%s\"'" "$SIDEBAR_IME_TITLE" "$1"
}

# Index of our entry in a hook array, or nothing.
# tmux 3.2a omits pane-focus-in/out from a bare `show-hooks -g`; name the hook.
sidebar_ime_hook_index()
{
    tmux show-hooks -g "$1" 2>/dev/null | awk -v hook="$1" -v marker="pane_title},$SIDEBAR_IME_TITLE}" '
        index($0, hook "[") == 1 && index($0, marker) {
            entry = $1
            sub(/^[^[]*\[/, "", entry)
            sub(/\].*/, "", entry)
            print entry
            exit
        }'
}

sidebar_ime_hook_installed()
{
    [ -n "$(sidebar_ime_hook_index "$1")" ]
}

sidebar_ime_uninstall_hook()
{
    local index
    index="$(sidebar_ime_hook_index "$1")"
    [ -n "$index" ] || return 0
    tmux set-hook -gu "$1[$index]" 2>/dev/null || true
}

sidebar_ime_install_hook()
{
    # $1 hook name, $2 helper invocation
    local hook
    hook="$(sidebar_ime_hook_command "$2")"
    if tmux show-hooks -g "$1" 2>/dev/null | grep -F "$1[" | grep -F "pane_title},$SIDEBAR_IME_TITLE}" | grep -qF -- "$2"; then
        return 0
    fi
    sidebar_ime_uninstall_hook "$1"
    tmux set-option -g focus-events on 2>/dev/null || true
    # Append so a user's own hooks survive.
    tmux set-hook -ga "$1" "$hook" 2>/dev/null || true
}

# Reconcile both hooks with the current setting. Safe to call any time.
sidebar_ime_apply()
{
    local setting helper
    setting="$(sidebar_ime_setting)"
    helper="$(sidebar_ime_helper_path 2>/dev/null || true)"
    if [ "$setting" = "off" ] || [ -z "$helper" ] || ! sidebar_ime_available; then
        sidebar_ime_uninstall_hook "$SIDEBAR_IME_HOOK_IN"
        sidebar_ime_uninstall_hook "$SIDEBAR_IME_HOOK_OUT"
        return 0
    fi
    if [ "$setting" = "restore" ]; then
        sidebar_ime_install_hook "$SIDEBAR_IME_HOOK_IN" "$helper push"
        sidebar_ime_install_hook "$SIDEBAR_IME_HOOK_OUT" "$helper pop"
    else
        sidebar_ime_install_hook "$SIDEBAR_IME_HOOK_IN" "$helper en"
        sidebar_ime_uninstall_hook "$SIDEBAR_IME_HOOK_OUT"
    fi
    return 0
}

sidebar_ime_set_setting()
{
    sidebar_ime_write_setting "$SIDEBAR_IME_OPTION" "$SIDEBAR_IME_STATE_FILE" "$(sidebar_ime_normalize "${1:-}")"
    sidebar_ime_apply
}

# Restore where tmux fires no pane-focus-out: the focused sidebar quitting on
# its own (q).
# $1 = pane id to judge (default: the current client's active pane).
sidebar_ime_leaving()
{
    local helper state
    [ "$(sidebar_ime_setting)" = "restore" ] || return 0
    helper="$(sidebar_ime_helper_path 2>/dev/null || true)"
    [ -n "$helper" ] || return 0
    state="$(tmux display-message -p ${1:+-t "$1"} '#{pane_active}|#{pane_title}' 2>/dev/null || true)"
    [ "$state" = "1|$SIDEBAR_IME_TITLE" ] || return 0
    ("$helper" pop >/dev/null 2>&1 &)
    return 0
}

sidebar_ime_status()
{
    local hook_in="absent" hook_out="absent"
    sidebar_ime_hook_installed "$SIDEBAR_IME_HOOK_IN" && hook_in="installed"
    sidebar_ime_hook_installed "$SIDEBAR_IME_HOOK_OUT" && hook_out="installed"
    printf 'setting=%s backend=%s hook_in=%s hook_out=%s\n' \
        "$(sidebar_ime_setting)" "$(sidebar_ime_backend_name)" "$hook_in" "$hook_out"
}
