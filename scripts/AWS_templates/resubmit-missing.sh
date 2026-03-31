#!/bin/bash
# Resubmit missing or mismatched chunks for a library/model
# Usage: resubmit-missing.sh <model_id> <library_name> [queue]
#
# Scans input chunks and resubmits any that are missing or have mismatched row counts.
#
# Example:
#   resubmit-missing.sh eos4k4f_v1 Enamine_Hit_Locator_460K cpu-queue

MODEL_ID=$1
LIBRARY_NAME=$2
QUEUE=${3:-cpu-queue}

if [ -z "$MODEL_ID" ] || [ -z "$LIBRARY_NAME" ]; then
    echo "Usage: $0 <model_id> <library_name> [queue]"
    echo "Example: $0 eos4k4f_v1 Molport_Screening_Compounds_5.3M cpu-queue"
    exit 1
fi

INPUT_DIR="/fsx/input/${LIBRARY_NAME}"
OUTPUT_DIR="/fsx/output/${LIBRARY_NAME}/${MODEL_ID}"

if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory not found: $INPUT_DIR"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "=========================================="
echo "Scanning for missing/mismatched chunks"
echo "Library : $LIBRARY_NAME"
echo "Model   : $MODEL_ID"
echo "=========================================="

# Build list of input files that need reprocessing
MISSING_LIST="${OUTPUT_DIR}/chunk_list_missing.txt"
> "$MISSING_LIST"

for INPUT_FILE in $(ls "$INPUT_DIR"/*_chunk_*.csv 2>/dev/null | sort); do
    CHUNK_NUM=$(basename "$INPUT_FILE" .csv | grep -oP '\d+$')
    OUTPUT_FILE="${OUTPUT_DIR}/${MODEL_ID}_results_${CHUNK_NUM}.csv"

    if [ ! -f "$OUTPUT_FILE" ]; then
        echo "  MISSING : chunk_${CHUNK_NUM}"
        echo "$INPUT_FILE" >> "$MISSING_LIST"
    else
        # Check row count mismatch
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
    echo "All chunks complete for $LIBRARY_NAME / $MODEL_ID"
    rm "$MISSING_LIST"
    exit 0
fi

echo ""
echo "Found $NUM_MISSING chunks to resubmit"

# Submit as array job(s), respecting Slurm MaxArraySize=1000
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
    sed -n "$((START+1)),$((END+1))p" "$MISSING_LIST" > "$BATCH_LIST"

    ARRAY_ID=$(sbatch \
        --partition="$QUEUE" \
        --array=0-$((BATCH_SIZE-1)) \
        /shared/scripts/run-ersilia-job.sh \
        "$MODEL_ID" \
        "$BATCH_LIST" \
        "$OUTPUT_DIR" \
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
