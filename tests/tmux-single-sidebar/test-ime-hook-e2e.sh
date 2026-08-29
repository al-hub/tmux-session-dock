#!/usr/bin/env bash
# test-ime-hook-e2e.sh — the IME focus hook end to end on a private tmux server.
#
# Oracle: the English-switch helper runs exactly when a pane titled
# dotfiles-session-sidebar gains focus while a client is attached, never for
# other panes, never on a headless server, and never once the setting is off.
# The helper is a stub that logs its arguments; no real IME is touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TMUX_CONF="$SCRIPT_DIR/tests/fixtures/test-tmux.conf"
BIN="$SCRIPT_DIR/dist/tmux-session-dock"
SOCKET="test-ime-e2e-$$"
TMP="$(mktemp -d)"
LOG="$TMP/helper.log"
CLIENT_PID=""
FEED_PID=""

cleanup() {
    [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null || true
    [ -n "$FEED_PID" ] && kill "$FEED_PID" 2>/dev/null || true
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; echo "--- helper log ---"; cat "$LOG" 2>/dev/null; echo "--- hooks ---"; tmux -L "$SOCKET" show-hooks -g pane-focus-in 2>/dev/null || true; exit 1; }

# Stub helper in a private HOME: the dock finds ~/.local/bin/imemode.exe first.
export HOME="$TMP/home"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/imemode.exe" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$LOG"
STUB
chmod +x "$HOME/.local/bin/imemode.exe"
: > "$LOG"

calls() { grep -c . "$LOG" 2>/dev/null || true; }
wait_calls() {   # wait_calls <expected> <what>
    local i=0
    while [ "$i" -lt 60 ]; do
        [ "$(calls)" -ge "$1" ] && return 0
        sleep 0.05; i=$((i + 1))
    done
    fail "$2: expected >= $1 helper call(s), got $(calls)"
}
settle() { sleep 0.4; }

t() { tmux -L "$SOCKET" "$@"; }

echo "=== [1/7] private server, setting on, hook installed ==="
tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" new-session -d -s main -x 120 -y 40 "sleep 300"
t set-option -g @session-dock-ime on
t run-shell "$BIN --apply-ime-hook"
t show-hooks -g pane-focus-in | grep -qF "$HOME/.local/bin/imemode.exe en" || fail "hook not installed"
[ "$(t show-option -gv focus-events)" = "on" ] || fail "focus-events must be on"
status="$(t run-shell "$BIN --ime-status")"   # via run-shell: the lib talks to the server it runs under
echo "status: $status"
case "$status" in *"hook=installed"*) ;; *) fail "--ime-status must report hook=installed" ;; esac

work="$(t display-message -p '#{pane_id}')"
t split-window -d -h -t main "sleep 300"
sidebar="$(t list-panes -t main -F '#{pane_id}' | grep -v "^$work$" | head -1)"
t select-pane -t "$sidebar" -T dotfiles-session-sidebar
t select-pane -t "$work"
settle

echo "=== [2/7] headless: focus changes fire nothing ==="
t select-pane -t "$sidebar"; t select-pane -t "$work"; t select-pane -t "$sidebar"; t select-pane -t "$work"
settle
[ "$(calls)" = "0" ] || fail "headless server must not run the helper"

echo "=== [3/7] attach a control-mode client (counts as focused) ==="
# Keep the client's stdin open so it stays attached.
mkfifo "$TMP/feed"
sleep 300 > "$TMP/feed" & FEED_PID=$!
tmux -L "$SOCKET" -C attach -t main < "$TMP/feed" > /dev/null 2>&1 & CLIENT_PID=$!
i=0; while [ "$i" -lt 60 ] && [ "$(t list-clients 2>/dev/null | wc -l)" -lt 1 ]; do sleep 0.05; i=$((i + 1)); done
[ "$(t list-clients | wc -l)" -ge 1 ] || fail "client did not attach"
settle
[ "$(calls)" = "0" ] || fail "attach with work pane active must not run the helper (got $(calls))"

echo "=== [4/7] focus into the sidebar pane runs the helper once ==="
t select-pane -t "$sidebar"
wait_calls 1 "first sidebar focus"
settle
[ "$(calls)" = "1" ] || fail "exactly one call expected, got $(calls)"
[ "$(head -1 "$LOG")" = "en" ] || fail "helper must be called with 'en', got '$(head -1 "$LOG")'"

echo "=== [5/7] focus into the work pane runs nothing; back to sidebar runs again ==="
t select-pane -t "$work"; settle
[ "$(calls)" = "1" ] || fail "work pane focus must not run the helper"
t select-pane -t "$sidebar"
wait_calls 2 "second sidebar focus"
settle
[ "$(calls)" = "2" ] || fail "exactly two calls expected, got $(calls)"

echo "=== [6/7] real sidebar pane (title set by the product) triggers too ==="
t select-pane -t "$work"
t kill-pane -t "$sidebar"
win="$(t display-message -p -t main '#{window_id}')"
t set-option -gq @dotfiles_sidebar_enabled 1
t set-option -w -t "$win" @dotfiles_sidebar_managed 1
t run-shell "$BIN --ensure-sidebar-window $win"
i=0; real=""
while [ "$i" -lt 100 ]; do
    real="$(t list-panes -t "$win" -F '#{pane_id}|#{pane_title}' | awk -F '|' '$2=="dotfiles-session-sidebar"{print $1; exit}')"
    [ -n "$real" ] && break
    sleep 0.05; i=$((i + 1))
done
[ -n "$real" ] || fail "product sidebar pane did not appear"
before="$(calls)"
t select-pane -t "$work"; settle
t run-shell "$BIN --focus-sidebar"
wait_calls $((before + 1)) "quick-jump into the real sidebar"

echo "=== [7/7] setting off removes the hook; no more calls ==="
t run-shell "$BIN --ime-set off"
t show-hooks -g pane-focus-in | grep -qF "imemode.exe" && fail "hook must be removed when off"
before="$(calls)"
t select-pane -t "$work"; settle
t select-pane -t "$real"; settle
[ "$(calls)" = "$before" ] || fail "helper ran after the setting was turned off"
[ "$(cat "$HOME/.local/state/dotfiles/tmux-sidebar-ime")" = "off" ] || fail "state file must persist off"

echo "PASS: IME focus hook e2e"
