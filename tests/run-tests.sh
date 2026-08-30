#!/usr/bin/env bash
# ==============================================================================
# tests/run-tests.sh — test runner
#
# Two lists, no states:
#   tests/ci.list      every push. Every entry must PASS.
#   tests/manual.list  needs the user's tmux server or a live AI process.
#                      Run by a human on purpose.
#
# Rules:
#   - every tests/**/test-*.sh must appear in exactly one list  (else FAIL)
#   - every list entry must exist on disk                        (else FAIL)
#   - a test that exceeds --timeout is a FAIL
# ==============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${REPO_ROOT}/tests"
CI_LIST="${TESTS_DIR}/ci.list"
MANUAL_LIST="${TESTS_DIR}/manual.list"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

MODE="ci"
FAIL_FAST=0
TIMEOUT_S="${TEST_TIMEOUT:-300}"
ONLY=""

usage() {
    cat <<EOF
usage: $0 [--ci | --manual | --health] [-f] [--timeout SEC] [--only PATTERN]

  --ci              run tests/ci.list (default)
  --manual          run tests/manual.list
  --health          check list hygiene only (no tests run)
  -f, --fail-fast   stop at first failure
  --timeout SEC     per-test timeout (default ${TIMEOUT_S}; env TEST_TIMEOUT)
  --only PATTERN    run only list entries matching PATTERN (grep -E)

  env TEST_LOG_DIR  keep every test's full output as <dir>/<test>.log

  Tests run with a fresh HOME (~/.tmux.conf = tests/fixtures/test-tmux.conf)
  and TERM=xterm-256color, so results do not depend on the developer's setup.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ci) MODE="ci"; shift ;;
        --manual) MODE="manual"; shift ;;
        --health) MODE="health"; shift ;;
        -f|--fail-fast) FAIL_FAST=1; shift ;;
        --timeout) TIMEOUT_S="${2:?}"; shift 2 ;;
        --only) ONLY="${2:?}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo -e "${RED}unknown option: $1${NC}" >&2; usage ;;
    esac
done

read_list() {
    # strip comments / blank lines, print entries relative to tests/
    [ -f "$1" ] || return 0
    sed -e 's/#.*$//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"
}

