#!/bin/bash
# Status report for the DrugCLIP pocket-encoding runs.
#
# Run on the cluster head node.  For every target under /fsx/input/targets/<ID>/pockets
# it reports one of:
#   DONE          pocket_reps.pkl present and encodes all expected conformations
#   PARTIAL       pkl present but fewer conformations than *_LIG.pdb inputs
#   RUNNING       a drugclip-pocket-<ID> job is currently running
#   PENDING       a drugclip-pocket-<ID> job is queued
#   FAILED        no/short pkl, no active job, but a job log mentions this target
#   NOT SUBMITTED no pkl, no active job, no log
#
# Usage:
#   check-drugclip-pockets.sh
#   watch -n 60 'bash /shared/scripts/drugclip_scripts/check-drugclip-pockets.sh'

set -uo pipefail

POCKET_BASE="${POCKET_BASE:-/fsx/input/targets}"
LOG_DIR="${LOG_DIR:-/shared/logs}"
PY="${PY:-/shared/python39/bin/python3.9}"

if [ ! -d "$POCKET_BASE" ]; then
    echo "ERROR: $POCKET_BASE not found"
    exit 1
fi

# ── Snapshot the queue: map "drugclip-pocket-<TARGET>" -> state ────────────────
declare -A JOB_STATE
while IFS='|' read -r name state; do
    case "$name" in
        drugclip-pocket-*) JOB_STATE[${name#drugclip-pocket-}]="$state" ;;
    esac
done < <(squeue -u "$USER" -h -o "%j|%T" 2>/dev/null)

POCKET_DIRS=($(ls -d "$POCKET_BASE"/*/pockets 2>/dev/null | sort || true))
if [ ${#POCKET_DIRS[@]} -eq 0 ]; then
    echo "No targets found under $POCKET_BASE"
    exit 0
fi

n_done=0; n_partial=0; n_running=0; n_pending=0; n_failed=0; n_notsub=0

printf "%-10s %9s %9s   %s\n" "TARGET" "EXPECTED" "ENCODED" "STATUS"
printf "%-10s %9s %9s   %s\n" "------" "--------" "-------" "------"

for PDIR in "${POCKET_DIRS[@]}"; do
    TARGET=$(basename "$(dirname "$PDIR")")
    PKL="${PDIR}/pocket_reps.pkl"

    EXPECTED=$(ls "$PDIR"/*_LIG.pdb 2>/dev/null | wc -l)
    ENCODED="-"
    STATUS=""

    if [ -f "$PKL" ]; then
        ENCODED=$("$PY" - "$PKL" 2>/dev/null <<'PYEOF'
import pickle, sys
try:
    with open(sys.argv[1], "rb") as f:
        names, reps = pickle.load(f)
    print(len(names))
except Exception:
    print("ERR")
PYEOF
)
        if [ "$ENCODED" = "ERR" ]; then
            STATUS="FAILED"; n_failed=$(( n_failed + 1 ))
        elif [ "$ENCODED" -ge "$EXPECTED" ] 2>/dev/null && [ "$EXPECTED" -gt 0 ]; then
            STATUS="DONE"; n_done=$(( n_done + 1 ))
        else
            STATUS="PARTIAL"; n_partial=$(( n_partial + 1 ))
        fi
    elif [ -n "${JOB_STATE[$TARGET]:-}" ]; then
        case "${JOB_STATE[$TARGET]}" in
            RUNNING|COMPLETING) STATUS="RUNNING"; n_running=$(( n_running + 1 )) ;;
            *)                  STATUS="PENDING"; n_pending=$(( n_pending + 1 )) ;;
        esac
    else
        if grep -qE "Target[[:space:]]*: ${TARGET}\$" "$LOG_DIR"/drugclip-pocket-*.out 2>/dev/null; then
            STATUS="FAILED"; n_failed=$(( n_failed + 1 ))
        else
            STATUS="NOT SUBMITTED"; n_notsub=$(( n_notsub + 1 ))
        fi
    fi

    printf "%-10s %9s %9s   %s\n" "$TARGET" "$EXPECTED" "$ENCODED" "$STATUS"
done

echo "-------------------------------------------------"
printf "Total: %d | DONE %d | PARTIAL %d | RUNNING %d | PENDING %d | FAILED %d | NOT SUBMITTED %d\n" \
    "${#POCKET_DIRS[@]}" "$n_done" "$n_partial" "$n_running" "$n_pending" "$n_failed" "$n_notsub"

if [ "$n_failed" -gt 0 ] || [ "$n_partial" -gt 0 ]; then
    echo ""
    echo "Re-run a target (clears stale intermediates first):"
    echo "  rm -f ${POCKET_BASE}/<ID>/pockets/pocket.lmdb ${POCKET_BASE}/<ID>/pockets/pocket_reps.pkl"
    echo "  bash $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/submit-drugclip-pocket.sh <ID> ${POCKET_BASE}/<ID>/pockets"
fi
