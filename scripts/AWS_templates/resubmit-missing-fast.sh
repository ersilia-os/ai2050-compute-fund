#!/bin/bash
# Fast variant of resubmit-missing.sh — resubmits ONLY missing chunks.
#
# Unlike resubmit-missing.sh, this does NOT check input/output row-count
# mismatches (which requires wc -l on every input and output file — slow for
# models with huge output, e.g. descriptors). It resubmits a chunk only when
# its result file is absent, so detection is pure presence (no content read).
#
# By default it checks the fsx output dir. With --s3 it instead checks whether
# the final result exists in S3 — useful for big descriptor models whose fsx
# outputs are deleted after upload to free space. Inputs are still read from
# /fsx/input, so resubmission works unchanged.
#
# Usage: resubmit-missing-fast.sh [--s3] <model_id> <library_name> [queue]
#
# Env:
#   S3_BUCKET   S3 bucket for --s3 mode (default: ai2050-ersilia-cluster)
#
# Examples:
#   resubmit-missing-fast.sh eos4k4f_v1 Enamine_Hit_Locator_460K cpu-queue
#   resubmit-missing-fast.sh --s3 eos4k4f_v1 Molport_Screening_Compounds_5.3M

# ── Parse flags (--s3 may appear anywhere) ───────────────────────────────────
CHECK_S3=0
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --s3) CHECK_S3=1 ;;
        *)    POSITIONAL+=("$arg") ;;
    esac
done
set -- "${POSITIONAL[@]}"

MODEL_ID=$1
LIBRARY_NAME=$2
QUEUE=${3:-cpu-queue}

if [ -z "$MODEL_ID" ] || [ -z "$LIBRARY_NAME" ]; then
    echo "Usage: $0 [--s3] <model_id> <library_name> [queue]"
    echo "Example: $0 --s3 eos4k4f_v1 Molport_Screening_Compounds_5.3M cpu-queue"
    exit 1
fi

INPUT_DIR="/fsx/input/${LIBRARY_NAME}"
OUTPUT_DIR="/fsx/output/${LIBRARY_NAME}/${MODEL_ID}"
S3_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"
S3_OUTPUT_PREFIX="s3://${S3_BUCKET}/output/${LIBRARY_NAME}/${MODEL_ID}/"

if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory not found: $INPUT_DIR"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "=========================================="
if [ "$CHECK_S3" -eq 1 ]; then
    echo "Scanning for MISSING chunks (fast, S3 presence)"
    echo "Checking : $S3_OUTPUT_PREFIX"
else
    echo "Scanning for MISSING chunks (fast, fsx presence)"
    echo "Checking : $OUTPUT_DIR"
fi
echo "Library  : $LIBRARY_NAME"
echo "Model    : $MODEL_ID"
echo "=========================================="

# ── In --s3 mode, list the output prefix ONCE and build a set of done chunks ─
declare -A S3_DONE
if [ "$CHECK_S3" -eq 1 ]; then
    TMP_ERR=$(mktemp)
    S3_LS=$(aws s3 ls "$S3_OUTPUT_PREFIX" 2>"$TMP_ERR")
    if [ -s "$TMP_ERR" ]; then
        echo "ERROR: aws s3 ls failed for $S3_OUTPUT_PREFIX"
        cat "$TMP_ERR"; rm -f "$TMP_ERR"
        exit 1
    fi
    rm -f "$TMP_ERR"

    while read -r CH; do
        [ -n "$CH" ] && S3_DONE[$CH]=1
    done < <(printf '%s\n' "$S3_LS" | grep -oP "${MODEL_ID}_results_\K\d+(?=\.csv)")

    echo "Found ${#S3_DONE[@]} result file(s) in S3"
fi

# ── Build list of input files that need reprocessing (missing output only) ───
MISSING_LIST="${OUTPUT_DIR}/chunk_list_missing.txt"
> "$MISSING_LIST"

for INPUT_FILE in $(ls "$INPUT_DIR"/*_chunk_*.csv 2>/dev/null | sort); do
    CHUNK_NUM=$(basename "$INPUT_FILE" .csv | grep -oP '\d+$')

    if [ "$CHECK_S3" -eq 1 ]; then
        MISSING=0
        [ -z "${S3_DONE[$CHUNK_NUM]:-}" ] && MISSING=1
    else
        OUTPUT_FILE="${OUTPUT_DIR}/${MODEL_ID}_results_${CHUNK_NUM}.csv"
        MISSING=0
        [ ! -f "$OUTPUT_FILE" ] && MISSING=1
    fi

    if [ "$MISSING" -eq 1 ]; then
        echo "  MISSING : chunk_${CHUNK_NUM}"
        echo "$INPUT_FILE" >> "$MISSING_LIST"
    fi
done

NUM_MISSING=$(wc -l < "$MISSING_LIST" | tr -d ' ')

if [ "$NUM_MISSING" -eq 0 ]; then
    echo "All chunks present for $LIBRARY_NAME / $MODEL_ID"
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
