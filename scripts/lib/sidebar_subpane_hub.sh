#!/usr/bin/env bash
# SubpaneHubManager: Global Singleton Subpane Session & Mirror Management
set -euo pipefail

SUBPANE_HUB_SESSION="dotfiles-subpane-hub"
SUBPANE_LEASE_OPTION="@dotfiles_subpane_lease_window"
SUBPANE_COUNT_OPTION="@session-dock-subpane-count"
SUBPANE_KEEPER_OPTION="@dotfiles_subpane_hub_keeper"
SUBPANE_SLOT_PANE_OPTION_PREFIX="@dotfiles_subpane_slot_"
# Hidden tmux environment marker raised while a lease transaction (park to
# the hub, rebuild in a window, position swap) moves slots.  Hook handlers
# run as separate processes and snapshot User Height Intent 50 ms after an
# after-resize-pane; one that lands while slots are half parked reads the
# hub window's heights (or the grown remainder) and records them as intent,
# which the next rebuild then applies (measured: 4/4/4 became 11/5/4).  The
# value is an epoch-second deadline so a crashed transaction cannot block
# snapshots for good.
# The dock builder declares its geometry with the pure functions in
# sidebar_domain.sh. Callers that source this module alone (tests, ad-hoc
# shells) get them here; the bundled dist inlines the domain first.
if ! declare -f sidebar_domain_dock_layout >/dev/null 2>&1; then
    _subpane_hub_domain="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/sidebar_domain.sh"
    [ -r "$_subpane_hub_domain" ] && source "$_subpane_hub_domain"
    unset _subpane_hub_domain
fi

SUBPANE_TRANSACTION_ENV="DOTFILES_SIDEBAR_SUBPANE_TRANSACTION"
SUBPANE_TRANSACTION_TTL_SECONDS=5
_subpane_hub_transaction_depth=0

subpane_hub_transaction_begin() {
    _subpane_hub_transaction_depth=$((_subpane_hub_transaction_depth + 1))
    [ "$_subpane_hub_transaction_depth" -eq 1 ] || return 0
    sidebar_tmux_cmd set-environment -gh "$SUBPANE_TRANSACTION_ENV" \
        "$(( ${EPOCHSECONDS:-$(date +%s)} + SUBPANE_TRANSACTION_TTL_SECONDS ))" 2>/dev/null || true
}

subpane_hub_transaction_end() {
    [ "$_subpane_hub_transaction_depth" -gt 0 ] || return 0
    _subpane_hub_transaction_depth=$((_subpane_hub_transaction_depth - 1))
    [ "$_subpane_hub_transaction_depth" -eq 0 ] || return 0
    sidebar_tmux_cmd set-environment -ghu "$SUBPANE_TRANSACTION_ENV" 2>/dev/null || true
}

# True while another process's lease transaction is in flight.  The owning
# process itself is never blocked (its own snapshots run before it moves
# anything).
subpane_hub_transaction_active() {
    [ "$_subpane_hub_transaction_depth" -eq 0 ] || return 1
    local out deadline
    out="$(sidebar_tmux_cmd show-environment -gh "$SUBPANE_TRANSACTION_ENV" 2>/dev/null || true)"
    case "$out" in ''|-*) return 1 ;; esac
    deadline="${out#*=}"
    case "$deadline" in ''|*[!0-9]*) return 1 ;; esac
    [ "${EPOCHSECONDS:-$(date +%s)}" -le "$deadline" ]
}

subpane_hub_get_count() {
    local cnt
    cnt="$(sidebar_tmux_cmd show-option -gqv "$SUBPANE_COUNT_OPTION" 2>/dev/null || true)"
    case "$cnt" in
        2|3) printf '%s\n' "$cnt" ;;
        *)   printf '1\n' ;;
    esac
}

subpane_hub_set_count() {
    local cnt="${1:-1}"
    case "$cnt" in
        2|3) sidebar_tmux_cmd set-option -gq "$SUBPANE_COUNT_OPTION" "$cnt" 2>/dev/null || true ;;
        *)   sidebar_tmux_cmd set-option -gq "$SUBPANE_COUNT_OPTION" 1 2>/dev/null || true ;;
    esac
}

subpane_hub_get_lease_holder() {
    sidebar_tmux_cmd show-option -gqv "$SUBPANE_LEASE_OPTION" 2>/dev/null || true
}

