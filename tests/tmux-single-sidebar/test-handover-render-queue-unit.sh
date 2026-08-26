#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
trace_event() { :; }
render_marker_delta() { rendered_target="$3"; }
render_footer() { footer_rendered=true; }
request_full_render() { requested_render="$1"; }
transition_commit_pending() { return 1; }
transition_is_active() { return 1; }
source "$REPO_ROOT/scripts/lib/sidebar_coordinator.sh"

# One marker slot means an unflushed older handover is intentionally replaced
# by the newest target before the coordinator renders the settled frame.
transition_coordinator_queue_handover_render deferred older old 1 older
transition_coordinator_queue_handover_render delta newest old 2 newest
[ "$handover_render_target" = newest ] || { echo "FAIL: newest target was not retained"; exit 1; }

transition_coordinator_flush_handover_render
[ "${rendered_target:-}" = newest ] || { echo "FAIL: newest target was not rendered"; exit 1; }
[ "${footer_rendered:-false}" = true ] || { echo "FAIL: footer was not rendered"; exit 1; }
[ "$handover_render_intent" = none ] || { echo "FAIL: queue was not drained"; exit 1; }

echo "PASS: presenter handover render queue"
