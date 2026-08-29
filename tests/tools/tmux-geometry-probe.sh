#!/usr/bin/env bash
# Probe how this tmux accounts pane geometry with pane-border-status top,
# then run the product's subpane swap and report both the reported height
# and the rows a user actually sees. Diagnostic only; no assertions.
set -uo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CONF="$REPO_ROOT/tests/fixtures/test-tmux.conf"
SOCK="geometry-probe-$$"
T=(tmux -L "$SOCK" -f "$CONF")
trap '"${T[@]}" kill-server >/dev/null 2>&1 || true' EXIT

echo "tmux: $(tmux -V)"
echo "conf: pane-border-status=$("${T[@]}" start-server \; show-options -gv pane-border-status 2>/dev/null)"

panes() { "${T[@]}" list-panes -t "$1" -F '#{pane_id} top=#{pane_top} h=#{pane_height} w=#{pane_width} title=#{pane_title}' | sed 's/^/    /'; }

echo "== raw tmux: split -v -l 12, resize -y 12, swap =="
"${T[@]}" new-session -d -s p -x 120 -y 50 'sleep 120'
"${T[@]}" split-window -v -l 12 -t p 'sleep 120'; sleep 0.2
echo "  after split -l 12:"; panes p
"${T[@]}" resize-pane -t p:0.1 -y 12; sleep 0.2
echo "  after resize-pane -y 12:"; panes p
"${T[@]}" swap-pane -d -s p:0.0 -t p:0.1; sleep 0.2
echo "  after swap-pane (bottom pane now top):"; panes p
echo "  window_height=$("${T[@]}" display -p -t p '#{window_height}')  status=$("${T[@]}" show-options -gv status)"
"${T[@]}" kill-session -t p

echo "== product: provision subpane (12) then swap to top =="
export TMUX_SESSION_LAUNCHER_SOCKET="$SOCK"
export TMUX_SESSION_SIDEBAR_SUBPANE_HEIGHT_STATE_FILE="$(mktemp)"
"${T[@]}" new-session -d -s work -n main -x 120 -y 50 'sleep 120'
win_id="$("${T[@]}" display-message -p -t work '#{window_id}')"
launcher_p="$("${T[@]}" split-window -P -F '#{pane_id}' -d -t "$win_id" -h -f -b -l 30 'sleep 120')"
"${T[@]}" select-pane -t "$launcher_p" -T "dotfiles-session-sidebar"
"${T[@]}" set-option -g @dotfiles_sidebar_subpane_height 12
source "$REPO_ROOT/scripts/lib/sidebar_domain.sh"
source "$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh"
source "$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh"
sub_p="$(provision_sidebar_subpane "$win_id" "$launcher_p" 12 "")"
sleep 0.3
echo "  after provision (bottom):"; panes "$win_id"
sidebar_subpane_swap_position "$win_id"
sleep 0.5
echo "  after swap to top:"; panes "$win_id"
echo "  subpane capture rows (visible, -e off): $("${T[@]}" capture-pane -p -t "$sub_p" | wc -l)"
echo "  launcher capture rows: $("${T[@]}" capture-pane -p -t "$launcher_p" | wc -l)"
echo "  border-status option: $("${T[@]}" show-options -wv -t "$win_id" pane-border-status 2>/dev/null || "${T[@]}" show-options -gv pane-border-status)"

echo "== candidates: raw ops on a top subpane inside a 30-col sidebar column =="
# Same shape as the product: main pane | sidebar column (30 cols), subpane
# stacked above the launcher inside the column. Report reported height and
# the rows a user sees after each op so the version-specific correction can
# be chosen from data rather than from a guess.
"${T[@]}" kill-session -t work 2>/dev/null || true
rows_of() { "${T[@]}" capture-pane -p -t "$1" | wc -l | tr -d ' '; }
hw() { "${T[@]}" display -p -t "$1" 'h=#{pane_height} top=#{pane_top}'; }
cand() { # label, then commands
    local label="$1"; shift
    "${T[@]}" new-session -d -s c -x 120 -y 50 'sleep 120'
    local col; col="$("${T[@]}" split-window -P -F '#{pane_id}' -d -t c -h -f -b -l 30 'sleep 120')"
    "${T[@]}" select-pane -t "$col" -T "dotfiles-session-sidebar"
    local sub=""
    for step in "$@"; do
        case "$step" in
            split-b:*)  sub="$("${T[@]}" split-window -P -F '#{pane_id}' -d -v -b -t "$col" -l "${step#split-b:}" 'sleep 120')" ;;
            split:*)    sub="$("${T[@]}" split-window -P -F '#{pane_id}' -d -v -t "$col" -l "${step#split:}" 'sleep 120')" ;;
            swap)       "${T[@]}" swap-pane -d -s "$col" -t "$sub" ;;
            resize:*)   "${T[@]}" resize-pane -t "$sub" -y "${step#resize:}" ;;
            join-b:*)   "${T[@]}" new-window -d -t c -n hub 'sleep 120'; sub="$("${T[@]}" display -p -t c:hub '#{pane_id}')"
                        "${T[@]}" join-pane -d -b -v -s "$sub" -t "$col" -l "${step#join-b:}" ;;
        esac
        sleep 0.15
        printf '  %-34s %-12s sub %s rows=%s | launcher %s rows=%s\n' "$label" "$step" "$(hw "$sub")" "$(rows_of "$sub")" "$(hw "$col")" "$(rows_of "$col")"
    done
    "${T[@]}" kill-session -t c
}
cand "A split -b 13, resize 12, 11"   split-b:13 resize:12 resize:11
cand "B split -b 12, resize 12"       split-b:12 resize:12
cand "C split 12, swap, resize 12,13" split:12 swap resize:12 resize:13
cand "D join -b 13, resize 12, 11"    join-b:13 resize:12 resize:11
cand "E join -b 12, resize 12"        join-b:12 resize:12
