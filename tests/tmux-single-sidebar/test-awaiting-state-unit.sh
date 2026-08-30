#!/usr/bin/env bash
# Unit: the awaiting decision, driven straight through the pure policy.
#
# Awaiting means "the AI stopped and the user has not been here since". It is an
# unread marker, so nothing but the user's arrival or the AI moving again may
# clear it - in particular no clock does.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/sidebar_domain_activity.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

AWAIT_AFTER=30
BUSY=10
# Not named `state`: the policy declares its own `local state`, which would
# shadow a caller variable of that name behind the nameref.
out_state="" out_changed=""

# observe <session> <observation> <now> [acknowledged] [await_after]
observe() {
    sidebar_domain_activity_observe out_state out_changed \
        "$1" '%1' '1234' true "$2" "$3" "$BUSY" "${5:-$AWAIT_AFTER}" "${4:-false}"
}

expect() {
    [ "$out_state" = "$1" ] || fail "$2: state was '$out_state', expected '$1'"
}

# --- a real run that stops with nobody watching ------------------------------
sidebar_domain_activity_reset_all
observe s 'frame-0' 100          # first sighting: seeds, looks like running
expect running 'first sighting'
observe s 'frame-1' 101          # a genuine change
expect running 'observed change'
observe s 'frame-1' 105          # quiet, still inside the busy window
expect running 'quiet under busy window'
observe s 'frame-1' 115          # quiet past busy, not yet past await
expect idle 'quiet past busy, under await threshold'
observe s 'frame-1' 131          # quiet past the await threshold
expect awaiting 'quiet past the await threshold'
printf 'PASS: a stop nobody witnessed becomes awaiting\n'

# --- it stays awaiting; no clock clears it -----------------------------------
observe s 'frame-1' 400
expect awaiting 'still awaiting much later'
observe s 'frame-1' 100000
expect awaiting 'awaiting does not time out'
printf 'PASS: awaiting is not cleared by the passage of time\n'

# --- the user arriving clears it ---------------------------------------------
observe s 'frame-1' 100001 true
expect idle 'acknowledged'
observe s 'frame-1' 100002 false
expect idle 'stays idle once acknowledged, even after leaving'
printf 'PASS: arriving clears awaiting, and leaving again does not re-arm it\n'

# --- the AI moving again wins ------------------------------------------------
observe s 'frame-2' 100003
expect running 'output resumed'
observe s 'frame-2' 100040
expect awaiting 'stopped again, unwitnessed'
observe s 'frame-3' 100041
expect running 'awaiting -> running on new output'
printf 'PASS: new output overrides awaiting\n'

# --- stopping while the user is present never announces ----------------------
sidebar_domain_activity_reset_all
observe w 'a' 200
observe w 'b' 201
observe w 'b' 260 true
expect idle 'stopped while the user was in the session'
printf 'PASS: a stop the user witnessed is not announced\n'

# --- the bootstrap guard -----------------------------------------------------
# A fresh observer has empty maps, so the first observation of an idle session
# looks like a change and therefore like "running". Without the guard, every AI
# session would raise a false awaiting once the threshold passed.
sidebar_domain_activity_reset_all
observe boot 'unchanged-screen' 500
expect running 'bootstrap sighting'
observe boot 'unchanged-screen' 600
[ "$out_state" = awaiting ] && fail 'bootstrap: a first sighting must never produce awaiting'
expect idle 'bootstrap stop'
printf 'PASS: the first sighting of a session never produces awaiting\n'

# --- await_after 0 disables the state entirely (presenter local fallback) -----
sidebar_domain_activity_reset_all
observe f 'a' 700
observe f 'b' 701
observe f 'b' 900 false 0
expect idle 'await_after 0'
printf 'PASS: await_after 0 never produces awaiting\n'

# --- a session whose AI is gone forgets everything ----------------------------
sidebar_domain_activity_reset_all
observe g 'a' 800
observe g 'b' 801
observe g 'b' 900
expect awaiting 'awaiting before the AI exits'
sidebar_domain_activity_observe out_state out_changed g '' '' false '' 901 "$BUSY" "$AWAIT_AFTER" false
expect gone 'AI exited'
observe g 'a' 902
expect running 'a new AI is a first sighting again'
observe g 'a' 1000
expect idle 'and its first stop does not announce'
printf 'PASS: an exiting AI resets the session, guard included\n'

# --- the threshold clamp ------------------------------------------------------
for pair in ":30000" "abc:30000" "0:1000" "1:1000" "999:1000" "1000:1000" \
    "30000:30000" "300000:300000" "300001:300000" "9999999:300000"; do
    sidebar_domain_activity_await_after "${pair%%:*}"
    [ "$sidebar_awaiting_after_ms_result" = "${pair#*:}" ] ||
        fail "clamp('${pair%%:*}') was $sidebar_awaiting_after_ms_result, expected ${pair#*:}"
done
printf 'PASS: the threshold is clamped, and an unusable value falls back\n'
