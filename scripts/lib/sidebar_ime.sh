#!/usr/bin/env bash
# ==============================================================================
# sidebar_ime.sh - IME focus hook for tmux-session-dock
#
# Goal: the sidebar's letter shortcuts (j/k/c/r/d/o/h/a/s/p/q) must work even
# when the user types Korean (or another CJK language) in the work panes.
# Whenever the sidebar pane gains focus, the OS input method is switched to
# English/alphanumeric. Leaving the sidebar restores nothing: the user keeps
# toggling 한/영 in the work pane as usual.
#
# Mechanism: ONE tmux `pane-focus-in` hook. tmux evaluates a format compare on
# the pane title inside the server (no process, ~0.1 ms per focus event) and
# runs a one-shot helper only when the sidebar pane is the one gaining focus.
# The hook needs `focus-events on` and an attached, focused client; headless
# servers (test suites, CI) never fire it, so nothing there touches an IME.
#
# Opt-in: `set -g @session-dock-ime on` in tmux.conf, or the `S` settings popup.
# Precedence: tmux option (if set) > persisted state file > off.
# ==============================================================================
set -euo pipefail

SIDEBAR_IME_OPTION="@session-dock-ime"
SIDEBAR_IME_HOOK="pane-focus-in"
SIDEBAR_IME_TITLE="dotfiles-session-sidebar"
SIDEBAR_IME_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/tmux-sidebar-ime"

sidebar_ime_normalize()
{
    case "${1:-}" in
        on|1|true|yes|english) echo "on" ;;
        *) echo "off" ;;
    esac
}

# Prints "<backend>|<command that switches the current IME to English>".
# Returns 1 (prints nothing) when no supported helper exists on this host.
sidebar_ime_backend()
{
    local exe="$HOME/.local/bin/imemode.exe"
    if [ -x "$exe" ]; then
        echo "imemode|$exe en"
    elif command -v imemode.exe >/dev/null 2>&1; then
        echo "imemode|imemode.exe en"
    elif command -v fcitx5-remote >/dev/null 2>&1; then
        echo "fcitx5|fcitx5-remote -c"
    elif command -v fcitx-remote >/dev/null 2>&1; then
        echo "fcitx|fcitx-remote -c"
    elif command -v ibus >/dev/null 2>&1; then
        echo "ibus|ibus engine xkb:us::eng"
    elif command -v im-select >/dev/null 2>&1; then
        echo "im-select|im-select com.apple.keylayout.ABC"
    elif command -v macism >/dev/null 2>&1; then
        echo "macism|macism com.apple.keylayout.ABC"
    else
        return 1
    fi
}

sidebar_ime_backend_name()
{
    local backend
    backend="$(sidebar_ime_backend 2>/dev/null || true)"
    echo "${backend%%|*}"
}

sidebar_ime_english_cmd()
{
    local backend
    backend="$(sidebar_ime_backend 2>/dev/null || true)"
    [ -n "$backend" ] || return 1
    echo "${backend#*|}"
}

sidebar_ime_setting()
{
    local value=""
    value="$(tmux show-option -gqv "$SIDEBAR_IME_OPTION" 2>/dev/null || true)"
    if [ -z "$value" ] && [ -r "$SIDEBAR_IME_STATE_FILE" ]; then
        IFS= read -r value < "$SIDEBAR_IME_STATE_FILE" || true
    fi
    sidebar_ime_normalize "$value"
}

sidebar_ime_hook_command()
{
    # $1 = English-switch command. The title compare runs inside tmux; only a
    # match forks the helper. run-shell -b keeps the focus change non-blocking.
    printf "if-shell -F '#{==:#{pane_title},%s}' 'run-shell -b \"%s\"'" "$SIDEBAR_IME_TITLE" "$1"
}

# Index of our entry in the pane-focus-in hook array, or nothing.
# tmux 3.2a omits pane-focus-in from a bare `show-hooks -g`; name it explicitly.
sidebar_ime_hook_index()
{
    tmux show-hooks -g "$SIDEBAR_IME_HOOK" 2>/dev/null | awk -v hook="$SIDEBAR_IME_HOOK" -v marker="pane_title},$SIDEBAR_IME_TITLE}" '
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
    [ -n "$(sidebar_ime_hook_index)" ]
}

sidebar_ime_uninstall_hook()
{
    local index
    index="$(sidebar_ime_hook_index)"
    [ -n "$index" ] || return 0
    tmux set-hook -gu "${SIDEBAR_IME_HOOK}[$index]" 2>/dev/null || true
}

sidebar_ime_install_hook()
{
    local cmd hook
    cmd="$(sidebar_ime_english_cmd)" || return 1
    hook="$(sidebar_ime_hook_command "$cmd")"
    # Same helper already hooked: nothing to do.
    if tmux show-hooks -g "$SIDEBAR_IME_HOOK" 2>/dev/null | grep -F "${SIDEBAR_IME_HOOK}[" | grep -F "pane_title},$SIDEBAR_IME_TITLE}" | grep -qF -- "$cmd"; then
        return 0
    fi
    sidebar_ime_uninstall_hook
    tmux set-option -g focus-events on 2>/dev/null || true
    # Append so a user's own pane-focus-in hooks survive.
    tmux set-hook -ga "$SIDEBAR_IME_HOOK" "$hook" 2>/dev/null || true
}

# Reconcile the hook with the current setting. Safe to call any time.
sidebar_ime_apply()
{
    if [ "$(sidebar_ime_setting)" = "on" ]; then
        sidebar_ime_install_hook || true
    else
        sidebar_ime_uninstall_hook
    fi
    return 0
}

sidebar_ime_set_setting()
{
    local value
    value="$(sidebar_ime_normalize "${1:-}")"
    tmux set-option -gq "$SIDEBAR_IME_OPTION" "$value" 2>/dev/null || true
    if mkdir -p "$(dirname "$SIDEBAR_IME_STATE_FILE")" 2>/dev/null; then
        printf '%s\n' "$value" > "$SIDEBAR_IME_STATE_FILE" 2>/dev/null || true
    fi
    sidebar_ime_apply
}

sidebar_ime_status()
{
    local backend hook="absent"
    backend="$(sidebar_ime_backend_name)"
    sidebar_ime_hook_installed && hook="installed"
    printf 'setting=%s backend=%s hook=%s\n' "$(sidebar_ime_setting)" "${backend:-none}" "$hook"
}
