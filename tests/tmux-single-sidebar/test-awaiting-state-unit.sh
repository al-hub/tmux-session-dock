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

# observe <session> <observation> <now> [acknowledged] [await_after] [bootstrap_sweep]
observe() {
    sidebar_domain_activity_observe out_state out_changed \
        "$1" '%1' '1234' true "$2" "$3" "$BUSY" "${5:-$AWAIT_AFTER}" "${4:-false}" "${6:-false}"
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
# A fresh observer has empty maps, so its first sweep sees every session as
# having just changed. Those sessions have been sitting there for an unknown
# time; announcing them would raise a false alarm on every reopened dock.
sidebar_domain_activity_reset_all
observe boot 'unchanged-screen' 500 false "$AWAIT_AFTER" true
expect running 'first sweep sighting'
observe boot 'unchanged-screen' 600
[ "$out_state" = awaiting ] && fail 'a session swept up by a starting observer must not announce'
expect idle 'first sweep stop'
observe boot 'moved' 601
expect running 'the same session actually working'
observe boot 'moved' 700
expect awaiting 'and now its stop is real news'
printf 'PASS: a session the observer merely inherited stays silent until it moves\n'

# --- a session that appears later is new, even if its screen never moves ------
# An AI that finishes drawing before the observer's next sample is never seen to
# change. It is still a session that did not exist a moment ago, so its stop is
# worth reporting.
observe fresh 'drawn-once' 800
expect running 'a session that appeared while the observer was running'
observe fresh 'drawn-once' 900
expect awaiting 'its stop is announced without ever being seen to change'
printf 'PASS: a session created after the observer starts can announce its first stop\n'

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
expect awaiting 'a replacement AI that stops is news, because it just started'
printf 'PASS: an exiting AI resets the session, and its replacement can announce\n'

# --- the threshold decides when, exactly -------------------------------------
# With a threshold longer than the busy window there is a quiet stretch that is
# reported as Idle before the mark is earned.
sidebar_domain_activity_reset_all
observe t 'a' 1000
observe t 'b' 1001            # a real change: the session is now eligible
observe t 'b' $((1001 + 10 - 1))
expect running 'one second inside the busy window'
observe t 'b' $((1001 + 10))
expect idle 'left running, but the threshold has not passed'
observe t 'b' $((1001 + AWAIT_AFTER - 1))
expect idle 'one second before the threshold'
observe t 'b' $((1001 + AWAIT_AFTER))
expect awaiting 'exactly on the threshold'
printf 'PASS: the mark is earned exactly at the configured threshold\n'

# --- a threshold at the busy window leaves no gap -----------------------------
# The threshold is measured from the last output and its floor is the busy
# window, so the shortest setting a user can reach makes the mark appear the
# moment the session stops counting as Working: Idle is never seen. (The pure
# policy still accepts a smaller number, which is what the clamp exists to
# prevent from reaching it.)
SHORT=10
sidebar_domain_activity_reset_all
observe s2 'a' 2000
observe s2 'b' 2001
for elapsed in 1 3 5 7 9; do
    observe s2 'b' $((2001 + elapsed)) false "$SHORT"
    expect running "still working ${elapsed}s after the last change"
done
observe s2 'b' $((2001 + 10)) false "$SHORT"
expect awaiting 'the first observation that is not running is already awaiting'
printf 'PASS: a threshold at the busy window turns Working straight into Awaiting\n'

# --- the threshold clamp ------------------------------------------------------
# The floor is the busy window: a number below it could never be honoured, so
# it is raised rather than accepted as a promise the code cannot keep.
for pair in ":30000" "abc:30000" "0:$SIDEBAR_AWAITING_AFTER_MS_MIN" "1:$SIDEBAR_AWAITING_AFTER_MS_MIN" \
    "6000:$SIDEBAR_AWAITING_AFTER_MS_MIN" "9999:$SIDEBAR_AWAITING_AFTER_MS_MIN" \
    "10000:10000" "30000:30000" "300000:300000" "300001:300000" "9999999:300000"; do
    sidebar_domain_activity_await_after "${pair%%:*}"
    [ "$sidebar_awaiting_after_ms_result" = "${pair#*:}" ] ||
        fail "clamp('${pair%%:*}') was $sidebar_awaiting_after_ms_result, expected ${pair#*:}"
done
printf 'PASS: a threshold below the busy window is raised to it, not accepted\n'
