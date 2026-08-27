#!/usr/bin/env bash
# contract: restoring an archived session shows the sidebar at the width the
#           user currently uses, not the width recorded in the archive.
#           Sidebar width is a single global user setting; an archive is a
#           snapshot of work panes.
#
# Oracle: visible #{pane_width} of the restored sidebar.
#
# Known to fail on the current product: restore applies the archived layout
# string verbatim (scripts/tmux-session-dock restore_archived_sidebar_layout)
# and the presenter then re-persists that width. This test stays in ci.list on
# purpose — CI reports the defect by name until the product honours the contract.

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd -P)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
SOCKET="dotfiles-width-restore-$$"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-width-restore.XXXXXX")"
HISTORY_DIR="$RUN_DIR/history"
HOME_DIR="$RUN_DIR/home"
STATE_DIR="$HOME_DIR/.local/state/dotfiles"
WIDTH_STATE_FILE="$STATE_DIR/tmux-sidebar-width"
TMUX=(tmux -L "$SOCKET" -f "$REPO_ROOT/dotfiles/tmux.conf")
KEEP_RUN_DIR="${KEEP_RUN_DIR:-false}"

mkdir -p "$HISTORY_DIR" "$STATE_DIR"
source "$REPO_ROOT/tests/lib/test_artifact_helper.sh"
source "$REPO_ROOT/tests/lib/width_contract_common.sh"

cleanup() {
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        KEEP_RUN_DIR=true
        dump_test_failure_artifacts "$SOCKET" "$RUN_DIR"
    fi
    "${TMUX[@]}" kill-server >/dev/null 2>&1 || true
    [ "$KEEP_RUN_DIR" = true ] || rm -rf "$RUN_DIR"
}
trap cleanup EXIT

echo "=== archive taken at width 40 ==="
tmuxc new-session -d -s anchor -x 140 -y 50 -c "$REPO_ROOT" 'sleep 300'
pane="$(provision_session archived 40)"
wait_for_width "$pane" 40
tmuxc run-shell "$LAUNCHER --archive-session archived false"
archive_path="$HISTORY_DIR/archived.tsv"
[ -f "$archive_path" ] || { echo "FAIL: archive was not created" >&2; exit 1; }

echo "=== user now works at width 28 ==="
wait_for_settled_width "$pane"
tmuxc resize-pane -t "$pane" -x 28
wait_for_width "$pane" 28
wait_for_persisted_width 28
tmuxc kill-session -t '=archived:'

echo "=== restore shows the user's width, not the archive's ==="
tmuxc run-shell "$LAUNCHER --restore-archive '$archive_path' op-width-test false"
tmuxc has-session -t '=archived:' || { echo "FAIL: archived session was not restored" >&2; exit 1; }
restored_pane="$(sidebar_pane_for archived)"
[ -n "$restored_pane" ] || { echo "FAIL: restored session has no sidebar" >&2; exit 1; }
wait_for_width "$restored_pane" 28

echo "PASS: restore keeps the user's current sidebar width"