subpane_hub_acquire_lease() {
    local target_win="${1:-}"
    [ -n "$target_win" ] || return 1
    sidebar_tmux_cmd set-option -gq "$SUBPANE_LEASE_OPTION" "$target_win" 2>/dev/null || true
}

subpane_hub_release_lease() {
    local target_win="${1:-}"
    local current_holder
    current_holder="$(subpane_hub_get_lease_holder)"
    if [ -z "$target_win" ] || [ "$current_holder" = "$target_win" ]; then
        sidebar_tmux_cmd set-option -gu "$SUBPANE_LEASE_OPTION" 2>/dev/null || true
    fi
}

subpane_hub_session_name() {
    printf '%s\n' "$SUBPANE_HUB_SESSION"
}

subpane_hub_default_command() {
    local zdot="${HOME}/.cache/dotfiles"
    if [ -x "/bin/zsh" ]; then
        printf 'exec env ZDOTDIR="%s" /bin/zsh\n' "$zdot"
    else
        printf 'exec env ZDOTDIR="%s" %s\n' "$zdot" "${SHELL:-/bin/bash}"
    fi
}

subpane_hub_keeper_command() {
    printf 'exec sleep 2147483647\n'
}

subpane_hub_slot_title() {
    local slot="$1" count="$2" base="${3:-${SIDEBAR_SUBPANE_TITLE:-dotfiles-sidebar-subpane}}"
    if [ "$count" -eq 1 ]; then
        printf '%s\n' "$base"
    else
        printf '%s-%s\n' "$base" "$slot"
    fi
}

subpane_hub_is_alive() {
    if sidebar_tmux_cmd has-session -t "=$(subpane_hub_session_name):" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

subpane_hub_get_keeper() {
    local hub_sess keeper
    hub_sess="$(subpane_hub_session_name)"
    keeper="$(sidebar_tmux_cmd list-panes -t "=$hub_sess:" -F "#{pane_id}|#{${SUBPANE_KEEPER_OPTION}}" 2>/dev/null |
        awk -F '|' '$2 == "1" { print $1; exit }' || true)"
    [ -n "$keeper" ] || return 1
    printf '%s\n' "$keeper"
}

subpane_hub_slot_pane_option() {
    local slot="${1:-1}"
    printf '%s%s_pane\n' "$SUBPANE_SLOT_PANE_OPTION_PREFIX" "$slot"
}

subpane_hub_register_pane() {
    local slot="$1" pane_id="$2" option
    option="$(subpane_hub_slot_pane_option "$slot")"
    sidebar_tmux_cmd set-option -gq "$option" "$pane_id" 2>/dev/null || return 1
}

subpane_hub_registered_pane() {
    local slot="$1" option pane_id
    option="$(subpane_hub_slot_pane_option "$slot")"
    pane_id="$(sidebar_tmux_cmd show-option -gqv "$option" 2>/dev/null || true)"
    [ -n "$pane_id" ] || return 1
    if sidebar_tmux_cmd display-message -p -t "$pane_id" '#{pane_id}' >/dev/null 2>&1; then
        printf '%s\n' "$pane_id"
        return 0
    fi
    sidebar_tmux_cmd set-option -gu "$option" 2>/dev/null || true
    return 1
}

subpane_hub_ensure_session() {
    local hub_sess keeper cmd created=0
    hub_sess="$(subpane_hub_session_name)"
    if ! subpane_hub_is_alive; then
        cmd="$(subpane_hub_keeper_command)"
        if sidebar_tmux_cmd new-session -d -s "$hub_sess" -n "hub" -x 30 -y 12 "$cmd" 2>/dev/null; then
            created=1
        fi
        sidebar_tmux_cmd set-option -t "=$hub_sess:" remain-on-exit off 2>/dev/null || true
        sidebar_tmux_cmd set-option -s -t "$hub_sess" @dotfiles_sidebar_managed 0 2>/dev/null || true
        sidebar_tmux_cmd set-hook -t "$hub_sess" -u window-linked 2>/dev/null || true
        sidebar_tmux_cmd set-hook -t "$hub_sess" -u window-unlinked 2>/dev/null || true
        sidebar_tmux_cmd set-hook -t "$hub_sess" -u session-created 2>/dev/null || true
        sidebar_tmux_cmd set-hook -t "$hub_sess" -u client-session-changed 2>/dev/null || true
    fi

    keeper="$(subpane_hub_get_keeper 2>/dev/null || true)"
    if [ -z "$keeper" ]; then
        if [ "$created" -eq 1 ]; then
            keeper="$(sidebar_tmux_cmd list-panes -t "=$hub_sess:" -F '#{pane_id}' 2>/dev/null | head -n 1 || true)"
        else
            cmd="$(subpane_hub_keeper_command)"
            keeper="$(sidebar_tmux_cmd new-window -d -t "=$hub_sess:" -n keeper -P -F '#{pane_id}' "$cmd" 2>/dev/null || true)"
        fi
    fi
    [ -n "$keeper" ] || return 1
    sidebar_tmux_cmd set-option -p -q -t "$keeper" "$SUBPANE_KEEPER_OPTION" 1 2>/dev/null || return 1
    sidebar_tmux_cmd set-option -p -q -u -t "$keeper" @dotfiles_subpane_hub_pane 2>/dev/null || true
    sidebar_tmux_cmd set-option -p -q -u -t "$keeper" @dotfiles_sidebar_subpane 2>/dev/null || true
    sidebar_tmux_cmd set-option -p -q -u -t "$keeper" @dotfiles_subpane_slot 2>/dev/null || true
    sidebar_tmux_cmd set-option -p -q -t "$keeper" allow-rename off 2>/dev/null || true
    sidebar_tmux_cmd select-pane -t "$keeper" -T dotfiles-subpane-hub-keeper 2>/dev/null || true
}

