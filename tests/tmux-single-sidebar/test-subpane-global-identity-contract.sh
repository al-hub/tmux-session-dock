#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_SOCKET="subpane-global-identity-$$"
BIN_SCRIPT="$REPO_ROOT/scripts/tmux-session-dock"
STATE_DIR="$(mktemp -d /tmp/subpane-global-identity-state.XXXXXX)"

cleanup() {
    tmux -L "$TEST_SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$STATE_DIR"
}
trap cleanup EXIT

export TMUX_SESSION_SIDEBAR_SUBPANE_HEIGHT_STATE_FILE="$STATE_DIR/height"
export TMUX_SESSION_SIDEBAR_SUBPANE_POSITION_STATE_FILE="$STATE_DIR/position"
export TMUX_SESSION_SIDEBAR_SUBPANE_ENABLED_STATE_FILE="$STATE_DIR/enabled"

source "$REPO_ROOT/tests/lib/subpane_topology_oracle.sh"

create_presenter_window() {
    local session="$1"
    tmux -L "$TEST_SOCKET" new-session -d -s "$session" -n main -x 120 -y 50
    local window work presenter
    window="$(tmux -L "$TEST_SOCKET" display-message -p -t "$session:main" '#{window_id}')"
    work="$(tmux -L "$TEST_SOCKET" display-message -p -t "$session:main" '#{pane_id}')"
    presenter="$(tmux -L "$TEST_SOCKET" split-window -h -b -t "$work" -l 34 -P -F '#{pane_id}')"
    tmux -L "$TEST_SOCKET" select-pane -t "$presenter" -T dotfiles-session-sidebar
    tmux -L "$TEST_SOCKET" set-option -p -q -t "$presenter" @dotfiles_sidebar_pane 1
    printf '%s|%s|%s\n' "$window" "$work" "$presenter"
}

IFS='|' read -r win1 work1 presenter1 <<< "$(create_presenter_window sess1)"
IFS='|' read -r win2 work2 presenter2 <<< "$(create_presenter_window sess2)"

tmux -L "$TEST_SOCKET" set-option -gq @dotfiles_sidebar_enabled 1
tmux -L "$TEST_SOCKET" set-option -gq @session-dock-subpane-count 2
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$presenter1" \
    bash "$BIN_SCRIPT" --toggle-subpane

mapfile -t canonical_ids < <(subpane_oracle_slot_ids "$TEST_SOCKET")
[ "${#canonical_ids[@]}" -eq 2 ] || {
    echo "expected two canonical Subpane Slot identities after provisioning" >&2
    exit 1
}

initial_pane_count="$(tmux -L "$TEST_SOCKET" list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')"
subpane_oracle_assert_leased_pool "$TEST_SOCKET" 2 "$win1" "${canonical_ids[@]}"

export TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET"
source "$REPO_ROOT/scripts/lib/sidebar_domain.sh"
source "$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh"
source "$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh"

for round in 1 2 3 4 5; do
    tmux -L "$TEST_SOCKET" select-pane -t "$work2"
    ensure_sidebar_subpane_window "$win2" "$presenter2"
    subpane_oracle_assert_leased_pool "$TEST_SOCKET" 2 "$win2" "${canonical_ids[@]}"
    active2="$(tmux -L "$TEST_SOCKET" display-message -p -t "$win2" '#{pane_id}')"
    [ "$active2" = "$work2" ] || {
        echo "round $round: lease movement changed target focus from $work2 to $active2" >&2
        exit 1
    }

    tmux -L "$TEST_SOCKET" select-pane -t "$work1"
    ensure_sidebar_subpane_window "$win1" "$presenter1"
    subpane_oracle_assert_leased_pool "$TEST_SOCKET" 2 "$win1" "${canonical_ids[@]}"
    active1="$(tmux -L "$TEST_SOCKET" display-message -p -t "$win1" '#{pane_id}')"
    [ "$active1" = "$work1" ] || {
        echo "round $round: lease movement changed target focus from $work1 to $active1" >&2
        exit 1
    }
done

