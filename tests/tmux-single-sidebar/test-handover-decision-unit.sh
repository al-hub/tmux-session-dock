#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/sidebar_handover.sh"

assert_result() {
    local expected_result="$1" expected_marker="$2" expected_render="$3"
    [ "$sidebar_handover_result" = "$expected_result" ] || {
        echo "FAIL: result expected=$expected_result actual=$sidebar_handover_result"
        exit 1
    }
    [ "$sidebar_handover_marker_action" = "$expected_marker" ] || {
        echo "FAIL: marker expected=$expected_marker actual=$sidebar_handover_marker_action"
        exit 1
    }
    [ "$sidebar_handover_render_intent" = "$expected_render" ] || {
        echo "FAIL: render expected=$expected_render actual=$sidebar_handover_render_intent"
        exit 1
    }
}

# A normal marker settles selection and asks the coordinator for a delta render.
sidebar_handover_decide "target" true true false false false sessions
assert_result settled consume delta

# An active transition owns the first target frame.
sidebar_handover_decide "target" true true true false false sessions
assert_result settled consume deferred

# A committed transition also owns the first target frame.
sidebar_handover_decide "target" true true false true false sessions
assert_result settled consume deferred

# A target that still exists but has not reached the local snapshot is retried.
sidebar_handover_decide "target" true false false false false sessions
assert_result retry preserve none

# A deleted target is discarded and requires a fresh complete frame.
sidebar_handover_decide "target" false false false false false sessions
assert_result discarded discard full

echo "PASS: presenter handover decisions"
