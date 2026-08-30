#!/usr/bin/env bash
# Contract: sidebar_client_field answers about the client it is given.
#
# The dock asks per-client questions in the switch (which session did we come
# from), in the focus hooks and when sizing the dock. It used to ask them with
# `display-message -c <tty>`, which cannot answer them on either supported tmux:
# 3.2a rejects `-p -c` outright, and 3.4 accepts it but resolves the format
# against the most recently used session, so every client reports the same
# answer and a client that has just switched reports the session it left.
#
# Two clients on two sessions is the case that separates a per-client answer
# from a server-wide one, so that is what this asserts.
set -euo pipefail
export LC_ALL="${LC_ALL:-C.UTF-8}" LANG="${LANG:-C.UTF-8}" TERM=xterm-256color

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
TEST_TMUX_CONF="$REPO_ROOT/tests/fixtures/test-tmux.conf"
SOCKET="client-field-$$"
PIDS=()

cleanup() {
    local pid
    for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; tmuxc list-clients -F '  #{client_tty} -> #{client_session}' >&2 2>/dev/null || true; exit 1; }

# shellcheck disable=SC1091
export TMUX_SESSION_LAUNCHER_SOCKET="$SOCKET"
source "$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh"
declare -f sidebar_client_field >/dev/null || fail 'sidebar_client_field not loaded'

tmuxc new-session -d -s one -x 80 -y 24 'sleep 120'
tmuxc new-session -d -s two -x 100 -y 30 'sleep 120'
for s in one two; do
    setsid script -qefc "tmux -L '$SOCKET' attach-session -t $s" /dev/null >/dev/null 2>&1 &
    PIDS+=("$!")
done

deadline=$(( $(date +%s) + 20 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(tmuxc list-clients -F '#{client_tty}' | grep -c .)" -ge 2 ] && break
    sleep 0.2
done
[ "$(tmuxc list-clients -F '#{client_tty}' | grep -c .)" -ge 2 ] || fail 'two clients never attached'

checked=0
while IFS='|' read -r tty expected; do
    [ -n "$tty" ] || continue
    got="$(sidebar_client_field "$tty" '#S' || printf 'NO-ANSWER')"
    [ "$got" = "$expected" ] || fail "client $tty is on '$expected' but sidebar_client_field said '$got'"
    checked=$((checked + 1))
done < <(tmuxc list-clients -F '#{client_tty}|#{client_session}')
[ "$checked" -ge 2 ] || fail "only $checked client(s) checked"
printf 'PASS: each of %d clients reports its own session\n' "$checked"

# The size is per client too - the dock reads it to lay itself out. Give the
# two terminals different sizes first; both ptys start at the same default and
# a server-wide answer would be indistinguishable from a per-client one.
one_tty="$(tmuxc list-clients -F '#{client_session}|#{client_tty}' | awk -F'|' '$1 == "one" { print $2; exit }')"
two_tty="$(tmuxc list-clients -F '#{client_session}|#{client_tty}' | awk -F'|' '$1 == "two" { print $2; exit }')"
stty -F "$two_tty" columns 111 rows 33 2>/dev/null || fail "could not resize $two_tty"
deadline=$(( $(date +%s) + 10 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(sidebar_client_field "$two_tty" '#{client_width}' || true)" = 111 ] && break
    sleep 0.2
done
one_w="$(sidebar_client_field "$one_tty" '#{client_width}' || printf 'NO-ANSWER')"
two_w="$(sidebar_client_field "$two_tty" '#{client_width}' || printf 'NO-ANSWER')"
[ "$two_w" = 111 ] || fail "the resized client reports width '$two_w', not 111"
[ "$one_w" != "$two_w" ] || fail "both clients reported width '$one_w'; the answer is not per client"
printf 'PASS: the two clients report their own widths (%s and %s)\n' "$one_w" "$two_w"

# A client that is not there is not the same answer as an empty session name.
if sidebar_client_field /dev/pts/9999 '#S' >/dev/null 2>&1; then
    fail 'an unknown client tty was answered instead of refused'
fi
printf 'PASS: an unknown client tty is refused, so callers can fall back\n'

# Switching a client must move its answer, and only its answer.
tmuxc switch-client -c "$one_tty" -t two
deadline=$(( $(date +%s) + 10 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(sidebar_client_field "$one_tty" '#S' || true)" = two ] && break
    sleep 0.2
done
[ "$(sidebar_client_field "$one_tty" '#S' || true)" = two ] ||
    fail "after switch-client the client still reports '$(sidebar_client_field "$one_tty" '#S' || true)'"
printf 'PASS: a switched client reports the session it moved to\n'
