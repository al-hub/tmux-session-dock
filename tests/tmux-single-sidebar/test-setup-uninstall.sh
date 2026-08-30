#!/usr/bin/env bash
# ==============================================================================
# tests/tmux-single-sidebar/test-setup-uninstall.sh
# `setup.sh uninstall` must detach the RUNNING tmux server from the dock (hooks,
# key bindings, dock panes, hub session, options) while keeping the user's
# sessions and work panes. Ending the server is opt-in: --kill-server asks for
# confirmation and is ignored without a TTY unless --yes is given.
# ==============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$SCRIPT_DIR/setup.sh"
BIN="$SCRIPT_DIR/dist/tmux-session-dock"
PLUGIN_ENTRY="$SCRIPT_DIR/session-dock.tmux"
SOCKET="test-setup-uninstall-$$"
SOCKET_PATH="/tmp/tmux-$(id -u)/$SOCKET"
TMP="$(mktemp -d)"
cleanup() { tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*"; tmux -L "$SOCKET" list-panes -a -F "#{session_name} #{pane_id} #{pane_title} dead=#{pane_dead} sub=#{@dotfiles_sidebar_subpane} side=#{@dotfiles_sidebar_pane}" 2>/dev/null; tmux -L "$SOCKET" list-keys 2>/dev/null | grep -E "tmux-session-dock|tmux-subpane-picker|tmux-theme-picker|tmux-help-viewer|tmux-command-palette" | cut -c1-150; tail -4 "$TMP"/uninstall*.log 2>/dev/null; exit 1; }
t() { tmux -L "$SOCKET" "$@"; }

# Sandbox every path setup.sh touches; plain `tmux` inside setup.sh follows $TMUX.
export HOME="$TMP/home"; mkdir -p "$HOME/.local/bin"
export TMUX_DOCK_BIN_DIR="$TMP/bin" TMUX_CONF="$TMP/tmux.conf" TMUX_DOCK_INSTALL_DIR="$TMP/install"
export XDG_STATE_HOME="$TMP/state" XDG_CACHE_HOME="$TMP/cache" XDG_CONFIG_HOME="$TMP/config"
mkdir -p "$TMUX_DOCK_BIN_DIR"; ln -s "$BIN" "$TMUX_DOCK_BIN_DIR/tmux-session-dock"
printf 'set -g status off\n# >>> tmux-session-dock configuration >>>\nset -g @session-dock-dotfiles-mode "on"\nrun-shell "bash %s"\n# <<< tmux-session-dock configuration <<<\n' "$PLUGIN_ENTRY" > "$TMUX_CONF"

echo "=== [1/4] a server with user sessions, dock hooks, keys, dock panes and the hub ==="
tmux -L "$SOCKET" -f /dev/null new-session -d -s keep -n main -x 120 -y 40 'sleep 300'
t new-session -d -s keep-too 'sleep 300'
export TMUX="$SOCKET_PATH,0,0"
win="$(t display-message -p -t keep:main '#{window_id}')"
t set-option -gq @dotfiles_sidebar_enabled 1
t set-option -w -t "$win" @dotfiles_sidebar_managed 1
t run-shell "$BIN --ensure-sidebar-window $win"
t run-shell "bash '$PLUGIN_ENTRY'"
t set-option -gq @session-dock-subpane-count 2
sidebar="$(t list-panes -t "$win" -F '#{pane_id}|#{pane_title}' | awk -F '|' '$2=="dotfiles-session-sidebar"{print $1; exit}')"
[ -n "$sidebar" ] || fail "no sidebar provisioned"
t run-shell "env TMUX_PANE=$sidebar $BIN --toggle-subpane"
i=0; while [ "$i" -lt 60 ] && [ "$(t list-panes -a -F '#{@dotfiles_sidebar_subpane}' | grep -c 1)" -lt 2 ]; do sleep 0.05; i=$((i + 1)); done
work="$(t list-panes -t "$win" -F '#{pane_id}|#{pane_title}|#{@dotfiles_sidebar_subpane}' | awk -F '|' '$2!="dotfiles-session-sidebar" && $3!="1"{print $1; exit}')"
[ -n "$work" ] || fail "no work pane"
t show-hooks -g | grep -q "tmux-session-dock" || fail "precondition: dock hooks installed"
t list-keys | grep -q "tmux-session-dock" || fail "precondition: dock keys bound"
t has-session -t "=dotfiles-subpane-hub" 2>/dev/null || fail "precondition: hub session"
echo "PASS: fixture ready (sidebar=$sidebar work=$work)"

echo "=== [2/4] plain uninstall keeps the server and the user's sessions ==="
bash "$SETUP" uninstall </dev/null >"$TMP/uninstall.log" 2>&1 || fail "setup.sh uninstall failed: $(tail -3 "$TMP/uninstall.log")"
t has-session -t keep 2>/dev/null || fail "server/session 'keep' must survive a plain uninstall"
t has-session -t keep-too 2>/dev/null || fail "session 'keep-too' must survive"
t list-panes -t keep:main -F '#{pane_id}' | grep -qx "$work" || fail "work pane must survive"
[ "$(t list-panes -a -F '#{pane_title}' | grep -c 'dotfiles-session-sidebar\|dotfiles-sidebar-subpane')" -eq 0 ] || fail "dock panes must be gone"
t has-session -t "=dotfiles-subpane-hub" 2>/dev/null && fail "hub session must be gone"
for h in $(t show-hooks -g | awk '{print $1}' | sed 's/\[.*//' | sort -u) pane-focus-in pane-focus-out; do
    t show-hooks -g "$h" 2>/dev/null | grep -q "tmux-session-dock" && fail "hook $h still references the dock"
done
t list-keys | grep -qE "tmux-session-dock|tmux-subpane-picker|tmux-theme-picker|tmux-help-viewer|tmux-command-palette" && fail "dock key bindings must be unbound"
t show-options -g | grep -qE '^@(dotfiles_|session-dock|sidebar_)' && fail "dock options must be unset"
grep -q "tmux-session-dock" "$TMUX_CONF" 2>/dev/null && fail "snippet must be removed from the conf"
[ ! -e "$TMUX_DOCK_BIN_DIR/tmux-session-dock" ] || fail "symlink must be removed"
grep -q "sessions are untouched" "$TMP/uninstall.log" || fail "uninstall must say the sessions were kept"
echo "PASS: detached, sessions kept"

echo "=== [3/4] --kill-server without a TTY and without --yes is refused ==="
bash "$SETUP" uninstall --kill-server </dev/null >"$TMP/uninstall2.log" 2>&1 || true
t has-session -t keep 2>/dev/null || fail "--kill-server must not end the server when nobody can confirm"
grep -q "no interactive terminal" "$TMP/uninstall2.log" || fail "must explain why --kill-server was ignored"
echo "PASS: refused without confirmation"

echo "=== [4/4] --kill-server --yes ends the server ==="
bash "$SETUP" uninstall --kill-server --yes </dev/null >"$TMP/uninstall3.log" 2>&1 || true
if t has-session -t keep 2>/dev/null; then fail "--kill-server --yes must end the tmux server"; fi
grep -q "tmux server terminated" "$TMP/uninstall3.log" || fail "must report the termination"
echo "PASS: explicit kill honoured"

echo "PASS: setup.sh uninstall keeps sessions by default"
