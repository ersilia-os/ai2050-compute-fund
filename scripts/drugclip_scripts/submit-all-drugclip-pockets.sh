#!/bin/bash
# Submit a DrugCLIP pocket-encoding job for every staged target.
#
# Run on the cluster head node after stage-drugclip-pockets.sh has uploaded the
# pockets (they appear under /fsx/input/targets/<ID>/pockets/).  For each target it
# calls the existing submit-drugclip-pocket.sh with an explicit pocket dir:
#
#   submit-drugclip-pocket.sh <TARGET> /fsx/input/targets/<TARGET>/pockets
#
# Skips targets whose pocket_reps.pkl already exists (unless --force).  Throttles
# on the pending-job count so we never flood the gpu-queue.
#
# Usage:
#   submit-all-drugclip-pockets.sh [--force] [max_pending=20]
#
# Examples:
#   submit-all-drugclip-pockets.sh
#   submit-all-drugclip-pockets.sh --force 8

set -uo pipefail

FORCE=0
MAX_PENDING=20
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        ''|*[!0-9]*) echo "Unknown option: $arg"; exit 1 ;;
        *) MAX_PENDING=$arg ;;
    esac
done

POCKET_BASE="${POCKET_BASE:-/fsx/input/targets}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBMIT="${SCRIPT_DIR}/submit-drugclip-pocket.sh"

if [ ! -d "$POCKET_BASE" ]; then
    echo "ERROR: $POCKET_BASE not found — run stage-drugclip-pockets.sh first"
    exit 1
fi
if [ ! -f "$SUBMIT" ]; then
    echo "ERROR: submit-drugclip-pocket.sh not found next to this script ($SUBMIT)"
    exit 1
fi

POCKET_DIRS=($(ls -d "$POCKET_BASE"/*/pockets 2>/dev/null | sort || true))
if [ ${#POCKET_DIRS[@]} -eq 0 ]; then
    echo "ERROR: no <ID>/pockets dirs under $POCKET_BASE"
    exit 1
fi

echo "=========================================="
echo "Submit all DrugCLIP pocket jobs"
echo "=========================================="
echo "Targets     : ${#POCKET_DIRS[@]}"
echo "Force resubmit: $FORCE"
echo "Max pending : $MAX_PENDING"
echo "=========================================="

SUBMITTED=0
SKIPPED=0
FAILED=0

for PDIR in "${POCKET_DIRS[@]}"; do
    TARGET=$(basename "$(dirname "$PDIR")")

    if [ "$FORCE" -eq 0 ] && [ -f "${PDIR}/pocket_reps.pkl" ]; then
        echo "  SKIP  $TARGET (pocket_reps.pkl already exists)"
        SKIPPED=$(( SKIPPED + 1 ))
        continue
    fi

    # Throttle: wait until pending job count drops below MAX_PENDING
    if [ "$(squeue -u "$USER" -h | wc -l)" -ge "$MAX_PENDING" ]; then
        echo "  Queue at limit ($MAX_PENDING) — waiting..."
        while [ "$(squeue -u "$USER" -h | wc -l)" -ge "$MAX_PENDING" ]; do
            sleep 30
        done
    fi

    echo -n "  Submitting $TARGET ... "
    OUT=$(bash "$SUBMIT" "$TARGET" "$PDIR" 2>&1)
    JOB_ID=$(echo "$OUT" | grep -oP 'Submitted job \K\d+' || true)
    if [ -n "$JOB_ID" ]; then
        echo "job $JOB_ID"
        SUBMITTED=$(( SUBMITTED + 1 ))
    else
        echo "ERROR"
        echo "$OUT" | sed 's/^/      /'
        FAILED=$(( FAILED + 1 ))
    fi
done

echo ""
echo "=========================================="
echo "Submitted: $SUBMITTED   Skipped: $SKIPPED   Failed: $FAILED"
echo "Monitor:   bash ${SCRIPT_DIR}/check-drugclip-pockets.sh"
echo "           watch -n 10 'squeue -u \$USER'"
echo "=========================================="
[ "$FAILED" -eq 0 ]