# ------------------------------------------------------------------------------
# health: orphan / missing / duplicate detection
# ------------------------------------------------------------------------------
health_check() {
    local problems=0 entry
    local -A seen=()

    for list in "$CI_LIST" "$MANUAL_LIST"; do
        [ -f "$list" ] || { echo -e "${RED}[HEALTH] list missing: ${list#"$REPO_ROOT/"}${NC}"; problems=$((problems + 1)); continue; }
        while IFS= read -r entry; do
            if [ -n "${seen[$entry]:-}" ]; then
                echo -e "${RED}[HEALTH] listed twice: ${entry}${NC}"; problems=$((problems + 1))
            fi
            seen["$entry"]=1
            if [ ! -f "${TESTS_DIR}/${entry}" ]; then
                echo -e "${RED}[HEALTH] listed but not on disk: ${entry}  (${list##*/})${NC}"; problems=$((problems + 1))
            fi
        done < <(read_list "$list")
    done

    while IFS= read -r entry; do
        if [ -z "${seen[$entry]:-}" ]; then
            echo -e "${RED}[HEALTH] on disk but in no list: ${entry}${NC}"; problems=$((problems + 1))
        fi
    done < <(cd "$TESTS_DIR" && find . -path ./lib -prune -o -type f -name 'test-*.sh' -print | sed 's#^\./##' | sort)

    # Every shell function has exactly one home. A function defined in both a
    # lib module and the core entrypoint is dead in one of them, and lib-only
    # test harnesses would exercise a different body than production runs.
    while IFS= read -r entry; do
        echo -e "${RED}[HEALTH] function defined twice (lib + core): ${entry}${NC}"; problems=$((problems + 1))
    done < <(grep -hoE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$REPO_ROOT/scripts/tmux-session-dock" "$REPO_ROOT"/scripts/lib/*.sh | sort | uniq -d)

    if [ "$problems" -eq 0 ]; then
        echo -e "${GREEN}[HEALTH] ok${NC} — ci: $(read_list "$CI_LIST" | wc -l), manual: $(read_list "$MANUAL_LIST" | wc -l)"
        return 0
    fi
    echo -e "${RED}[HEALTH] ${problems} problem(s)${NC}"
    return 1
}

if [ "$MODE" = "health" ]; then
    health_check; exit $?
fi

health_check || exit 1

# ------------------------------------------------------------------------------
# environment: same on every machine
#   - fresh HOME whose ~/.tmux.conf is tests/fixtures/test-tmux.conf, so a
#     test that starts tmux without -f still gets the fixture, never the
#     developer's config; its ~/.bashrc gives pane shells a plain prompt
#     that does not rewrite pane titles
#   - TERM fixed: CI runners hand out TERM=dumb, which tmux clients reject
#   - TMUX/TMUX_PANE dropped: when the suite is launched from inside tmux the
#     test servers inherit the host's TMUX_PANE (usually %0). Inside a test
#     server %0 is a real pane (often in a session literally named "0"), and
#     the product binds to TMUX_PANE as its own pane, so discovery and restore
#     tests fail only on the developer's box, never in CI
#   - /mnt/* PATH entries dropped: WSL appends the Windows PATH (dozens of
#     /mnt/c/... directories on a 9p mount). A zsh started in a fresh
#     ZDOTDIR stats every PATH directory before its first prompt; on 9p that
#     takes 10-15 s, so subpane shells never answer within a test's budget.
#     Nothing under test needs a Windows binary.
# ------------------------------------------------------------------------------
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/session-dock-test-home.XXXXXX")"
# Every test gets its own HOME under TEST_HOME. The product persists state
# there (~/.local/state/dotfiles/tmux-sidebar-width), so a shared HOME would
# let one test's persisted width leak into the next test's restore.
make_test_home() {
    local home
    home="$(mktemp -d "${TEST_HOME}/home.XXXXXX")"
    cp "${TESTS_DIR}/fixtures/test-tmux.conf" "${home}/.tmux.conf"
    # Shells inside test panes read this. Ubuntu's default bashrc sets the
    # terminal title from the prompt when TERM=xterm*, which overwrites the
    # pane titles the product uses to find its panes (seen on GitHub runners).
    cat > "${home}/.bashrc" <<'BASHRC'
PS1='$ '
PROMPT_COMMAND=
BASHRC
    cp "${home}/.bashrc" "${home}/.bash_profile"
    printf '%s\n' "$home"
}
export TERM=xterm-256color
unset TMUX TMUX_PANE
# A shell started inside a dock-managed tmux may carry DOTFILES_SIDEBAR_* from
# an older dock; a test server started from here would inherit them as its
# initial global environment.
while IFS= read -r _var; do unset "$_var"; done < <(compgen -e DOTFILES_SIDEBAR_ 2>/dev/null || true)
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '^/mnt/' | paste -sd: -)"
export PATH
# Shared AI observer state files and locks go under the per-run HOME instead of
# /tmp, so a test server that dies without cleanup leaves nothing behind.
export TMUX_SESSION_LAUNCHER_LOCK_ROOT="$TEST_HOME/observer-locks"
mkdir -p "$TMUX_SESSION_LAUNCHER_LOCK_ROOT"
trap 'rm -rf "$TEST_HOME"' EXIT

# ------------------------------------------------------------------------------
# run
# ------------------------------------------------------------------------------
LIST_FILE="$CI_LIST"; [ "$MODE" = "manual" ] && LIST_FILE="$MANUAL_LIST"

mapfile -t TEST_LIST < <(read_list "$LIST_FILE" | { if [ -n "$ONLY" ]; then grep -E -- "$ONLY"; else cat; fi; })

