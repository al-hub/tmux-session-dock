#!/usr/bin/env bash

# Global Topology Oracle for the server-wide Subpane Pool contract.

subpane_oracle_inventory() {
    local socket="$1"
    tmux -L "$socket" list-panes -a \
        -F '#{session_name}|#{window_id}|#{pane_id}|#{pane_active}|#{@dotfiles_sidebar_subpane}|#{@dotfiles_subpane_slot}|#{@dotfiles_subpane_hub_keeper}|#{pane_current_command}' \
        2>/dev/null || true
}

subpane_oracle_slot_ids() {
    local socket="$1"
    subpane_oracle_inventory "$socket" |
        awk -F '|' '$5 == "1" && $6 ~ /^[0-9]+$/ { print $6 "|" $3 }' |
        sort -n -t '|' -k 1 |
        cut -d '|' -f 2
}

subpane_oracle_assert_leased_pool() {
    local socket="$1" expected_count="$2" expected_window="$3"
    shift 3
    local expected_ids=("$@")
    local inventory keeper_count marked_count lease_holder

    inventory="$(subpane_oracle_inventory "$socket")"
    keeper_count="$(printf '%s\n' "$inventory" | awk -F '|' '$7 == "1" { count++ } END { print count + 0 }')"
    [ "$keeper_count" -eq 1 ] || {
        echo "oracle: expected one Hub Keeper, found $keeper_count" >&2
        printf '%s\n' "$inventory" >&2
        return 1
    }

    if ! printf '%s\n' "$inventory" | awk -F '|' '$1 == "dotfiles-subpane-hub" && $7 == "1" && $8 == "sleep" { found=1 } END { exit !found }'; then
        echo "oracle: Hub Keeper must be one idle sleep process in the infrastructure session" >&2
        printf '%s\n' "$inventory" >&2
        return 1
    fi

    if printf '%s\n' "$inventory" | awk -F '|' '$7 == "1" && ($5 == "1" || $6 != "") { found=1 } END { exit !found }'; then
        echo "oracle: Hub Keeper must not carry Subpane Slot roles" >&2
        return 1
    fi

    marked_count="$(printf '%s\n' "$inventory" | awk -F '|' '$5 == "1" { count++ } END { print count + 0 }')"
    [ "$marked_count" -eq "$expected_count" ] || {
        echo "oracle: expected $expected_count marked Subpane Slots, found $marked_count" >&2
        printf '%s\n' "$inventory" >&2
        return 1
    }

    local slot actual_count actual_id expected_id
    for ((slot=1; slot<=expected_count; slot++)); do
        actual_count="$(printf '%s\n' "$inventory" | awk -F '|' -v slot="$slot" '$5 == "1" && $6 == slot { count++ } END { print count + 0 }')"
        [ "$actual_count" -eq 1 ] || {
            echo "oracle: expected slot $slot exactly once, found $actual_count" >&2
            printf '%s\n' "$inventory" >&2
            return 1
        }
        actual_id="$(printf '%s\n' "$inventory" | awk -F '|' -v slot="$slot" '!done && $5 == "1" && $6 == slot { print $3; done = 1 }')"
        expected_id="${expected_ids[$((slot - 1))]:-}"
        if [ -n "$expected_id" ] && [ "$actual_id" != "$expected_id" ]; then
            echo "oracle: slot $slot identity changed from $expected_id to $actual_id" >&2
            return 1
        fi
        if ! printf '%s\n' "$inventory" | awk -F '|' -v id="$actual_id" -v win="$expected_window" '$3 == id && $2 == win { found=1 } END { exit !found }'; then
            echo "oracle: slot $slot ($actual_id) is not in lease window $expected_window" >&2
            return 1
        fi
    done

    lease_holder="$(tmux -L "$socket" show-option -gqv '@dotfiles_subpane_lease_window' 2>/dev/null || true)"
    [ "$lease_holder" = "$expected_window" ] || {
        echo "oracle: lease holder is ${lease_holder:-none}, expected $expected_window" >&2
        return 1
    }
}

# Stack oracle: the Subpane Slots of one Presenter Window form a stack in the
# dock column whose order never changes (slot 1 on top, slot N at the bottom -
# a top/bottom position swap moves the whole stack, it does not reverse it)
# and whose per-slot heights are the user's last intents.
#   subpane_oracle_assert_stack <socket> <window> <count> <top|bottom> [<h1> <h2> ...]
# Prints "oracle: ..." and dumps the window's panes on the first violation.
subpane_oracle_assert_stack() {
    local socket="$1" window="$2" count="$3" position="$4"
    shift 4
    local -a heights=("$@")
    local panes sidebar_top sidebar_left slots slot_count order expected i slot actual

    panes="$(tmux -L "$socket" list-panes -t "$window" \
        -F '#{pane_id}|#{pane_title}|#{@dotfiles_sidebar_pane}|#{@dotfiles_sidebar_subpane}|#{@dotfiles_subpane_slot}|#{pane_top}|#{pane_left}|#{pane_height}' 2>/dev/null)"
    fail() {
        echo "oracle: $1" >&2
        printf '%s\n' "$panes" | awk -F '|' '{ printf "  %s title=%s sidebar=%s subpane=%s slot=%s top=%s left=%s height=%s\n", $1, $2, $3, $4, $5, $6, $7, $8 }' >&2
        return 1
    }

    sidebar_top="$(printf '%s\n' "$panes" | awk -F '|' '!done && ($2 == "dotfiles-session-sidebar" || $3 == "1") { print $6; done = 1 }')"
    sidebar_left="$(printf '%s\n' "$panes" | awk -F '|' '!done && ($2 == "dotfiles-session-sidebar" || $3 == "1") { print $7; done = 1 }')"
    [ -n "$sidebar_top" ] || { fail "no sidebar pane in $window"; return 1; }

    # slot|top|left|height, sorted by pane_top
    slots="$(printf '%s\n' "$panes" | awk -F '|' '$4 == "1" && $5 ~ /^[0-9]+$/ { print $5 "|" $6 "|" $7 "|" $8 }' | sort -t '|' -k2,2n)"
    slot_count="$(printf '%s\n' "$slots" | grep -c . || true)"
    [ "$slot_count" -eq "$count" ] || { fail "expected $count Subpane Slots in $window, found $slot_count"; return 1; }

    order="$(printf '%s\n' "$slots" | cut -d '|' -f 1 | paste -sd ' ')"
    expected="$(seq 1 "$count" | paste -sd ' ')"
    [ "$order" = "$expected" ] || { fail "slot order top->bottom is [$order], expected [$expected] (position=$position)"; return 1; }

    while IFS='|' read -r slot top left height; do
        [ -n "$slot" ] || continue
        [ "$left" = "$sidebar_left" ] || { fail "slot $slot is at column $left, sidebar column is $sidebar_left"; return 1; }
        actual="${heights[$((slot - 1))]:-}"
        if [ -n "$actual" ] && [ "$height" != "$actual" ]; then
            fail "slot $slot height is $height, expected $actual (position=$position)"; return 1
        fi
        case "$position" in
            top)    [ "$top" -lt "$sidebar_top" ] || { fail "slot $slot (top=$top) is not above the sidebar (top=$sidebar_top) while position=top"; return 1; } ;;
            bottom) [ "$top" -gt "$sidebar_top" ] || { fail "slot $slot (top=$top) is not below the sidebar (top=$sidebar_top) while position=bottom"; return 1; } ;;
        esac
    done <<< "$slots"
    return 0
}