subpane_hub_get_pane() {
    local slot="${1:-1}"
    local pane_id resolve_count resolved
    pane_id="$(subpane_hub_registered_pane "$slot" 2>/dev/null || true)"
    if [ -n "$pane_id" ]; then
        printf '%s\n' "$pane_id"
        return 0
    fi

    resolve_count="$(subpane_hub_get_count)"
    [ "$resolve_count" -ge "$slot" ] 2>/dev/null || resolve_count="$slot"
    resolved="$(subpane_hub_resolve_pool "$resolve_count")" || return 1
    pane_id="$(printf '%s\n' "$resolved" | awk -F '|' -v slot="$slot" '$1 == slot { print $2; exit }')"
    [ -n "$pane_id" ] || return 1
    printf '%s\n' "$pane_id"
}

subpane_hub_get_window_subpanes() {
    local target_win="${1:-}"
    [ -n "$target_win" ] || target_win="$(sidebar_tmux_cmd display-message -p '#{window_id}' 2>/dev/null || true)"
    [ -n "$target_win" ] || return 0

    sidebar_tmux_cmd list-panes -t "$target_win" -F '#{pane_id}|#{@dotfiles_sidebar_subpane}|#{@dotfiles_subpane_slot}' 2>/dev/null |
        awk -F '|' '$2 == "1" { print ($3 ? $3 : 1) "|" $1 }' |
        sort -n -t '|' -k 1 |
        cut -d '|' -f 2
}

# Capture the live User Height Intent for the leased stack by canonical slot,
# not by whichever pane happens to be observed first. This is the single
# snapshot seam used before Enter, Sidebar OFF, and position transitions.
subpane_hub_snapshot_user_intent() {
    local target_win="${1:-}"
    [ -n "$target_win" ] || return 0
    # Slots are moving: whatever this process would measure now is transaction
    # geometry, not the user's.
    subpane_hub_transaction_active && return 0

    local total_h=0 slot pane height captured=0
    while IFS='|' read -r slot pane; do
        [ -n "$slot" ] && [ -n "$pane" ] || continue
        height="$(sidebar_tmux_cmd display-message -p -t "$pane" '#{pane_height}' 2>/dev/null || true)"
        case "$height" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "$height" -ge 2 ] 2>/dev/null || continue
        sidebar_tmux_cmd set-option -gq "@dotfiles_subpane_slot_${slot}_height" "$height" 2>/dev/null || return 1
        total_h=$((total_h + height))
        captured=1
    done < <(sidebar_tmux_cmd list-panes -t "$target_win" \
        -F '#{@dotfiles_subpane_slot}|#{pane_id}|#{@dotfiles_sidebar_subpane}' 2>/dev/null |
        awk -F '|' '$3 == "1" && $1 ~ /^[1-9][0-9]*$/ { print $1 "|" $2 }' |
        sort -t '|' -k1,1n)

    if [ "$captured" -eq 1 ] && [ "$total_h" -ge 4 ]; then
        sidebar_tmux_cmd set-option -gq "${SIDEBAR_SUBPANE_HEIGHT_OPTION:-@dotfiles_sidebar_subpane_height}" "$total_h" 2>/dev/null || return 1
        persist_sidebar_subpane_height "$total_h" 2>/dev/null || true
        printf '%s\n' "$total_h"
        return 0
    fi
    return 0
}

