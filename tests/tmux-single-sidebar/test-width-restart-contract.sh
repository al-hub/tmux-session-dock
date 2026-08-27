#!/usr/bin/env bash
# contract: a sidebar width the user chose is what they see after the tmux
#           server restarts. A corrupt persisted width never produces an
#           undrawable sidebar.
#
# Oracle: visible #{pane_width} only.

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd -P)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
SOCKET="dotfiles-width-restart-$$"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-width-restart.XXXXXX")"
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

echo "=== corrupt persisted width still yields a drawable sidebar ==="
printf 'not-a-width\n' > "$WIDTH_STATE_FILE"
pane="$(provision_session first)"
width="$(tmuxc display-message -p -t "$pane" '#{pane_width}')"
[ "$width" -ge 20 ] && [ "$width" -le 45 ] || {
    echo "FAIL: corrupt width state produced visible width $width (want 20..45)" >&2
    exit 1
}

echo "=== user resize survives a server restart ==="
wait_for_settled_width "$pane"
tmuxc resize-pane -t "$pane" -x 40
wait_for_width "$pane" 40
wait_for_persisted_width 40
tmuxc kill-server
sleep 0.2
tmuxc new-session -d -s anchor -x 140 -y 50 -c "$REPO_ROOT" 'sleep 300'
pane="$(provision_session second)"
wait_for_width "$pane" 40

echo "PASS: user width survives restart; corrupt state falls back safely"
