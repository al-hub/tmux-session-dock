#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"
load_launcher_functions

STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT
AI_OBSERVER_STATE_PATH_CACHED="$STATE_DIR/ai.state"

write_state()
{
    printf '#ts %s pid 4242 interval 1\n' "$1" > "$AI_OBSERVER_STATE_PATH_CACHED"
    shift
    printf '%s\n' "$@" >> "$AI_OBSERVER_STATE_PATH_CACHED"
}

test_fresh_state_is_loaded()
{
    write_state 1000 $'alpha\trunning\t%3\tact::0:1:2:cap:123:45' $'beta\tidle\t%5\tact::0:9:9:cap:77:10' $'gamma\tgone\t\t'
    SIDEBAR_AI_OBSERVER_STALE_SECONDS=4
    ai_observer_state_load 1003
    assert_eq running "${shared_ai_state[alpha]}" 'alpha state'
    assert_eq '%3' "${shared_ai_pane[alpha]}" 'alpha pane'
    assert_eq 'act::0:1:2:cap:123:45' "${shared_ai_fp[alpha]}" 'alpha fingerprint'
    assert_eq idle "${shared_ai_state[beta]}" 'beta state'
    assert_eq gone "${shared_ai_state[gamma]}" 'gamma state'
    assert_eq '' "${shared_ai_pane[gamma]}" 'gamma has no pane'
}

test_stale_state_is_rejected()
{
    write_state 1000 $'alpha\trunning\t%3\tfp'
    SIDEBAR_AI_OBSERVER_STALE_SECONDS=4
    if ai_observer_state_load 1005; then
        printf '  stale file accepted\n' >&2
        return 1
    fi
    assert_eq running "${shared_ai_state[alpha]:-}" 'stale file still parsed for fallback callers'
}

test_missing_or_garbage_header()
{
    rm -f "$AI_OBSERVER_STATE_PATH_CACHED"
    if ai_observer_state_load 1000; then
        printf '  missing file accepted\n' >&2
        return 1
    fi
    printf 'garbage\nalpha\trunning\t%%3\tfp\n' > "$AI_OBSERVER_STATE_PATH_CACHED"
    if ai_observer_state_load 1000; then
        printf '  header-less file accepted as fresh\n' >&2
        return 1
    fi
}

test_apply_shared_drives_collect_state()
{
    cached_session_cli_state=()
    session_ai_direct_pane_id=()
    shared_ai_state=([alpha]=running [beta]=gone)
    shared_ai_pane=([alpha]='%3' [beta]='')
    shared_ai_fp=([alpha]='fp-a' [beta]='')

    ai_observer_apply_shared alpha
    assert_eq running "$cli_state_value" 'alpha applied state'
    assert_eq fp-a "$ai_fingerprint_value" 'alpha applied fingerprint'
    assert_eq '%3' "${session_ai_direct_pane_id[alpha]}" 'alpha tracked pane'
    assert_eq true "$observer_state_changed" 'first application is a change'

    cached_session_cli_state[alpha]=running
    ai_observer_apply_shared alpha
    assert_eq false "$observer_state_changed" 'unchanged state is not a change'

    session_ai_direct_pane_id[beta]='%9'
    ai_observer_apply_shared beta
    assert_eq gone "$cli_state_value" 'beta applied state'
    assert_eq '' "${session_ai_direct_pane_id[beta]:-}" 'gone session drops its tracked pane'
}

run_test 'fresh shared state file is loaded' test_fresh_state_is_loaded
run_test 'stale shared state file is rejected but parsed' test_stale_state_is_rejected
run_test 'missing file or garbage header is rejected' test_missing_or_garbage_header
run_test 'applying shared state drives collect variables' test_apply_shared_drives_collect_state
finish_tests
