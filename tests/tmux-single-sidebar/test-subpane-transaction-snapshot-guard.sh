#!/usr/bin/env bash
# User Height Intent snapshots must not run while another process moves the
# slots.  Hook handlers (after-resize-pane -> --sync-sidebar-layout) are
# separate processes that snapshot 50 ms after a resize; one that landed while
# Sidebar OFF was parking slots in the hub recorded the hub window's heights
# (4/4/4 became 11/5/4 on the next ON).  The lease transaction raises a hidden
# environment marker; a foreign snapshot leaves the intent alone while it is
# up, the owning process is never blocked, and a stale marker expires.
set -euo pipefail
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"
SOCKET="test-subpane-txn-guard-$$"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; }
trap cleanup EXIT

export TMUX="$SOCKET"
source "$SCRIPT_DIR/scripts/lib/sidebar_domain.sh"
source "$SCRIPT_DIR/scripts/lib/sidebar_port_tmux.sh"
source "$SCRIPT_DIR/scripts/lib/sidebar_subpane_hub.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
intent() { tmux -L "$SOCKET" show-option -gqv @dotfiles_subpane_slot_1_height 2>/dev/null || true; }
marker() { tmux -L "$SOCKET" show-environment -gh "$SUBPANE_TRANSACTION_ENV" 2>/dev/null | sed -n 's/^[^=]*=//p'; }

tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" new-session -d -s work -n main -x 100 -y 40 'sleep 60'
win_id="$(tmux -L "$SOCKET" display-message -p -t work '#{window_id}')"
launcher_p="$(tmux -L "$SOCKET" split-window -P -F '#{pane_id}' -d -t "$win_id" -h -f -b -l 30 'sleep 60')"
sub_p="$(subpane_hub_acquire_pane "$launcher_p" 10)"
[ -n "$sub_p" ] || fail "could not acquire a subpane"
[ -z "$(marker)" ] || fail "transaction marker left up after acquire: $(marker)"

# 1. Plain snapshot records the live height.
tmux -L "$SOCKET" resize-pane -t "$sub_p" -y 6
subpane_hub_snapshot_user_intent "$win_id" >/dev/null
[ "$(intent)" = 6 ] || fail "baseline snapshot expected intent 6, got '$(intent)'"

# 2. A foreign transaction is in flight: the snapshot must not record.
tmux -L "$SOCKET" set-environment -gh "$SUBPANE_TRANSACTION_ENV" "$(( ${EPOCHSECONDS:-$(date +%s)} + 5 ))"
tmux -L "$SOCKET" resize-pane -t "$sub_p" -y 8
subpane_hub_snapshot_user_intent "$win_id" >/dev/null
[ "$(intent)" = 6 ] || fail "snapshot during a foreign transaction changed intent to '$(intent)'"

# 3. The owner of a transaction is not blocked by its own marker.
subpane_hub_transaction_begin
subpane_hub_snapshot_user_intent "$win_id" >/dev/null
[ "$(intent)" = 8 ] || fail "owner snapshot expected intent 8, got '$(intent)'"
subpane_hub_transaction_end
[ -z "$(marker)" ] || fail "transaction_end left the marker up: $(marker)"

# 4. A stale marker (crashed transaction) does not block for good.
tmux -L "$SOCKET" set-environment -gh "$SUBPANE_TRANSACTION_ENV" "$(( ${EPOCHSECONDS:-$(date +%s)} - 1 ))"
tmux -L "$SOCKET" resize-pane -t "$sub_p" -y 5
subpane_hub_snapshot_user_intent "$win_id" >/dev/null
[ "$(intent)" = 5 ] || fail "expired marker still blocked the snapshot (intent '$(intent)')"
tmux -L "$SOCKET" set-environment -ghu "$SUBPANE_TRANSACTION_ENV"

# 5. Park and rebuild clear the marker behind them and keep the intent.
subpane_hub_release_pane "$sub_p"
[ -z "$(marker)" ] || fail "release_pane left the marker up: $(marker)"
[ "$(intent)" = 5 ] || fail "park changed the intent to '$(intent)'"
sub_p2="$(subpane_hub_acquire_pane "$launcher_p" 10)"
[ -n "$sub_p2" ] || fail "could not re-acquire the subpane"
[ -z "$(marker)" ] || fail "rebuild left the marker up: $(marker)"
[ "$(tmux -L "$SOCKET" display-message -p -t "$sub_p2" '#{pane_height}')" = 5 ] || fail "rebuild ignored the intent (height $(tmux -L "$SOCKET" display-message -p -t "$sub_p2" '#{pane_height}'))"

echo "PASS: user intent snapshots are guarded against foreign lease transactions"
