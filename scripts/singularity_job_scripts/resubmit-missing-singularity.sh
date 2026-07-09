#!/bin/bash
# Resubmit missing or mismatched singularity batch chunks for a given model
#
# Usage: resubmit-missing-singularity.sh <model_id> [queue]
#
# Example:
#   bash resubmit-missing-singularity.sh mtb-public-models
#   bash resubmit-missing-singularity.sh mtb-public-models cpu-queue

MODEL_ID=$1
QUEUE=${2:-cpu-queue}

if [ -z "$MODEL_ID" ]; then
    echo "Usage: $0 <model_id> [queue]"
    exit 1
fi

INPUT_DIR="/fsx/input/batch_inputs"
OUTPUT_DIR="/fsx/output/batch_outputs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory not found: $INPUT_DIR"
    exit 1
fi

echo "=========================================="
echo "Scanning for missing/mismatched chunks"
echo "Model   : $MODEL_ID"
echo "Input   : $INPUT_DIR"
echo "Output  : $OUTPUT_DIR"
echo "=========================================="

MISSING_LIST="${OUTPUT_DIR}/chunk_list_${MODEL_ID}_missing.txt"
> "$MISSING_LIST"

for INPUT_FILE in $(ls "$INPUT_DIR"/smiles_*.csv 2>/dev/null | sort); do
    CHUNK_NUM=$(basename "$INPUT_FILE" .csv | grep -oP '\d+$')
    OUTPUT_FILE="${OUTPUT_DIR}/${MODEL_ID}_${CHUNK_NUM}.csv"

    if [ ! -f "$OUTPUT_FILE" ]; then
        echo "  MISSING : chunk_${CHUNK_NUM}"
        echo "$INPUT_FILE" >> "$MISSING_LIST"
    else
        IN_ROWS=$(( $(wc -l < "$INPUT_FILE") - 1 ))
        OUT_ROWS=$(( $(wc -l < "$OUTPUT_FILE") - 1 ))
        if [ "$IN_ROWS" -ne "$OUT_ROWS" ]; then
            echo "  MISMATCH: chunk_${CHUNK_NUM} (input=$IN_ROWS, output=$OUT_ROWS)"
            echo "$INPUT_FILE" >> "$MISSING_LIST"
        fi
    fi
done

NUM_MISSING=$(wc -l < "$MISSING_LIST" | tr -d ' ')

if [ "$NUM_MISSING" -eq 0 ]; then
    echo "All chunks complete for model $MODEL_ID"
    rm "$MISSING_LIST"
    exit 0
fi

echo ""
echo "Found $NUM_MISSING chunk(s) to resubmit"

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

    BATCH_LIST="${OUTPUT_DIR}/chunk_list_${MODEL_ID}_missing_batch${BATCH}.txt"
    sed -n "$((START+1)),$((END+1))p" "$MISSING_LIST" > "$BATCH_LIST"

    ARRAY_ID=$(sbatch \
        --partition="$QUEUE" \
        --array=0-$((BATCH_SIZE-1)) \
        "${SCRIPT_DIR}/run-singularity-job.sh" \
        "$MODEL_ID" \
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