subpane_hub_pool_snapshot() {
    sidebar_tmux_cmd list-panes -a \
        -F '#{pane_id}|#{window_id}|#{session_name}|#{@dotfiles_subpane_slot}|#{@dotfiles_sidebar_subpane}|#{@dotfiles_subpane_hub_keeper}' \
        2>/dev/null || true
}

# Resolve one canonical pane per Subpane Slot from a single server snapshot.
# A registered pane wins. Without a registry entry, the current lease window
# disambiguates legacy duplicates; otherwise ambiguous state fails closed.
subpane_hub_resolve_pool() {
    local max_count="${1:-}"
    [ -n "$max_count" ] || max_count="$(subpane_hub_get_count)"
    subpane_hub_ensure_session || return 1

    local snapshot lease_holder hub_sess slot
    snapshot="$(subpane_hub_pool_snapshot)"
    lease_holder="$(subpane_hub_get_lease_holder)"
    hub_sess="$(subpane_hub_session_name)"

    for ((slot=1; slot<=max_count; slot++)); do
        local canonical registered candidate_count lease_count cmd
        local candidates=() lease_candidates=()
        registered="$(subpane_hub_registered_pane "$slot" 2>/dev/null || true)"
        if [ -n "$registered" ] && printf '%s\n' "$snapshot" | awk -F '|' -v pane="$registered" '$1 == pane { found=1 } END { exit !found }'; then
            canonical="$registered"
        else
            mapfile -t candidates < <(printf '%s\n' "$snapshot" |
                awk -F '|' -v slot="$slot" '$4 == slot && $6 != "1" { print $1 }')
            candidate_count="${#candidates[@]}"
            case "$candidate_count" in
                0)
                    cmd="$(subpane_hub_default_command)"
                    canonical="$(sidebar_tmux_cmd new-window -d -t "=$hub_sess:" -P -F '#{pane_id}' "$cmd" 2>/dev/null || true)"
                    [ -n "$canonical" ] || return 1
                    ;;
                1)
                    canonical="${candidates[0]}"
                    ;;
                *)
                    if [ -n "$lease_holder" ]; then
                        mapfile -t lease_candidates < <(printf '%s\n' "$snapshot" |
                            awk -F '|' -v slot="$slot" -v win="$lease_holder" '$2 == win && $4 == slot && $6 != "1" { print $1 }')
                    fi
                    lease_count="${#lease_candidates[@]}"
                    [ "$lease_count" -eq 1 ] || return 1
                    canonical="${lease_candidates[0]}"
                    ;;
            esac
            subpane_hub_register_pane "$slot" "$canonical" || return 1
        fi

        sidebar_tmux_cmd set-option -p -q -t "$canonical" @dotfiles_subpane_hub_pane 1 2>/dev/null || return 1
        sidebar_tmux_cmd set-option -p -q -t "$canonical" @dotfiles_sidebar_subpane 1 2>/dev/null || return 1
        sidebar_tmux_cmd set-option -p -q -t "$canonical" @dotfiles_subpane_slot "$slot" 2>/dev/null || return 1
        sidebar_tmux_cmd set-option -p -q -u -t "$canonical" "$SUBPANE_KEEPER_OPTION" 2>/dev/null || true
        sidebar_tmux_cmd set-option -p -q -t "$canonical" allow-rename off 2>/dev/null || true
        sidebar_tmux_cmd select-pane -t "$canonical" -T "$(subpane_hub_slot_title "$slot" "$max_count")" 2>/dev/null || true

        # A canonical identity is now unambiguous. Remove bug-created duplicate
        # terminals so pane/process count remains bounded across migrations.
        local duplicate
        while IFS= read -r duplicate; do
            [ -n "$duplicate" ] || continue
            [ "$duplicate" = "$canonical" ] && continue
            sidebar_tmux_cmd kill-pane -t "$duplicate" 2>/dev/null || return 1
        done < <(printf '%s\n' "$snapshot" |
            awk -F '|' -v slot="$slot" '$4 == slot && $6 != "1" { print $1 }')

        printf '%s|%s\n' "$slot" "$canonical"
    done
}

