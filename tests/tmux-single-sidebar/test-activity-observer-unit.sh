#!/usr/bin/env bash
# Unit tests for the pure AI activity observer in scripts/lib/sidebar_domain_activity.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/scripts/lib/sidebar_domain_activity.sh"

pass_count=0

check()
{
    local expected="$1" actual="$2" msg="$3"
    if [ "$expected" != "$actual" ]; then
        printf 'FAIL: %s (expected: [%s], got: [%s])\n' "$msg" "$expected" "$actual" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$msg"
    pass_count=$((pass_count + 1))
}

# observe <session> <pane> <pid> <alive> <observation> <now> <idle_timeout>
# The output namerefs must not collide with the observer's own locals
# (`state`, `changed` would resolve to its internals), hence the obs_ prefix.
observe()
{
    sidebar_domain_activity_observe obs_state obs_changed "$@"
}

echo "=== Running Activity Observer Domain Unit Tests ==="

# 1. No tracked pane -> gone, and the very first evaluation is not a transition.
sidebar_domain_activity_reset_all
observe s1 '' '' false '' 100 10
check gone "$obs_state" 'untracked session is gone'
check false "$obs_changed" 'initial gone is not a transition'

# 2. First live observation -> running, transition reported once.
observe s1 %1 4242 true fp-a 100 10
check running "$obs_state" 'first live observation is running'
check true "$obs_changed" 'gone -> running is a transition'
check true "$(sidebar_domain_activity_get_animate s1)" 'running animates'

observe s1 %1 4242 true fp-a 101 10
check running "$obs_state" 'unchanged observation inside grace stays running'
check false "$obs_changed" 'steady running is not a transition'

# 3. Grace period: unchanged for idle_timeout seconds -> idle, exactly at the boundary.
observe s1 %1 4242 true fp-a 109 10
check running "$obs_state" 'unchanged 9s after last change stays running'
observe s1 %1 4242 true fp-a 110 10
check idle "$obs_state" 'unchanged 10s after last change becomes idle'
check true "$obs_changed" 'running -> idle is a transition'
check false "$(sidebar_domain_activity_get_animate s1)" 'idle does not animate'

# 4. New observation while idle -> running again, clock restarts from that sample.
observe s1 %1 4242 true fp-b 130 10
check running "$obs_state" 'changed observation resumes running'
check true "$obs_changed" 'idle -> running is a transition'
observe s1 %1 4242 true fp-b 139 10
check running "$obs_state" 'grace restarts from the latest change'
observe s1 %1 4242 true fp-b 140 10
check idle "$obs_state" 'idle again after a full grace with no change'

# 5. Pane or pid replacement is a new generation -> running even with identical output.
observe s1 %2 4242 true fp-b 141 10
check running "$obs_state" 'pane replacement restarts running'
observe s1 %2 4242 true fp-b 151 10
check idle "$obs_state" 'replaced pane obeys the grace period'
observe s1 %2 9999 true fp-b 152 10
check running "$obs_state" 'pid replacement restarts running'

# 6. Losing the pane -> gone and tracked state is cleared.
observe s1 %2 9999 false fp-b 153 10
check gone "$obs_state" 'dead pane is gone'
check true "$obs_changed" 'running -> gone is a transition'
check '' "${_SIDEBAR_ACTIVITY_OBSERVATION[s1]:-}" 'gone clears the stored observation'
observe s1 %2 9999 true fp-b 154 10
check running "$obs_state" 'reappearing pane starts a fresh running generation'

# 7. Sessions are independent.
sidebar_domain_activity_reset_all
observe a %1 1 true fp 100 10
observe b %2 2 true fp 100 10
observe a %1 1 true fp 120 10
check idle "$obs_state" 'session a idles on its own clock'
observe b %2 2 true fp-x 120 10
check running "$obs_state" 'session b keeps running on its own observation'
check idle "$(sidebar_domain_activity_get_state a)" 'session b change does not touch session a'

# 8. Garbage clock values degrade to zero instead of failing arithmetic.
sidebar_domain_activity_reset_all
observe s2 %1 1 true fp '' abc
check running "$obs_state" 'first observation with garbage clock still runs'
observe s2 %1 1 true fp x abc
check idle "$obs_state" 'zero idle timeout idles on the next unchanged sample'

echo "=== All $pass_count Activity Observer Unit Tests Passed ==="
