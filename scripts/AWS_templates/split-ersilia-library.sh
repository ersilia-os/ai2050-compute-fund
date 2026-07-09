#!/bin/bash
# Submit split-and-merge jobs for all chunks of a library.
#
# For slow Ersilia models: splits each chunk into N sub-chunks, runs all in
# parallel as SLURM array jobs, and auto-merges each chunk via dependency.
#
# Skips chunks whose final output already exists and has the correct row count.
# Throttles submission: waits until pending job count drops below MAX_PENDING
# before submitting the next chunk (avoids hitting SLURM's queue limit).
#
# Usage:
#   split-ersilia-library.sh <model_id> <library_name> [n_splits=100] [queue=cpu-queue] [max_pending=600]
#
# Example:
#   split-ersilia-library.sh eos4k4f_v1 Enamine_Real_Sample_10.4M 100 cpu-queue 600

set -euo pipefail

MODEL_ID=${1:-}
LIBRARY_NAME=${2:-}
N_SPLITS=${3:-100}
QUEUE=${4:-cpu-queue}
MAX_PENDING=${5:-600}

if [ -z "$MODEL_ID" ] || [ -z "$LIBRARY_NAME" ]; then
    echo "Usage: $0 <model_id> <library_name> [n_splits=100] [queue=cpu-queue] [max_pending=600]"
    echo ""
    echo "Arguments:"
    echo "  model_id      - Ersilia model ID (e.g., eos4k4f_v1)"
    echo "  library_name  - Library folder name (e.g., Enamine_Real_Sample_10.4M)"
    echo "  n_splits      - Sub-chunks per input chunk, default 100"
    echo "  queue         - SLURM partition, default cpu-queue"
    echo "  max_pending   - Max pending jobs before pausing submission, default 600"
    echo ""
    echo "Example:"
    echo "  $0 eos4k4f_v1 Enamine_Real_Sample_10.4M"
    exit 1
fi

INPUT_DIR="/fsx/input/${LIBRARY_NAME}"
OUTPUT_DIR="/fsx/output/${LIBRARY_NAME}/${MODEL_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory not found: $INPUT_DIR"
    exit 1
fi

if [ ! -f "/shared/sif-files/${MODEL_ID}.sif" ]; then
    echo "ERROR: Model SIF not found: /shared/sif-files/${MODEL_ID}.sif"
    echo "Download it first: /shared/scripts/download-ersilia-model.sh $MODEL_ID"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

CHUNK_FILES=($(ls "$INPUT_DIR"/*.csv 2>/dev/null | grep '_chunk_' | sort || true))
NUM_CHUNKS=${#CHUNK_FILES[@]}

if [ $NUM_CHUNKS -eq 0 ]; then
    echo "ERROR: No chunk files found in $INPUT_DIR"
    echo "Expected files containing '_chunk_': chunk_0001.csv or LibraryName_chunk_000.csv"
    exit 1
fi

echo "=========================================="
echo "Ersilia Split Library Submission"
echo "=========================================="
echo "Model:       $MODEL_ID"
echo "Library:     $LIBRARY_NAME"
echo "Chunks:      $NUM_CHUNKS"
echo "Splits:      $N_SPLITS per chunk"
echo "Queue:       $QUEUE"
echo "Max pending: $MAX_PENDING jobs"
echo "=========================================="
echo ""

SUBMITTED=0
SKIPPED=0
FAILED=0
declare -a ARRAY_JOB_IDS=()
declare -a MERGE_JOB_IDS=()

for CHUNK_FILE in "${CHUNK_FILES[@]}"; do
    CHUNK_NUM=$(basename "$CHUNK_FILE" .csv | grep -oP '\d+$')
    FINAL_OUTPUT="${OUTPUT_DIR}/${MODEL_ID}_results_${CHUNK_NUM}.csv"

    # Skip if already complete (correct row count)
    if [ -f "$FINAL_OUTPUT" ]; then
        IN_ROWS=$(( $(wc -l < "$CHUNK_FILE") - 1 ))
        OUT_ROWS=$(( $(wc -l < "$FINAL_OUTPUT") - 1 ))
        if [ "$IN_ROWS" -eq "$OUT_ROWS" ]; then
            echo "  SKIP  chunk_${CHUNK_NUM} (already complete: ${OUT_ROWS} rows)"
            SKIPPED=$(( SKIPPED + 1 ))
            continue
        fi
    fi

    # Throttle: wait until pending job count drops below MAX_PENDING
    PENDING=$(squeue -u "$USER" -h | wc -l)
    if [ "$PENDING" -ge "$MAX_PENDING" ]; then
        echo "  Queue at ${PENDING} jobs (limit ${MAX_PENDING}) — waiting..."
        while [ "$(squeue -u "$USER" -h | wc -l)" -ge "$MAX_PENDING" ]; do
            sleep 30
        done
        echo "  Queue drained to $(squeue -u "$USER" -h | wc -l) — resuming"
    fi

    echo -n "  Submitting chunk_${CHUNK_NUM}... "

    set +e
    RESULT=$(bash "${SCRIPT_DIR}/split-ersilia-chunk.sh" \
        "$MODEL_ID" "$LIBRARY_NAME" "$CHUNK_NUM" "$N_SPLITS" "$QUEUE" 2>&1)
    EXIT_CODE=$?
    set -e

    if [ $EXIT_CODE -ne 0 ]; then
        echo "ERROR"
        echo "$RESULT"
        FAILED=$(( FAILED + 1 ))
        continue
    fi

    ARRAY_ID=$(echo "$RESULT" | grep "Submitted array job:" | grep -oP '\d+$' || true)
    MERGE_ID=$(echo "$RESULT" | grep "Submitted merge job:" | grep -oP '\d+' | head -1 || true)

    if [ -n "$ARRAY_ID" ]; then
        ARRAY_JOB_IDS+=("$ARRAY_ID")
        MERGE_JOB_IDS+=("${MERGE_ID:-?}")
        echo "array=$ARRAY_ID  merge=${MERGE_ID:-FAILED}"
        SUBMITTED=$(( SUBMITTED + 1 ))
    else
        echo "ERROR (no job ID returned)"
        echo "$RESULT"
        FAILED=$(( FAILED + 1 ))
    fi
done

echo ""
echo "=========================================="
echo "Submission Summary"
echo "=========================================="
echo "Model:      $MODEL_ID"
echo "Library:    $LIBRARY_NAME"
echo "Submitted:  $SUBMITTED chunk(s)"
echo "Skipped:    $SKIPPED chunk(s) (already complete)"
echo "Failed:     $FAILED chunk(s)"

if [ ${#ARRAY_JOB_IDS[@]} -gt 0 ]; then
    echo ""
    echo "Array jobs:  ${ARRAY_JOB_IDS[*]}"
    echo "Merge jobs:  ${MERGE_JOB_IDS[*]}"
    echo ""
    echo "Monitor:     watch -n 10 'squeue -u \$USER'"
    echo "Cancel all:  scancel ${ARRAY_JOB_IDS[*]}"
fi

if [ $FAILED -gt 0 ]; then
    echo ""
    echo "WARNING: $FAILED chunk(s) failed to submit. Check output above."
    exit 1
fi
echo "=========================================="
