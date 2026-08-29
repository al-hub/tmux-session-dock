#!/usr/bin/env bash
# test-ime-unit.sh — scripts/lib/sidebar_ime.sh + scripts/tmux-session-dock-ime
# Setting normalization and precedence, hook strings, hook install/uninstall
# per mode on a private tmux server (foreign hooks survive), the leaving guard,
# and the helper's push/pop state with a fcitx5 stub.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$SCRIPT_DIR/scripts/tmux-session-dock-ime"
TMP="$(mktemp -d)"
SOCKET="test-ime-unit-$$"
cleanup() {
    command tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }

export HOME="$TMP/home"
mkdir -p "$HOME/.local/bin" "$TMP/bin" "$TMP/tools"
# Restricted PATH for detection tests: stub helpers plus only the tools needed,
# so a real fcitx/ibus on the host cannot leak in.
for tool in bash chmod rm mv mkdir cat grep awk sed sleep dirname id tmux cut readlink tr tail head; do
    ln -s "$(command -v "$tool")" "$TMP/tools/$tool"
done
STUB_PATH="$TMP/bin:$TMP/tools"
ORIG_PATH="$PATH"
CALLS="$TMP/calls.log"; : > "$CALLS"
stub() {   # stub <name> [stdout]
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$CALLS" "${2:+echo \"$2\"}" > "$TMP/bin/$1"
    chmod +x "$TMP/bin/$1"
}

source "$SCRIPT_DIR/scripts/lib/sidebar_ime.sh"

echo "=== [1/7] normalize ==="
[ "$(sidebar_ime_normalize on)" = "on" ] || fail "normalize on"
[ "$(sidebar_ime_normalize restore)" = "restore" ] || fail "normalize restore"
[ "$(sidebar_ime_normalize 1)" = "on" ] || fail "normalize 1"
[ "$(sidebar_ime_normalize '')" = "off" ] || fail "normalize empty"
[ "$(sidebar_ime_normalize garbage)" = "off" ] || fail "normalize garbage"

echo "=== [2/7] helper backend detection order ==="
export PATH="$STUB_PATH"
[ "$("$HELPER" backend)" = "none" ] || fail "no helper on PATH must be none"
[ "$(sidebar_ime_backend_name)" = "none" ] || fail "lib backend none"
sidebar_ime_available && fail "not available without helper"
stub ibus
[ "$("$HELPER" backend)" = "ibus" ] || fail "ibus"
stub fcitx-remote
[ "$("$HELPER" backend)" = "fcitx" ] || fail "fcitx beats ibus"
stub fcitx5-remote
[ "$("$HELPER" backend)" = "fcitx5" ] || fail "fcitx5 beats fcitx"
stub imemode.exe; mv "$TMP/bin/imemode.exe" "$HOME/.local/bin/imemode.exe"
[ "$("$HELPER" backend)" = "imemode" ] || fail "imemode in ~/.local/bin wins"
[ "$(sidebar_ime_backend_name)" = "imemode" ] || fail "lib sees imemode"
sidebar_ime_available || fail "available with imemode"

echo "=== [3/7] helper delegates every verb to imemode.exe ==="
: > "$CALLS"
"$HELPER" en; "$HELPER" push; "$HELPER" pop; "$HELPER" get
[ "$(tr '\n' ' ' < "$CALLS")" = "imemode.exe en imemode.exe push imemode.exe pop imemode.exe get " ] || fail "delegation: $(cat "$CALLS")"

echo "=== [4/7] helper push/pop keeps state for fcitx5 ==="
rm -f "$HOME/.local/bin/imemode.exe"
export TMUX_SESSION_DOCK_IME_STATE="$TMP/ime.state"
cat > "$TMP/bin/fcitx5-remote" <<STUB
#!/usr/bin/env bash
echo "fcitx5-remote \$*" >> "$CALLS"
[ \$# -eq 0 ] && cat "$TMP/fcitx.mode"
exit 0
STUB
chmod +x "$TMP/bin/fcitx5-remote"
echo 2 > "$TMP/fcitx.mode"          # 2 = Korean active
: > "$CALLS"
"$HELPER" push
[ "$(cat "$TMP/ime.state")" = "2" ] || fail "push must save state 2"
grep -q "fcitx5-remote -c" "$CALLS" || fail "push must switch to English"
echo 1 > "$TMP/fcitx.mode"          # now English (as the IME would report)
"$HELPER" push                      # re-entry: must NOT overwrite the saved 2
[ "$(cat "$TMP/ime.state")" = "2" ] || fail "nested push must keep the original state"
: > "$CALLS"
"$HELPER" pop
grep -q "fcitx5-remote -o" "$CALLS" || fail "pop must restore Korean (-o)"
[ ! -e "$TMP/ime.state" ] || fail "pop must clear state"
: > "$CALLS"
"$HELPER" pop
[ ! -s "$CALLS" ] || fail "pop without state must do nothing"
echo 1 > "$TMP/fcitx.mode"; "$HELPER" push; : > "$CALLS"; "$HELPER" pop
grep -q "fcitx5-remote -c" "$CALLS" || fail "pop after English push must set English (-c)"
echo "--- pop is skipped while a focused client still shows a sidebar (sidebar -> sidebar move) ---"
cat > "$TMP/bin/tmux" <<STUB
#!/usr/bin/env bash
[ "\$1" = "list-clients" ] && cat "$TMP/clients"
exit 0
STUB
chmod +x "$TMP/bin/tmux"
echo 2 > "$TMP/fcitx.mode"; "$HELPER" push
echo "attached,focused,UTF-8|dotfiles-session-sidebar" > "$TMP/clients"
: > "$CALLS"; TMUX=fake "$HELPER" pop
grep -q "fcitx5-remote -o" "$CALLS" && fail "pop must be skipped while a focused client shows a sidebar"
[ "$(cat "$TMP/ime.state")" = "2" ] || fail "skipped pop must keep the remembered state"
echo "attached,focused,UTF-8|LAPTOP" > "$TMP/clients"
: > "$CALLS"; TMUX=fake "$HELPER" pop
grep -q "fcitx5-remote -o" "$CALLS" || fail "pop must restore once the focused client shows a work pane"
echo 2 > "$TMP/fcitx.mode"; "$HELPER" push
echo "attached,focused,UTF-8|dotfiles-session-sidebar" > "$TMP/clients"
: > "$CALLS"; "$HELPER" pop        # no \$TMUX: not running under a tmux hook, no client check
grep -q "fcitx5-remote -o" "$CALLS" || fail "pop outside tmux must not consult clients"
rm -f "$TMP/bin/tmux"
unset TMUX_SESSION_DOCK_IME_STATE
rm -f "$TMP/bin"/*
stub imemode.exe; mv "$TMP/bin/imemode.exe" "$HOME/.local/bin/imemode.exe"
export PATH="$ORIG_PATH"

echo "=== [5/7] hook command string ==="
expected="if-shell -F '#{==:#{pane_title},dotfiles-session-sidebar}' 'run-shell -b \"/x/tmux-session-dock-ime push\"'"
[ "$(sidebar_ime_hook_command '/x/tmux-session-dock-ime push')" = "$expected" ] || fail "hook string"

echo "=== [6/7] settings precedence + hooks per mode (private server) ==="
tmux() { command tmux -L "$SOCKET" "$@"; }
command tmux -L "$SOCKET" -f /dev/null new-session -d -s unit -x 80 -y 24 "sleep 120"
[ "$(sidebar_ime_setting)" = "off" ] || fail "default off"
mkdir -p "$SIDEBAR_IME_STATE_DIR"; echo restore > "$SIDEBAR_IME_STATE_FILE"
[ "$(sidebar_ime_setting)" = "restore" ] || fail "state file restore"
tmux set-option -gq "$SIDEBAR_IME_OPTION" off
[ "$(sidebar_ime_setting)" = "off" ] || fail "tmux option overrides state file"
tmux set-option -gu "$SIDEBAR_IME_OPTION"
rm -f "$SIDEBAR_IME_STATE_FILE"

helper_path="$(sidebar_ime_helper_path)"
[ -x "$helper_path" ] || fail "helper path"
count_in()  { tmux show-hooks -g pane-focus-in  | grep -c '^pane-focus-in\['  || true; }
count_out() { tmux show-hooks -g pane-focus-out | grep -c '^pane-focus-out\[' || true; }
tmux set-hook -g pane-focus-in "display-message foreign-in"
tmux set-hook -g pane-focus-out "display-message foreign-out"

sidebar_ime_apply
[ "$(count_in)" = "1" ] && [ "$(count_out)" = "1" ] || fail "off: no hooks added"

sidebar_ime_set_setting on
[ "$(count_in)" = "2" ] || fail "on: focus-in hook appended"
[ "$(count_out)" = "1" ] || fail "on: no focus-out hook"
tmux show-hooks -g pane-focus-in | grep -qF "$helper_path en" || fail "on: focus-in runs helper en"
[ "$(tmux show-option -gv focus-events)" = "on" ] || fail "focus-events on"
[ "$(cat "$SIDEBAR_IME_STATE_FILE")" = "on" ] || fail "state file on"

sidebar_ime_set_setting restore
[ "$(count_in)" = "2" ] || fail "restore: still one of ours in"
[ "$(count_out)" = "2" ] || fail "restore: focus-out hook appended"
tmux show-hooks -g pane-focus-in  | grep -qF "$helper_path push" || fail "restore: focus-in runs push"
tmux show-hooks -g pane-focus-in  | grep -qF "$helper_path en" && fail "restore: en hook must be replaced"
tmux show-hooks -g pane-focus-out | grep -qF "$helper_path pop" || fail "restore: focus-out runs pop"
sidebar_ime_apply; sidebar_ime_apply
[ "$(count_in)" = "2" ] && [ "$(count_out)" = "2" ] || fail "re-apply must not duplicate"
[ "$(sidebar_ime_status)" = "setting=restore backend=imemode hook_in=installed hook_out=installed" ] || fail "status: $(sidebar_ime_status)"

tmux show-hooks -g pane-focus-in | grep -qF "foreign-in" || fail "foreign focus-in hook lost"

sidebar_ime_set_setting off
[ "$(count_in)" = "1" ] && [ "$(count_out)" = "1" ] || fail "off: both of ours removed"
tmux show-hooks -g pane-focus-in  | grep -qF "foreign-in"  || fail "foreign in lost on uninstall"
tmux show-hooks -g pane-focus-out | grep -qF "foreign-out" || fail "foreign out lost on uninstall"
[ "$(sidebar_ime_status)" = "setting=off backend=imemode hook_in=absent hook_out=absent" ] || fail "status off: $(sidebar_ime_status)"

# helper gone: on-setting installs nothing, no error
rm -f "$HOME/.local/bin/imemode.exe"; export PATH="$STUB_PATH"
sidebar_ime_set_setting restore
[ "$(count_in)" = "1" ] && [ "$(count_out)" = "1" ] || fail "no backend: nothing installed"
export PATH="$ORIG_PATH"
stub imemode.exe; mv "$TMP/bin/imemode.exe" "$HOME/.local/bin/imemode.exe"

echo "=== [7/7] leaving: pop only for a focused sidebar in restore mode ==="
sidebar_ime_set_setting restore
tmux select-pane -T work; : > "$CALLS"
sidebar_ime_leaving; sleep 0.3
[ ! -s "$CALLS" ] || fail "leaving from a work pane must not pop"
tmux select-pane -T dotfiles-session-sidebar; : > "$CALLS"
sidebar_ime_leaving; sleep 0.3
[ "$(cat "$CALLS")" = "imemode.exe pop" ] || fail "leaving a focused sidebar must pop: $(cat "$CALLS")"
sidebar_ime_set_setting on; : > "$CALLS"
sidebar_ime_leaving; sleep 0.3
[ ! -s "$CALLS" ] || fail "leaving in mode on must not pop"
sidebar_ime_set_setting off
unset -f tmux

echo "PASS: sidebar_ime unit tests"