echo -e "${BOLD}${CYAN}== ${MODE} (${#TEST_LIST[@]} tests, timeout ${TIMEOUT_S}s, HOME=${TEST_HOME}, $(tmux -V 2>/dev/null || echo 'tmux ?')) ==${NC}"

PASSED=(); FAILED=()
T0=$(date +%s)

now_ms() { local n; n=$(date +%s%N); echo $(( n / 1000000 )); }

# Servers a test leaves behind keep the launcher's background loops alive and
# pile up CPU load across a run (seen: load avg 29 after ~200 leaked servers).
# After each test, kill any server on a socket that did not exist before it,
# plus the processes attached to that socket, and say so.
SOCKET_DIR="/tmp/tmux-$(id -u)"
list_sockets() { find "$SOCKET_DIR" -maxdepth 1 -type s -printf '%f\n' 2>/dev/null | sort; }
sweep_leaked_servers() {
    local rel="$1" before="$2" sock n pid
    while IFS= read -r sock; do
        [ -n "$sock" ] || continue
        tmux -L "$sock" list-sessions >/dev/null 2>&1 || continue
        n="$(tmux -L "$sock" list-sessions 2>/dev/null | wc -l)"
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
        for pid in $(grep -lsz -- "${SOCKET_DIR}/${sock}" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3); do
            [ "$pid" != "$$" ] && kill "$pid" 2>/dev/null || true
        done
        sleep 0.2
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
        echo -e "    ${YELLOW}[LEAK]${NC} left tmux server '${sock}' (${n} sessions) running; killed"
    done < <(comm -13 <(printf '%s\n' "$before") <(list_sockets))
}

for rel in "${TEST_LIST[@]}"; do
    path="${TESTS_DIR}/${rel}"
    echo -n -e "▶ ${rel} ... "
    sockets_before="$(list_sockets)"
    s=$(now_ms)
    if [ -n "${TEST_LOG_DIR:-}" ]; then
        mkdir -p "$TEST_LOG_DIR"
        log="$TEST_LOG_DIR/$(basename "$rel" .sh).log"
    else
        log=$(mktemp)
    fi
    test_home="$(make_test_home)"
    HOME="$test_home" timeout --foreground -k 5 "$TIMEOUT_S" bash "$path" > "$log" 2>&1
    rc=$?
    e=$(now_ms)
    rm -rf "$test_home"
    if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}[PASS]${NC} ($((e - s))ms)"
        PASSED+=("$rel")
    else
        if [ "$rc" -eq 124 ]; then
            echo -e "${RED}[FAIL]${NC} (timeout ${TIMEOUT_S}s)"
        else
            echo -e "${RED}[FAIL]${NC} ($((e - s))ms, rc=$rc)"
        fi
        # Reason first: tests print "FAIL:/ERROR:" then may dump long
        # diagnostics, so a plain tail would hide the reason.
        echo -e "${RED}--- ${rel} reason ---${NC}"
        grep -aE '^(FAIL|ERROR|PRODUCT_[A-Z_]+)[: ]' "$log" | head -n 5 | sed 's/^/    /'
        echo -e "${RED}--- ${rel} (last 15 lines) ---${NC}"
        tail -n 15 "$log" | sed 's/^/    /'
        echo -e "${RED}-----------------------------------${NC}"
        FAILED+=("$rel")
        if [ "$FAIL_FAST" -eq 1 ]; then [ -n "${TEST_LOG_DIR:-}" ] || rm -f "$log"; break; fi
    fi
    [ -n "${TEST_LOG_DIR:-}" ] || rm -f "$log"
    sweep_leaked_servers "$rel" "$sockets_before"
done

T1=$(date +%s)
echo
echo -e "${BOLD}${CYAN}== summary ==${NC}  $((T1 - T0))s  pass ${GREEN}${#PASSED[@]}${NC}  fail ${RED}${#FAILED[@]}${NC}"
if [ ${#FAILED[@]} -gt 0 ]; then
    for f in "${FAILED[@]}"; do echo -e "  ${RED}FAIL${NC} $f"; done
    exit 1
fi
exit 0
