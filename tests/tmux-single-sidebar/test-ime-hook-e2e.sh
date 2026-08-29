#!/usr/bin/env bash
# test-ime-hook-e2e.sh — the IME focus hooks end to end on a private tmux server.
#
# Oracle: the helper runs exactly when a pane titled dotfiles-session-sidebar
# gains (and, in restore mode, loses) focus while a client is attached -
# whatever moved the focus (select-pane, --focus-sidebar, --smart-pane) -
# never for other panes, never on a headless server, never once the setting
# is off. The helper is a stub imemode.exe that logs its verb; no real IME is
# touched.
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
fail() {
    echo "FAIL: $*"; echo "--- helper log ---"; cat "$LOG" 2>/dev/null
    echo "--- hooks ---"; tmux -L "$SOCKET" show-hooks -g pane-focus-in 2>/dev/null || true; tmux -L "$SOCKET" show-hooks -g pane-focus-out 2>/dev/null || true
    exit 1
}

# Stub Windows helper in a private HOME: the dock finds ~/.local/bin/imemode.exe first.
export HOME="$TMP/home"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/imemode.exe" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$LOG"
STUB
chmod +x "$HOME/.local/bin/imemode.exe"
: > "$LOG"

calls() { grep -c . "$LOG" 2>/dev/null || true; }
last_call() { tail -1 "$LOG" 2>/dev/null || true; }
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
status() { t run-shell "$BIN --ime-status"; }

echo "=== [1/8] private server, setting on, hook installed ==="
tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" new-session -d -s main -x 120 -y 40 "sleep 300"
t set-option -g @session-dock-ime on
t run-shell "$BIN --apply-ime-hook"
t show-hooks -g pane-focus-in | grep -qF "tmux-session-dock-ime en" || fail "focus-in hook not installed"
[ "$(t show-option -gv focus-events)" = "on" ] || fail "focus-events must be on"
echo "status: $(status)"
case "$(status)" in *"hook_in=installed hook_out=absent"*) ;; *) fail "status must report hook_in only" ;; esac

work="$(t display-message -p '#{pane_id}')"
t split-window -d -h -t main "sleep 300"
sidebar="$(t list-panes -t main -F '#{pane_id}' | grep -v "^$work$" | head -1)"
t select-pane -t "$sidebar" -T dotfiles-session-sidebar
t select-pane -t "$work"
settle

echo "=== [2/8] headless: focus changes fire nothing ==="
t select-pane -t "$sidebar"; t select-pane -t "$work"; t select-pane -t "$sidebar"; t select-pane -t "$work"
settle
[ "$(calls)" = "0" ] || fail "headless server must not run the helper"

echo "=== [3/8] attach a control-mode client (counts as focused) ==="
mkfifo "$TMP/feed"
sleep 300 > "$TMP/feed" & FEED_PID=$!
tmux -L "$SOCKET" -C attach -t main < "$TMP/feed" > /dev/null 2>&1 & CLIENT_PID=$!
i=0; while [ "$i" -lt 60 ] && [ "$(t list-clients 2>/dev/null | wc -l)" -lt 1 ]; do sleep 0.05; i=$((i + 1)); done
[ "$(t list-clients | wc -l)" -ge 1 ] || fail "client did not attach"
settle
[ "$(calls)" = "0" ] || fail "attach with work pane active must not run the helper (got $(calls))"

echo "=== [4/8] mode on: sidebar focus -> en once; work pane -> nothing ==="
t select-pane -t "$sidebar"
wait_calls 1 "first sidebar focus"; settle
[ "$(calls)" = "1" ] || fail "exactly one call expected, got $(calls)"
[ "$(last_call)" = "en" ] || fail "helper must be called with 'en', got '$(last_call)'"
t select-pane -t "$work"; settle
[ "$(calls)" = "1" ] || fail "leaving in mode on must not run the helper"

echo "=== [5/8] mode restore: focus in -> push, focus out -> pop ==="
t run-shell "$BIN --ime-set restore"
case "$(status)" in *"setting=restore"*"hook_in=installed hook_out=installed"*) ;; *) fail "restore status: $(status)" ;; esac
before="$(calls)"
t select-pane -t "$sidebar"
wait_calls $((before + 1)) "restore: sidebar focus"; settle
[ "$(last_call)" = "push" ] || fail "restore: focus-in must push, got '$(last_call)'"
t select-pane -t "$work"
wait_calls $((before + 2)) "restore: leaving sidebar"; settle
[ "$(last_call)" = "pop" ] || fail "restore: focus-out must pop, got '$(last_call)'"
[ "$(calls)" = "$((before + 2))" ] || fail "restore round trip must be exactly push+pop"

