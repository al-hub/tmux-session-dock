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
# run
# ------------------------------------------------------------------------------
LIST_FILE="$CI_LIST"; [ "$MODE" = "manual" ] && LIST_FILE="$MANUAL_LIST"

mapfile -t TEST_LIST < <(read_list "$LIST_FILE" | { if [ -n "$ONLY" ]; then grep -E -- "$ONLY"; else cat; fi; })

echo -e "${BOLD}${CYAN}== ${MODE} (${#TEST_LIST[@]} tests, timeout ${TIMEOUT_S}s) ==${NC}"

PASSED=(); FAILED=()
T0=$(date +%s)

now_ms() { local n; n=$(date +%s%N); echo $(( n / 1000000 )); }

for rel in "${TEST_LIST[@]}"; do
    path="${TESTS_DIR}/${rel}"
    echo -n -e "▶ ${rel} ... "
    s=$(now_ms)
    log=$(mktemp)
    timeout --foreground -k 5 "$TIMEOUT_S" bash "$path" > "$log" 2>&1
    rc=$?
    e=$(now_ms)
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
        if [ "$FAIL_FAST" -eq 1 ]; then rm -f "$log"; break; fi
    fi
    rm -f "$log"
done

T1=$(date +%s)
echo
echo -e "${BOLD}${CYAN}== summary ==${NC}  $((T1 - T0))s  pass ${GREEN}${#PASSED[@]}${NC}  fail ${RED}${#FAILED[@]}${NC}"
if [ ${#FAILED[@]} -gt 0 ]; then
    for f in "${FAILED[@]}"; do echo -e "  ${RED}FAIL${NC} $f"; done
    exit 1
fi
exit 0
