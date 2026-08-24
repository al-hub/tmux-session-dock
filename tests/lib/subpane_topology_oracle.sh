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
        actual_id="$(printf '%s\n' "$inventory" | awk -F '|' -v slot="$slot" '$5 == "1" && $6 == slot { print $3; exit }')"
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
