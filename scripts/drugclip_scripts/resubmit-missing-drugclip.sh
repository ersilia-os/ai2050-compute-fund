#!/bin/bash
# Resubmit missing or mismatched DrugCLIP chunks for a library.
#
# Usage:
#   bash /shared/scripts/drugclip/resubmit-missing-drugclip.sh <library_name> [queue]
#
# Examples:
#   bash /shared/scripts/drugclip/resubmit-missing-drugclip.sh Enamine_Hit_Locator_460K
#   bash /shared/scripts/drugclip/resubmit-missing-drugclip.sh Molport_Screening_Compounds_5.3M gpu-queue

LIBRARY_NAME=$1
QUEUE=${2:-gpu-queue}

if [ -z "$LIBRARY_NAME" ]; then
    echo "Usage: $0 <library_name> [queue]"
    echo "Example: $0 Enamine_Hit_Locator_460K gpu-queue"
    exit 1
fi

INPUT_DIR="/fsx/input/${LIBRARY_NAME}"
OUTPUT_DIR="/fsx/output/${LIBRARY_NAME}/drugclip"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory not found: $INPUT_DIR"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "=========================================="
echo "Scanning for missing/mismatched chunks"
echo "Library : $LIBRARY_NAME"
echo "Queue   : $QUEUE"
echo "=========================================="

# ── Build missing list ────────────────────────────────────────────────────────
MISSING_LIST="${OUTPUT_DIR}/chunk_list_missing.txt"
> "$MISSING_LIST"

for INPUT_FILE in $(ls "${INPUT_DIR}"/*_chunk_*.csv 2>/dev/null | sort); do
    CHUNK_NUM=$(basename "$INPUT_FILE" .csv | grep -oP '\d+$')
    OUTPUT_FILE="${OUTPUT_DIR}/${LIBRARY_NAME}_drugclip_${CHUNK_NUM}.h5"

    if [ ! -f "$OUTPUT_FILE" ]; then
        echo "  MISSING  : chunk_${CHUNK_NUM}"
        echo "$INPUT_FILE" >> "$MISSING_LIST"
        continue
    fi

    # Check embedding count vs input row count
    IN_ROWS=$(( $(wc -l < "$INPUT_FILE") - 1 ))
    OUT_ROWS=$(/shared/python39/bin/python3.9 -c "
import h5py, sys
try:
    with h5py.File('${OUTPUT_FILE}', 'r') as f:
        print(f['embeddings'].shape[0] if 'embeddings' in f else f.attrs.get('n_molecules', -1))
except Exception as e:
    print(-1)
" 2>/dev/null)

    if [ "$OUT_ROWS" -lt 0 ] 2>/dev/null || [ "$IN_ROWS" -ne "$OUT_ROWS" ] 2>/dev/null; then
        echo "  MISMATCH : chunk_${CHUNK_NUM} (input=${IN_ROWS}, output=${OUT_ROWS})"
        echo "$INPUT_FILE" >> "$MISSING_LIST"
    fi
done

NUM_MISSING=$(wc -l < "$MISSING_LIST" | tr -d ' ')

if [ "$NUM_MISSING" -eq 0 ]; then
    echo "All chunks complete for $LIBRARY_NAME"
    rm "$MISSING_LIST"
    exit 0
fi

echo ""
echo "Found $NUM_MISSING chunk(s) to resubmit"

# ── Submit array jobs (split at 1000 for Slurm MaxArraySize) ─────────────────
MAX_ARRAY_SIZE=1000
ARRAY_IDS=()
BATCH=0
START=0

while [ $START -lt $NUM_MISSING ]; do
    END=$(( START + MAX_ARRAY_SIZE - 1 ))
    if [ $END -ge $NUM_MISSING ]; then
        END=$(( NUM_MISSING - 1 ))
    fi
    BATCH_SIZE=$(( END - START + 1 ))

    BATCH_LIST="${OUTPUT_DIR}/chunk_list_missing_batch${BATCH}.txt"
    sed -n "$((START + 1)),$((END + 1))p" "$MISSING_LIST" > "$BATCH_LIST"

    ARRAY_ID=$(sbatch \
        --partition="$QUEUE" \
        --array=0-$((BATCH_SIZE - 1)) \
        "${SCRIPT_DIR}/run-drugclip-job.sh" \
        "$LIBRARY_NAME" \
        "$BATCH_LIST" \
        2>&1 | grep -oP 'Submitted batch job \K\d+')

    if [ -n "$ARRAY_ID" ]; then
        ARRAY_IDS+=("$ARRAY_ID")
        echo "Submitted array job $ARRAY_ID (${BATCH_SIZE} chunks)"
    else
        echo "ERROR: Submission failed for batch $BATCH"
        exit 1
    fi

    START=$(( END + 1 ))
    BATCH=$(( BATCH + 1 ))
done

echo ""
echo "=========================================="
echo "Array Job IDs: ${ARRAY_IDS[*]}"
echo "Monitor: watch -n 5 'squeue -u \$USER'"
echo "Cancel all: scancel ${ARRAY_IDS[*]}"
echo "=========================================="
