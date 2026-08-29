#!/usr/bin/env bash
# ==============================================================================
# sidebar_ime.sh - IME focus hooks for tmux-session-dock
#
# Goal: the sidebar's letter shortcuts (j/k/c/r/d/o/h/a/s/p/q) must work even
# when the user types Korean (or another CJK language) in the work panes.
# Whenever the sidebar pane gains focus, the OS input method is switched to
# English/alphanumeric; optionally the previous mode is restored on leave.
#
# Settings (tmux option > persisted state file > default):
#   @session-dock-ime          off | on | restore     (default off)
#       on       sidebar focus -> English; leaving restores nothing
#       restore  sidebar focus -> remember mode, English; leaving -> restore
#   @session-dock-ime-trigger  any | keybind          (default any)
#       any      every focus route (mouse, keys, session switch, attach)
#       keybind  only the dock's own commands (Alt+s, Prefix+s, Alt+arrows)
#
# Mechanism: tmux `pane-focus-in` / `pane-focus-out` hooks whose pane_title
# compare runs inside tmux (`if-shell -F`, no process, ~0.1 ms per event) and
# run the one-shot helper `tmux-session-dock-ime` only for the sidebar pane.
# Hooks need `focus-events on` and an attached focused client; headless
# servers (tests, CI) never fire them. In `keybind` mode the focus-in hook is
# not installed; the dock commands call the helper after landing on the
# sidebar instead. The focus-out hook (restore) is used in both trigger modes.
# ==============================================================================
set -euo pipefail

SIDEBAR_IME_OPTION="@session-dock-ime"
SIDEBAR_IME_TRIGGER_OPTION="@session-dock-ime-trigger"
SIDEBAR_IME_HOOK_IN="pane-focus-in"
SIDEBAR_IME_HOOK_OUT="pane-focus-out"
SIDEBAR_IME_TITLE="dotfiles-session-sidebar"
SIDEBAR_IME_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles"
SIDEBAR_IME_STATE_FILE="$SIDEBAR_IME_STATE_DIR/tmux-sidebar-ime"
SIDEBAR_IME_TRIGGER_STATE_FILE="$SIDEBAR_IME_STATE_DIR/tmux-sidebar-ime-trigger"

sidebar_ime_normalize()
{
    case "${1:-}" in
        restore) echo "restore" ;;
        on|1|true|yes|english) echo "on" ;;
        *) echo "off" ;;
    esac
}

sidebar_ime_normalize_trigger()
{
    case "${1:-}" in
        keybind|key|keys|bind) echo "keybind" ;;
        *) echo "any" ;;
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

sidebar_ime_trigger()
{
    sidebar_ime_normalize_trigger "$(sidebar_ime_read_setting "$SIDEBAR_IME_TRIGGER_OPTION" "$SIDEBAR_IME_TRIGGER_STATE_FILE")"
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

# Reconcile both hooks with the current settings. Safe to call any time.
sidebar_ime_apply()
{
    local setting trigger helper
    setting="$(sidebar_ime_setting)"
    trigger="$(sidebar_ime_trigger)"
    helper="$(sidebar_ime_helper_path 2>/dev/null || true)"
    if [ "$setting" = "off" ] || [ -z "$helper" ] || ! sidebar_ime_available; then
        sidebar_ime_uninstall_hook "$SIDEBAR_IME_HOOK_IN"
        sidebar_ime_uninstall_hook "$SIDEBAR_IME_HOOK_OUT"
        return 0
    fi
    if [ "$trigger" = "any" ]; then
        if [ "$setting" = "restore" ]; then
            sidebar_ime_install_hook "$SIDEBAR_IME_HOOK_IN" "$helper push"
        else
            sidebar_ime_install_hook "$SIDEBAR_IME_HOOK_IN" "$helper en"
        fi
    else
        sidebar_ime_uninstall_hook "$SIDEBAR_IME_HOOK_IN"
    fi
    if [ "$setting" = "restore" ]; then
        sidebar_ime_install_hook "$SIDEBAR_IME_HOOK_OUT" "$helper pop"
    else
        sidebar_ime_uninstall_hook "$SIDEBAR_IME_HOOK_OUT"
    fi
    return 0
}

sidebar_ime_set_setting()
{
    sidebar_ime_write_setting "$SIDEBAR_IME_OPTION" "$SIDEBAR_IME_STATE_FILE" "$(sidebar_ime_normalize "${1:-}")"
    sidebar_ime_apply
}

sidebar_ime_set_trigger()
{
    sidebar_ime_write_setting "$SIDEBAR_IME_TRIGGER_OPTION" "$SIDEBAR_IME_TRIGGER_STATE_FILE" "$(sidebar_ime_normalize_trigger "${1:-}")"
    sidebar_ime_apply
}

# Called by the dock's own focus commands after they may have landed on the
# sidebar. Only acts in `keybind` trigger mode; `any` mode is hook-driven.
sidebar_ime_keybind_landed()
{
    local setting helper title
    setting="$(sidebar_ime_setting)"
    [ "$setting" != "off" ] || return 0
    [ "$(sidebar_ime_trigger)" = "keybind" ] || return 0
    helper="$(sidebar_ime_helper_path 2>/dev/null || true)"
    [ -n "$helper" ] || return 0
    title="$(tmux display-message -p '#{pane_title}' 2>/dev/null || true)"
    [ "$title" = "$SIDEBAR_IME_TITLE" ] || return 0
    if [ "$setting" = "restore" ]; then
        ("$helper" push >/dev/null 2>&1 &)
    else
        ("$helper" en >/dev/null 2>&1 &)
    fi
    return 0
}

sidebar_ime_status()
{
    local hook_in="absent" hook_out="absent"
    sidebar_ime_hook_installed "$SIDEBAR_IME_HOOK_IN" && hook_in="installed"
    sidebar_ime_hook_installed "$SIDEBAR_IME_HOOK_OUT" && hook_out="installed"
    printf 'setting=%s trigger=%s backend=%s hook_in=%s hook_out=%s\n' \
        "$(sidebar_ime_setting)" "$(sidebar_ime_trigger)" "$(sidebar_ime_backend_name)" "$hook_in" "$hook_out"
}