subpane_hub_swap_stack_position() {
    local target_win="${1:-}"
    [ -n "$target_win" ] || target_win="$(sidebar_tmux_cmd display-message -p '#{window_id}' 2>/dev/null || true)"
    [ -n "$target_win" ] || return 1

    local launcher_pane
    launcher_pane="$(sidebar_window_pane "$target_win" 2>/dev/null || true)"
    [ -n "$launcher_pane" ] || return 1

    # Position changes use the same lease transaction as Enter and Sidebar
    # OFF/ON. Park the canonical pool once, then let atomic_migrate rebuild the
    # stack from slot intents instead of maintaining a second join algorithm.
    # A resize hook normally records the intent before this command runs. Do
    # one live capture only when the canonical slots have no usable intent;
    # otherwise a one-row tmux border difference would become the next
    # transaction's preference and drift on every repeated swap.
    local transaction_count transaction_slot transaction_intent
    local transaction_has_intent=1
    transaction_count="$(subpane_hub_get_count)"
    for transaction_slot in $(seq 1 "$transaction_count"); do
        transaction_intent="$(sidebar_tmux_cmd show-option -gqv "@dotfiles_subpane_slot_${transaction_slot}_height" 2>/dev/null || true)"
        if ! [[ "$transaction_intent" =~ ^[0-9]+$ ]] || [ "$transaction_intent" -lt 2 ]; then
            transaction_has_intent=0
            break
        fi
    done
    if [ "$transaction_has_intent" -eq 0 ]; then
        subpane_hub_snapshot_user_intent "$target_win" >/dev/null 2>&1 || return 1
    fi

    local transaction_pos transaction_new_pos transaction_hub transaction_pane
    transaction_pos="$(sidebar_subpane_get_position)"
    transaction_new_pos="bottom"
    [ "$transaction_pos" = "top" ] || transaction_new_pos="top"
    sidebar_subpane_set_position "$transaction_new_pos"
    transaction_hub="$(subpane_hub_session_name)"
    subpane_hub_ensure_session || return 1
    subpane_hub_transaction_begin
    local transaction_rc=0
    while IFS= read -r transaction_pane; do
        [ -n "$transaction_pane" ] || continue
        sidebar_tmux_cmd join-pane -d -s "$transaction_pane" -t "=$transaction_hub:" -v 2>/dev/null || { transaction_rc=1; break; }
    done < <(subpane_hub_get_window_subpanes "$target_win")
    if [ "$transaction_rc" -eq 0 ]; then
        subpane_hub_release_lease "$target_win"
        local transaction_total
        transaction_total="$(sidebar_tmux_cmd show-option -gqv "${SIDEBAR_SUBPANE_HEIGHT_OPTION:-@dotfiles_sidebar_subpane_height}" 2>/dev/null || true)"
        subpane_hub_atomic_migrate "$launcher_pane" "$transaction_total" >/dev/null || transaction_rc=1
    fi
    subpane_hub_transaction_end
    return "$transaction_rc"
}

# ==============================================================================
# subpane_hub_sweep_ghosts: Remove any extra subpane markers from a window that
# are NOT registered hub slots. Protects against ghost pane accumulation.
# ==============================================================================
subpane_hub_sweep_ghosts() {
    local target_win="${1:-}"
    [ -n "$target_win" ] || return 0

    local max_count
    max_count="$(subpane_hub_get_count)"

    # Collect IDs of all legitimate hub slot panes (currently parked anywhere)
    local legitimate_ids=" "
    local slot
    for slot in $(seq 1 "${max_count}"); do
        local sp
        sp="$(subpane_hub_get_pane "$slot" || true)"
        [ -n "$sp" ] && legitimate_ids="$legitimate_ids $sp "
    done

    # Any pane in the target window marked as subpane but NOT a legitimate slot => ghost
    local p_id
    while IFS= read -r p_id; do
        [ -n "$p_id" ] || continue
        if [[ "$legitimate_ids" != *" $p_id "* ]]; then
            # Remove subpane marker and move to hub to prevent layout damage
            sidebar_tmux_cmd set-option -p -q -u -t "$p_id" @dotfiles_sidebar_subpane 2>/dev/null || true
            sidebar_tmux_cmd set-option -p -q -u -t "$p_id" @dotfiles_subpane_slot 2>/dev/null || true
            local hub_sess
            hub_sess="$(subpane_hub_session_name)"
            if subpane_hub_is_alive; then
                sidebar_tmux_cmd join-pane -d -s "$p_id" -t "=$hub_sess:" 2>/dev/null || true
            fi
        fi
    done < <(sidebar_tmux_cmd list-panes -t "$target_win" \
        -F '#{pane_id}|#{@dotfiles_sidebar_subpane}' 2>/dev/null \
        | awk -F '|' '$2 == "1" { print $1 }')
}