# Re-ensuring an already correct lease is a topology no-op: no detach/attach,
# redraw-producing layout change, or focus mutation.
layout_before_noop="$(tmux -L "$TEST_SOCKET" display-message -p -t "$win1" '#{window_layout}')"
active_before_noop="$(tmux -L "$TEST_SOCKET" display-message -p -t "$win1" '#{pane_id}')"
ensure_sidebar_subpane_window "$win1" "$presenter1"
layout_after_noop="$(tmux -L "$TEST_SOCKET" display-message -p -t "$win1" '#{window_layout}')"
active_after_noop="$(tmux -L "$TEST_SOCKET" display-message -p -t "$win1" '#{pane_id}')"
[ "$layout_after_noop" = "$layout_before_noop" ] || {
    echo "re-ensuring the current Subpane Lease changed window layout" >&2
    exit 1
}
[ "$active_after_noop" = "$active_before_noop" ] || {
    echo "re-ensuring the current Subpane Lease changed active pane" >&2
    exit 1
}

# Reconcile a legacy duplicate only after a registry-backed canonical identity
# is known. The duplicate terminal must not accumulate as another pane/process.
duplicate="$(tmux -L "$TEST_SOCKET" split-window -d -t "$work2" -v -P -F '#{pane_id}' 'sleep 300')"
tmux -L "$TEST_SOCKET" set-option -p -q -t "$duplicate" @dotfiles_subpane_hub_pane 1
tmux -L "$TEST_SOCKET" set-option -p -q -t "$duplicate" @dotfiles_sidebar_subpane 1
tmux -L "$TEST_SOCKET" set-option -p -q -t "$duplicate" @dotfiles_subpane_slot 1
tmux -L "$TEST_SOCKET" select-pane -t "$work2"
ensure_sidebar_subpane_window "$win2" "$presenter2"
if subpane_oracle_inventory "$TEST_SOCKET" | awk -F '|' -v pane="$duplicate" '$3 == pane { found=1 } END { exit !found }'; then
    echo "duplicate Subpane Slot survived canonical reconciliation" >&2
    subpane_oracle_inventory "$TEST_SOCKET" >&2
    exit 1
fi
subpane_oracle_assert_leased_pool "$TEST_SOCKET" 2 "$win2" "${canonical_ids[@]}"

# Toggle parking and re-entry retain the same terminal identities while the
# Hub Keeper prevents infrastructure churn.
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$presenter2" \
    bash "$BIN_SCRIPT" --toggle-subpane "$win2"
parked_in_presenter="$(tmux -L "$TEST_SOCKET" list-panes -t "$win2" -F '#{@dotfiles_sidebar_subpane}' |
    awk '$1 == "1" { count++ } END { print count + 0 }')"
[ "$parked_in_presenter" -eq 0 ] || {
    echo "toggle off left $parked_in_presenter Subpane Slots in the Presenter Window" >&2
    exit 1
}
mapfile -t parked_ids < <(subpane_oracle_slot_ids "$TEST_SOCKET")
[ "${parked_ids[*]}" = "${canonical_ids[*]}" ] || {
    echo "toggle off changed canonical Subpane Slot identities" >&2
    exit 1
}

TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$presenter2" \
    bash "$BIN_SCRIPT" --toggle-subpane "$win2"
subpane_oracle_assert_leased_pool "$TEST_SOCKET" 2 "$win2" "${canonical_ids[@]}"
active2="$(tmux -L "$TEST_SOCKET" display-message -p -t "$win2" '#{pane_id}')"
[ "$active2" = "$work2" ] || {
    echo "toggle roundtrip changed target focus from $work2 to $active2" >&2
    exit 1
}

final_pane_count="$(tmux -L "$TEST_SOCKET" list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')"
[ "$final_pane_count" -eq "$initial_pane_count" ] || {
    echo "Subpane Pool grew from $initial_pane_count to $final_pane_count panes" >&2
    subpane_oracle_inventory "$TEST_SOCKET" >&2
    exit 1
}

echo "PASS: Subpane Lease preserves canonical identity, bounded topology, and focus"
