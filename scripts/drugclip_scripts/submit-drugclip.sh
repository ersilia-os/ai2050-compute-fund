#!/bin/bash
# Submit DrugCLIP embedding jobs for one chemical library.
#
# Usage:
#   bash /shared/scripts/drugclip/submit-drugclip.sh <library_name> [queue]
#
# Examples:
#   bash /shared/scripts/drugclip/submit-drugclip.sh Enamine_Hit_Locator_460K
#   bash /shared/scripts/drugclip/submit-drugclip.sh Enamine_Hit_Locator_460K gpu-queue
#   bash /shared/scripts/drugclip/submit-drugclip.sh Enamine_Real_Sample_10.4M
#   bash /shared/scripts/drugclip/submit-drugclip.sh Enamine_Hit_Locator_460K cpu-queue
#
# Input:  /fsx/input/<library>/<library>_chunk_NNN.csv
# Output: /fsx/output/<library>/drugclip/<library>_drugclip_NNN.h5

LIBRARY_NAME=$1
QUEUE=${2:-gpu-queue}

if [ -z "$LIBRARY_NAME" ]; then
    echo "Usage: $0 <library_name> [queue]"
    echo ""
    echo "Examples:"
    echo "  $0 Enamine_Hit_Locator_460K"
    echo "  $0 Enamine_Hit_Locator_460K gpu-queue"
    echo "  $0 Enamine_Hit_Locator_460K cpu-queue"
    exit 1
fi

INPUT_DIR="/fsx/input/${LIBRARY_NAME}"
OUTPUT_DIR="/fsx/output/${LIBRARY_NAME}/drugclip"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory not found: $INPUT_DIR"
    exit 1
fi

if [ ! -f "/shared/sif-files/drugclip.sif" ]; then
    echo "ERROR: drugclip.sif not found at /shared/sif-files/drugclip.sif"
    echo "  Download: aws s3 cp s3://ai2050-ersilia-cluster/sif-files/drugclip.sif /shared/sif-files/"
    exit 1
fi

if [ ! -f "/shared/drugclip-weights/checkpoint_best.pt" ]; then
    echo "ERROR: Weights not found at /shared/drugclip-weights/checkpoint_best.pt"
    echo "  Download: aws s3 cp s3://ai2050-ersilia-cluster/drugclip-weights/checkpoint_best.pt /shared/drugclip-weights/"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# ── Collect chunk files ───────────────────────────────────────────────────────
CHUNK_FILES=($(ls "${INPUT_DIR}"/*_chunk_*.csv 2>/dev/null | sort))
NUM_CHUNKS=${#CHUNK_FILES[@]}

if [ $NUM_CHUNKS -eq 0 ]; then
    echo "ERROR: No chunk files found in $INPUT_DIR"
    exit 1
fi

echo "=========================================="
echo "DrugCLIP Embedding Submission"
echo "=========================================="
echo "Library  : $LIBRARY_NAME"
echo "Input    : $INPUT_DIR"
echo "Output   : $OUTPUT_DIR"
echo "Chunks   : $NUM_CHUNKS"
echo "Queue    : $QUEUE"
echo "=========================================="

# ── Write master chunk list ───────────────────────────────────────────────────
CHUNK_LIST="${OUTPUT_DIR}/chunk_list.txt"
printf '%s\n' "${CHUNK_FILES[@]}" > "$CHUNK_LIST"
echo "Chunk list: $CHUNK_LIST"

# ── Submit in batches of 1000 (Slurm MaxArraySize limit) ─────────────────────
MAX_ARRAY_SIZE=1000
ARRAY_IDS=()
BATCH=0
START=0

while [ $START -lt $NUM_CHUNKS ]; do
    END=$(( START + MAX_ARRAY_SIZE - 1 ))
    if [ $END -ge $NUM_CHUNKS ]; then
        END=$(( NUM_CHUNKS - 1 ))
    fi
    BATCH_SIZE=$(( END - START + 1 ))

    BATCH_LIST="${OUTPUT_DIR}/chunk_list_batch${BATCH}.txt"
    sed -n "$((START + 1)),$((END + 1))p" "$CHUNK_LIST" > "$BATCH_LIST"

    ARRAY_ID=$(sbatch \
        --partition="$QUEUE" \
        --array=0-$((BATCH_SIZE - 1)) \
        "${SCRIPT_DIR}/run-drugclip-job.sh" \
        "$LIBRARY_NAME" \
        "$BATCH_LIST" \
        2>&1 | grep -oP 'Submitted batch job \K\d+')

    if [ -n "$ARRAY_ID" ]; then
        ARRAY_IDS+=("$ARRAY_ID")
        echo "Submitted job $ARRAY_ID — chunks ${START}-${END} (batch: $BATCH_LIST)"
    else
        echo "ERROR: Submission failed for chunks ${START}-${END}"
        exit 1
    fi

    START=$(( END + 1 ))
    BATCH=$(( BATCH + 1 ))
done

echo ""
echo "=========================================="
echo "Submission Summary"
echo "=========================================="
echo "Library      : $LIBRARY_NAME"
echo "Total chunks : $NUM_CHUNKS"
echo "Array job IDs: ${ARRAY_IDS[*]}"
echo ""
echo "Monitor:"
echo "  watch -n 5 'squeue -u \$USER'"
echo ""
echo "Check results when done:"
echo "  bash ${SCRIPT_DIR}/check-drugclip-results.sh $LIBRARY_NAME"
echo ""
echo "Resubmit missing:"
echo "  bash ${SCRIPT_DIR}/resubmit-missing-drugclip.sh $LIBRARY_NAME $QUEUE"
echo "=========================================="

# ── Save job metadata ─────────────────────────────────────────────────────────
cat > "${OUTPUT_DIR}/job_info.txt" << EOF
Library: $LIBRARY_NAME
Input Directory: $INPUT_DIR
Output Directory: $OUTPUT_DIR
Number of Chunks: $NUM_CHUNKS
Queue: $QUEUE
Submitted: $(date)
Array Job IDs: ${ARRAY_IDS[*]}
Chunk List: $CHUNK_LIST
EOF