# ==============================================================================
# subpane_hub_atomic_migrate: canonical direct lease movement.
# Resolve and reconcile the Subpane Pool once, then move each canonical slot
# directly from its current window to the target without an intermediate redraw.
# ==============================================================================
subpane_hub_atomic_migrate() {
    # The marker is raised inside the body, right before the first join, so a
    # no-op call (slots already attached) never blocks anyone's snapshot.
    local migrate_rc=0
    subpane_hub_atomic_migrate_body "$@" || migrate_rc=$?
    subpane_hub_transaction_end
    return "$migrate_rc"
}

subpane_hub_atomic_migrate_body() {
    local target_launcher="$1"
    local height="${2:-}" sub_title="${3:-dotfiles-sidebar-subpane}"
    [ -n "$target_launcher" ] || return 1

    local max_count
    max_count="$(subpane_hub_get_count)"
    [ -n "$max_count" ] || max_count=1

    local target_win
    target_win="$(sidebar_tmux_cmd display-message -p -t "$target_launcher" '#{window_id}' 2>/dev/null || true)"
    [ -n "$target_win" ] || return 1
    local target_rows
    target_rows="$(sidebar_tmux_cmd display-message -p -t "$target_win" '#{window_height}' 2>/dev/null || echo 0)"
    case "$target_rows" in ''|*[!0-9]*) target_rows=0 ;; esac

    local sub_pos="bottom"
    if declare -f sidebar_subpane_get_position >/dev/null 2>&1; then
        sub_pos="$(sidebar_subpane_get_position 2>/dev/null || echo bottom)"
    fi

    local current_holder
    current_holder="$(subpane_hub_get_lease_holder)"
    if [ -n "$current_holder" ] && [ "$current_holder" != "$target_win" ] &&
        declare -f remember_sidebar_subpane_height_for_window >/dev/null 2>&1; then
        remember_sidebar_subpane_height_for_window "$current_holder" 2>/dev/null || true
    fi

    local resolved
    resolved="$(subpane_hub_resolve_pool "$max_count")" || return 1

    # Use default height only if no session-level saved height exists yet.
    # tmux restart clears global options -> back to default.
    local default_slot_h=14
    if [ -z "$height" ]; then
        if declare -f sidebar_subpane_get_height >/dev/null 2>&1; then
            local saved_h
            saved_h="$(sidebar_subpane_get_height 2>/dev/null || true)"
            [ -n "$saved_h" ] && [ "$saved_h" -ge 4 ] 2>/dev/null && height="$saved_h"
        fi
        [ -n "$height" ] || height=$((default_slot_h * max_count))
    fi

    local resolved_panes=() resolved_heights=() resolved_defaulted=()
    local slot sp
    while IFS='|' read -r slot sp; do
        [ -n "$slot" ] && [ -n "$sp" ] || continue

        # Prefer session-scoped saved height; fall back to equal division.
        local slot_h slot_defaulted=0
        slot_h="$(sidebar_tmux_cmd show-option -gqv "@dotfiles_subpane_slot_${slot}_height" 2>/dev/null || true)"
        if [ -z "$slot_h" ] || ! [ "$slot_h" -ge 2 ] 2>/dev/null; then
            slot_h="$((height / max_count))"
            [ "$slot_h" -ge 4 ] || slot_h=4
            slot_defaulted=1
        fi

        resolved_panes+=("$sp")
        resolved_heights+=("$slot_h")
        resolved_defaulted+=("$slot_defaulted")
    done <<< "$resolved"

    local total_slots="${#resolved_panes[@]}"
    [ "$total_slots" -gt 0 ] || return 1

    local already_attached=1 current_win
    for sp in "${resolved_panes[@]}"; do
        current_win="$(sidebar_tmux_cmd display-message -p -t "$sp" '#{window_id}' 2>/dev/null || true)"
        if [ "$current_win" != "$target_win" ]; then
            already_attached=0
            break
        fi
    done
    # An already attached stack still gets its geometry re-declared below when
    # it no longer matches (tmux scales a layout when a window built while
    # detached is first shown on a client); only the joins are skipped.

    subpane_hub_transaction_begin
    if declare -f set_sidebar_layout_hook_guard >/dev/null 2>&1; then
        set_sidebar_layout_hook_guard 500
    fi

    # Geometry is declared once for the whole window (sidebar_domain_dock_layout)
    # and applied with a single select-layout; the joins below only fix pane
    # order (tmux assigns layout leaves in pane-list order). The dock must be
    # the head of the pane list for that assignment to hold; otherwise fall
    # back to joins only and let tmux size the stack.
    local head_pane layout dock_width edge body checksum_layout=""
    head_pane="$(sidebar_tmux_cmd list-panes -t "$target_win" -F '#{pane_id}' 2>/dev/null | head -n 1)"
    if [ "$head_pane" = "$target_launcher" ]; then
        layout="$(sidebar_tmux_cmd display-message -p -t "$target_win" '#{window_layout}' 2>/dev/null || true)"
        dock_width="$(sidebar_tmux_cmd display-message -p -t "$target_launcher" '#{pane_width}' 2>/dev/null || true)"
        edge="none"
        if declare -f sidebar_port_dock_border_edge >/dev/null 2>&1; then
            edge="$(sidebar_port_dock_border_edge "$target_win")"
        fi
        # The budget only shapes THIS window's layout. The slot intents keep
        # their requested values: a window that is still detached (24 rows)
        # must not shrink what the user asked for once it is shown at 40.
        local -a budgeted=()
        if mapfile -t budgeted < <(sidebar_domain_dock_budget "$target_rows" "$sub_pos" "$edge" "${resolved_heights[@]}") &&
            [ "${#budgeted[@]}" -eq "$total_slots" ]; then
            if body="$(sidebar_domain_dock_layout "$layout" "$dock_width" "$sub_pos" "$edge" "${budgeted[@]}")"; then
                checksum_layout="$(sidebar_domain_layout_checksum "$body")"
            elif declare -f trace_event >/dev/null 2>&1; then
                trace_event "subpane.dock.layout.skip reason=not-a-dock-window window=$target_win layout=$layout"
            fi
        elif declare -f trace_event >/dev/null 2>&1; then
            trace_event "subpane.dock.layout.skip reason=budget rows=$target_rows heights=${resolved_heights[*]}"
        fi
    elif declare -f trace_event >/dev/null 2>&1; then
        trace_event "subpane.dock.layout.skip reason=pane-order head=$head_pane launcher=$target_launcher"
    fi

    # One compound tmux call: chained joins (slot 1 next to the launcher, -b
    # above it for a top stack; slot k right after slot k-1), then the layout.
    local -a cmd=()
    local prev="$target_launcher" first_pane="" sp slot_h idx
    for ((idx=0; idx<total_slots; idx++)); do
        sp="${resolved_panes[$idx]}"
        current_win="$(sidebar_tmux_cmd display-message -p -t "$sp" '#{window_id}' 2>/dev/null || true)"
        if [ "$current_win" != "$target_win" ]; then
            [ "${#cmd[@]}" -eq 0 ] || cmd+=(\;)
            if [ "$idx" -eq 0 ] && [ "$sub_pos" = "top" ]; then
                cmd+=(join-pane -d -b -v -s "$sp" -t "$prev")
            else
                cmd+=(join-pane -d -v -s "$sp" -t "$prev")
            fi
        fi
        prev="$sp"
        [ -z "$first_pane" ] && first_pane="$sp"
    done
    if [ -n "$checksum_layout" ]; then
        # Skip the (redundant) relayout when nothing moves and the window
        # already shows exactly this geometry.
        if [ "${#cmd[@]}" -gt 0 ] || [ "$(sidebar_domain_layout_body "$layout")" != "$body" ]; then
            [ "${#cmd[@]}" -eq 0 ] || cmd+=(\;)
            cmd+=(select-layout -t "$target_win" "$checksum_layout")
        fi
    fi
    if declare -f trace_event >/dev/null 2>&1; then
        trace_event "subpane.dock.layout window=$target_win rows=$target_rows edge=${edge:-?} position=$sub_pos heights=${resolved_heights[*]} joins=$(( ${#cmd[@]} > 0 )) declared=$([ -n "$checksum_layout" ] && echo 1 || echo 0) body=${body:-none}"
    fi
    if [ "${#cmd[@]}" -gt 0 ]; then
        sidebar_tmux_cmd "${cmd[@]}" 2>/dev/null || return 1
    fi

    for ((idx=0; idx<total_slots; idx++)); do
        sp="${resolved_panes[$idx]}"
        slot_h="${resolved_heights[$idx]}"
        sidebar_tmux_cmd set-option -p -q -t "$sp" allow-rename off 2>/dev/null || true
        sidebar_tmux_cmd select-pane -t "$sp" -T "$(subpane_hub_slot_title "$((idx + 1))" "$total_slots" "$sub_title")" 2>/dev/null || true
        sidebar_tmux_cmd set-option -p -q -t "$sp" @dotfiles_subpane_hub_pane 1 2>/dev/null || true
        sidebar_tmux_cmd set-option -p -q -t "$sp" @dotfiles_sidebar_subpane 1 2>/dev/null || true
        sidebar_tmux_cmd set-option -p -q -t "$sp" @dotfiles_subpane_slot "$((idx + 1))" 2>/dev/null || true
        # Record an intent only where none existed (equal division of the
        # total). Re-writing a saved intent here would let a no-op rebuild
        # clobber a newer user height recorded while this call was running.
        if [ "${resolved_defaulted[$idx]:-0}" = "1" ]; then
            sidebar_tmux_cmd set-option -gq "@dotfiles_subpane_slot_$((idx + 1))_height" "$slot_h" 2>/dev/null || true
        fi
    done

    subpane_hub_acquire_lease "$target_win"
    printf '%s\n' "${first_pane:-$target_launcher}"
}

