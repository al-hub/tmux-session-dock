#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/sidebar_domain_activity.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected=$1 actual=$2"; }

observe() {
    local result_state result_changed
    sidebar_domain_activity_observe result_state result_changed \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7"
    OBSERVED_STATE="$result_state"
    OBSERVED_CHANGED="$result_changed"
}

# First live observation starts the session as running.
observe work %1 101 true frame-a 100 10
assert_eq running "$OBSERVED_STATE" 'first live observation state'
assert_eq true "$OBSERVED_CHANGED" 'first live observation transition'

# One unchanged observation inside the grace period remains running and creates
# no row delta.
observe work %1 101 true frame-a 105 10
assert_eq running "$OBSERVED_STATE" 'unchanged observation inside grace state'
assert_eq false "$OBSERVED_CHANGED" 'unchanged observation inside grace transition'

# A new screen observation refreshes running without requiring selection.
observe work %1 101 true frame-b 109 10
assert_eq running "$OBSERVED_STATE" 'changed observation state'
assert_eq false "$OBSERVED_CHANGED" 'running heartbeat transition'

# The pane becomes idle only after the grace period from the last change.
observe work %1 101 true frame-b 119 10
assert_eq idle "$OBSERVED_STATE" 'grace expiry state'
assert_eq true "$OBSERVED_CHANGED" 'grace expiry transition'

# A dead tracked pane clears the activity state immediately.
observe work %1 101 false frame-b 120 10
assert_eq gone "$OBSERVED_STATE" 'dead pane state'
assert_eq true "$OBSERVED_CHANGED" 'dead pane transition'

printf 'PASS: observer keeps running through grace and idles after timeout\n'
printf 'PASS: observer clears a dead pane immediately\n'
