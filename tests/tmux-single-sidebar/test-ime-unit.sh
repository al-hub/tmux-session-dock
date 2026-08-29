#!/usr/bin/env bash
# test-ime-unit.sh — scripts/lib/sidebar_ime.sh
# Backend detection order, setting precedence, hook string, and hook
# install/uninstall on a private tmux server (foreign hooks must survive).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
SOCKET="test-ime-unit-$$"
cleanup() {
    command tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

export HOME="$TMP/home"
mkdir -p "$HOME/.local/bin" "$TMP/bin" "$TMP/tools"
# Restricted PATH for detection tests: stub helpers plus only the tools the test
# itself needs, so a real fcitx/ibus on the host cannot leak in.
for tool in bash chmod rm mkdir cat grep awk sed sleep dirname tmux; do
    ln -s "$(command -v "$tool")" "$TMP/tools/$tool"
done
STUB_PATH="$TMP/bin:$TMP/tools"
ORIG_PATH="$PATH"

fail() { echo "FAIL: $*"; exit 1; }

source "$SCRIPT_DIR/scripts/lib/sidebar_ime.sh"

echo "=== [1/5] normalize ==="
[ "$(sidebar_ime_normalize on)" = "on" ] || fail "normalize on"
[ "$(sidebar_ime_normalize 1)" = "on" ] || fail "normalize 1"
[ "$(sidebar_ime_normalize english)" = "on" ] || fail "normalize english"
[ "$(sidebar_ime_normalize off)" = "off" ] || fail "normalize off"
[ "$(sidebar_ime_normalize '')" = "off" ] || fail "normalize empty"
[ "$(sidebar_ime_normalize garbage)" = "off" ] || fail "normalize garbage"

echo "=== [2/5] backend detection order ==="
export PATH="$STUB_PATH"
if sidebar_ime_backend >/dev/null 2>&1; then fail "no helper on PATH must yield no backend"; fi
[ -z "$(sidebar_ime_backend_name)" ] || fail "backend name must be empty without helper"
sidebar_ime_english_cmd >/dev/null 2>&1 && fail "english cmd must fail without helper"

printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/ibus"; chmod +x "$TMP/bin/ibus"
[ "$(sidebar_ime_backend)" = "ibus|ibus engine xkb:us::eng" ] || fail "ibus backend: $(sidebar_ime_backend)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/fcitx-remote"; chmod +x "$TMP/bin/fcitx-remote"
[ "$(sidebar_ime_backend)" = "fcitx|fcitx-remote -c" ] || fail "fcitx beats ibus"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/fcitx5-remote"; chmod +x "$TMP/bin/fcitx5-remote"
[ "$(sidebar_ime_backend)" = "fcitx5|fcitx5-remote -c" ] || fail "fcitx5 beats fcitx"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/bin/imemode.exe"; chmod +x "$HOME/.local/bin/imemode.exe"
[ "$(sidebar_ime_backend)" = "imemode|$HOME/.local/bin/imemode.exe en" ] || fail "imemode in ~/.local/bin wins: $(sidebar_ime_backend)"
[ "$(sidebar_ime_backend_name)" = "imemode" ] || fail "backend name imemode"
[ "$(sidebar_ime_english_cmd)" = "$HOME/.local/bin/imemode.exe en" ] || fail "english cmd"
export PATH="$ORIG_PATH"

echo "=== [3/5] hook command string ==="
expected="if-shell -F '#{==:#{pane_title},dotfiles-session-sidebar}' 'run-shell -b \"/x/imemode.exe en\"'"
[ "$(sidebar_ime_hook_command '/x/imemode.exe en')" = "$expected" ] || fail "hook string: $(sidebar_ime_hook_command '/x/imemode.exe en')"

echo "=== [4/5] setting precedence (private server) ==="
tmux() { command tmux -L "$SOCKET" "$@"; }
command tmux -L "$SOCKET" -f /dev/null new-session -d -s unit -x 80 -y 24 "sleep 120"
[ "$(sidebar_ime_setting)" = "off" ] || fail "default off"
mkdir -p "$(dirname "$SIDEBAR_IME_STATE_FILE")"; echo on > "$SIDEBAR_IME_STATE_FILE"
[ "$(sidebar_ime_setting)" = "on" ] || fail "state file on"
tmux set-option -gq "$SIDEBAR_IME_OPTION" off
[ "$(sidebar_ime_setting)" = "off" ] || fail "tmux option off overrides state file"
tmux set-option -gu "$SIDEBAR_IME_OPTION"
rm -f "$SIDEBAR_IME_STATE_FILE"

echo "=== [5/5] hook install / uninstall keeps foreign hooks ==="
tmux set-hook -g pane-focus-in "display-message foreign"
count_entries() { tmux show-hooks -g pane-focus-in | grep -c '^pane-focus-in\[' || true; }
[ "$(count_entries)" = "1" ] || fail "precondition: one foreign hook"

sidebar_ime_apply   # setting off -> nothing installed
sidebar_ime_hook_installed && fail "apply with setting off must not install"
[ "$(count_entries)" = "1" ] || fail "off apply must not touch foreign hook"

sidebar_ime_set_setting on
sidebar_ime_hook_installed || fail "set on must install hook"
[ "$(count_entries)" = "2" ] || fail "install must append, got $(count_entries)"
tmux show-hooks -g pane-focus-in | grep -qF "$HOME/.local/bin/imemode.exe en" || fail "hook must carry helper command"
tmux show-hooks -g pane-focus-in | grep -qF "display-message foreign" || fail "foreign hook lost on install"
[ "$(tmux show-option -gv focus-events)" = "on" ] || fail "install must turn focus-events on"
[ "$(cat "$SIDEBAR_IME_STATE_FILE")" = "on" ] || fail "state file must persist on"
[ "$(tmux show-option -gqv "$SIDEBAR_IME_OPTION")" = "on" ] || fail "tmux option must be on"

sidebar_ime_apply; sidebar_ime_apply   # idempotent
[ "$(count_entries)" = "2" ] || fail "re-apply must not duplicate, got $(count_entries)"

status="$(sidebar_ime_status)"
[ "$status" = "setting=on backend=imemode hook=installed" ] || fail "status: $status"

sidebar_ime_set_setting off
sidebar_ime_hook_installed && fail "set off must remove hook"
[ "$(count_entries)" = "1" ] || fail "uninstall must leave foreign hook, got $(count_entries)"
tmux show-hooks -g pane-focus-in | grep -qF "display-message foreign" || fail "foreign hook lost on uninstall"
[ "$(cat "$SIDEBAR_IME_STATE_FILE")" = "off" ] || fail "state file must persist off"
status="$(sidebar_ime_status)"
[ "$status" = "setting=off backend=imemode hook=absent" ] || fail "status off: $status"

# helper disappears: on-setting must not install a hook (and must not error)
rm -f "$HOME/.local/bin/imemode.exe"
export PATH="$STUB_PATH"; rm -f "$TMP/bin"/*
sidebar_ime_set_setting on
sidebar_ime_hook_installed && fail "no helper: nothing to install"
[ "$(sidebar_ime_status)" = "setting=on backend=none hook=absent" ] || fail "status no helper: $(sidebar_ime_status)"
export PATH="$ORIG_PATH"
unset -f tmux

echo "PASS: sidebar_ime unit tests"