echo "=== [5b/8] Enter-style session switch: sidebar -> other session's sidebar keeps English ==="
t new-session -d -s other -x 120 -y 40 "sleep 300"
t split-window -d -h -t other "sleep 300"
other_side="$(t list-panes -t other -F '#{pane_id}' | tail -1)"
t select-pane -t "$other_side" -T dotfiles-session-sidebar
t select-pane -t "$other_side"             # other's active pane is its sidebar (no client there: no hook)
other_work="$(t list-panes -t other -F '#{pane_id}' | head -1)"
t select-pane -t "$sidebar"
wait_calls $((before + 3)) "back into the sidebar before switching"; settle
[ "$(last_call)" = "push" ] || fail "re-entry must push"
before="$(calls)"
t switch-client -t other                   # lands on other's sidebar: focus-in (push) then focus-out (pop)
sleep 1.0
[ "$(last_call)" = "push" ] || fail "sidebar -> sidebar switch must end with push, got '$(last_call)'"
[ "$(calls)" = "$((before + 1))" ] || fail "sidebar -> sidebar switch must make exactly one call (push), got $(( $(calls) - before ))"
t select-pane -t "$other_work"
wait_calls $((before + 2)) "leaving other's sidebar"; settle
[ "$(last_call)" = "pop" ] || fail "leaving the other sidebar must pop, got '$(last_call)'"
t switch-client -t main; t select-pane -t "$work"; settle
t kill-session -t other; settle

echo "=== [6/8] real sidebar pane (title set by the product): quick-jump in/out ==="
t select-pane -t "$work"; settle
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
t select-pane -t "$work"; settle
before="$(calls)"
t run-shell "$BIN --focus-sidebar"
wait_calls $((before + 1)) "quick-jump into the real sidebar"; settle
[ "$(last_call)" = "push" ] || fail "quick-jump must push, got '$(last_call)'"
t run-shell "$BIN --focus-sidebar"      # smart return -> focus-out hook pops
wait_calls $((before + 2)) "leaving via quick-jump"; settle
[ "$(last_call)" = "pop" ] || fail "leaving must pop, got '$(last_call)'"

echo "=== [7/8] Alt+Left between work panes moves without touching the IME; into the sidebar it pushes ==="
w2="$(t split-window -h -d -t "$work" -P -F '#{pane_id}' "sleep 300")"   # layout: sidebar | work | w2
t select-pane -t "$w2"; settle
before="$(calls)"
t run-shell "$BIN --smart-pane L"
settle
[ "$(t display-message -p -t main '#{pane_id}')" = "$work" ] || fail "Left from w2 must land on w1, got $(t display-message -p -t main '#{pane_id}')"
[ "$(calls)" = "$before" ] || fail "moving between work panes must not call the helper"
t run-shell "$BIN --smart-pane L"
wait_calls $((before + 1)) "Left from w1 into the sidebar"; settle
[ "$(t display-message -p -t main '#{pane_id}')" = "$real" ] || fail "Left from w1 must land on the sidebar"
[ "$(last_call)" = "push" ] || fail "entering the sidebar via Alt+Left must push"
t select-pane -t "$work"
wait_calls $((before + 2)) "leaving the sidebar"; settle
t kill-pane -t "$w2"; settle

echo "=== [8/8] setting off removes both hooks; no more calls ==="
t run-shell "$BIN --ime-set off"
t show-hooks -g pane-focus-in  | grep -qF "tmux-session-dock-ime" && fail "focus-in hook must be removed when off"
t show-hooks -g pane-focus-out | grep -qF "tmux-session-dock-ime" && fail "focus-out hook must be removed when off"
before="$(calls)"
t select-pane -t "$real"; settle
t select-pane -t "$work"; settle
[ "$(calls)" = "$before" ] || fail "helper ran after the setting was turned off"
[ "$(cat "$HOME/.local/state/dotfiles/tmux-sidebar-ime")" = "off" ] || fail "state file must persist off"

echo "PASS: IME focus hooks e2e"