subpane_hub_acquire_pane() {
    local target_launcher="$1" height="${2:-}" sub_title="${3:-dotfiles-sidebar-subpane}"
    [ -n "$target_launcher" ] || return 1
    subpane_hub_atomic_migrate "$target_launcher" "$height" "$sub_title"
}

subpane_hub_release_pane() {
    # The body raises the marker before the first join; a call that finds no
    # slot to park never blocks anyone's snapshot.
    local release_rc=0
    subpane_hub_release_pane_body "$@" || release_rc=$?
    subpane_hub_transaction_end
    return "$release_rc"
}

subpane_hub_release_pane_body() {
    local sub_pane="${1:-}"
    local target_win=""
    if [ -n "$sub_pane" ]; then
        target_win="$(sidebar_tmux_cmd display-message -p -t "$sub_pane" '#{window_id}' 2>/dev/null || true)"
    fi
    [ -n "$target_win" ] || target_win="$(sidebar_tmux_cmd display-message -p '#{window_id}' 2>/dev/null || true)"
    [ -n "$target_win" ] && subpane_hub_release_lease "$target_win"

    local hub_sess keeper
    hub_sess="$(subpane_hub_session_name)"
    subpane_hub_ensure_session || return 1
    keeper="$(subpane_hub_get_keeper)" || return 1

    # Find all subpanes in the target window or server and return to hub
    local p_id p_win p_sess release_started=0
    while IFS='|' read -r p_id p_win p_sess; do
        [ -n "$p_id" ] || continue
        [ "$p_sess" != "$hub_sess" ] || continue
        if [ "$release_started" -eq 0 ]; then
            subpane_hub_transaction_begin
            release_started=1
        fi
        sidebar_tmux_cmd set-option -p -q -t "$p_id" @dotfiles_subpane_hub_pane 1 2>/dev/null || true
        sidebar_tmux_cmd set-option -p -q -t "$p_id" @dotfiles_sidebar_subpane 1 2>/dev/null || true
        sidebar_tmux_cmd join-pane -d -s "$p_id" -t "$keeper" -v 2>/dev/null || return 1
    done < <(sidebar_tmux_cmd list-panes -a -F '#{pane_id}|#{window_id}|#{session_name}|#{@dotfiles_sidebar_subpane}' 2>/dev/null | awk -F '|' '$4 == "1" { print $1"|"$2"|"$3 }')
}

subpane_hub_destroy() {
    local slot slot_pane
    while IFS= read -r slot_pane; do
        [ -n "$slot_pane" ] || continue
        sidebar_tmux_cmd kill-pane -t "$slot_pane" 2>/dev/null || true
    done < <(sidebar_tmux_cmd list-panes -a -F '#{pane_id}|#{@dotfiles_sidebar_subpane}' 2>/dev/null |
        awk -F '|' '$2 == "1" { print $1 }')
    if subpane_hub_is_alive; then
        sidebar_tmux_cmd kill-session -t "=$(subpane_hub_session_name):" 2>/dev/null || true
    fi
    for slot in 1 2 3; do
        sidebar_tmux_cmd set-option -gu "$(subpane_hub_slot_pane_option "$slot")" 2>/dev/null || true
    done
    sidebar_tmux_cmd set-option -gu "$SUBPANE_LEASE_OPTION" 2>/dev/null || true
}
