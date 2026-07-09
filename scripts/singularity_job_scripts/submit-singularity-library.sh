#!/bin/bash
# Submit Singularity batch jobs for a named chemical library
#
# Usage: submit-singularity-library.sh <model_id> <library_name> [queue]
#
# Input  : /fsx/input/<library_name>/<library_name>_chunk_NNN.csv
# Output : /fsx/output/<library_name>/<model_id>/<model_id>_NNN.csv
# SIF    : /shared/sif-files/<model_id>.sif
#
# Available libraries:
#   Enamine_Hit_Locator_460K
#   Enamine_Liquid_Stock_2.5M
#   Molport_Screening_Compounds_5.3M
#   Coconut_715K
#   Enamine_Real_Sample_10.4M
#
# Examples:
#   bash submit-singularity-library.sh mtb-public-models Coconut_715K
#   bash submit-singularity-library.sh mtb-public-models Enamine_Hit_Locator_460K cpu-queue

MODEL_ID=$1
LIBRARY_NAME=$2
QUEUE=${3:-cpu-queue}

if [ -z "$MODEL_ID" ] || [ -z "$LIBRARY_NAME" ]; then
    echo "Usage: $0 <model_id> <library_name> [queue]"
    echo "Example: $0 mtb-public-models Coconut_715K cpu-queue"
    exit 1
fi

INPUT_DIR="/fsx/input/${LIBRARY_NAME}"
OUTPUT_DIR="/fsx/output/${LIBRARY_NAME}/${MODEL_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIF_FILE="/shared/sif-files/${MODEL_ID}.sif"

if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory not found: $INPUT_DIR"
    exit 1
fi

if [ ! -f "$SIF_FILE" ]; then
    echo "ERROR: SIF file not found: $SIF_FILE"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Collect chunk files (<library_name>_chunk_NNN.csv)
mapfile -t CHUNK_FILES < <(ls "$INPUT_DIR"/${LIBRARY_NAME}_chunk_*.csv 2>/dev/null | sort)
NUM_CHUNKS=${#CHUNK_FILES[@]}

if [ "$NUM_CHUNKS" -eq 0 ]; then
    echo "ERROR: No ${LIBRARY_NAME}_chunk_*.csv files found in $INPUT_DIR"
    exit 1
fi

echo "=========================================="
echo "Singularity Batch Job Submission"
echo "=========================================="
echo "Model    : $MODEL_ID"
echo "Library  : $LIBRARY_NAME"
echo "SIF      : $SIF_FILE"
echo "Input    : $INPUT_DIR"
echo "Output   : $OUTPUT_DIR"
echo "Chunks   : $NUM_CHUNKS"
echo "Queue    : $QUEUE"
echo "=========================================="

CHUNK_LIST="${OUTPUT_DIR}/chunk_list_${MODEL_ID}.txt"
printf '%s\n' "${CHUNK_FILES[@]}" > "$CHUNK_LIST"
echo "Chunk list: $CHUNK_LIST"
echo ""

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

    BATCH_LIST="${OUTPUT_DIR}/chunk_list_${MODEL_ID}_batch${BATCH}.txt"
    sed -n "$((START+1)),$((END+1))p" "$CHUNK_LIST" > "$BATCH_LIST"

    ARRAY_ID=$(sbatch \
        --partition="$QUEUE" \
        --array=0-$((BATCH_SIZE-1)) \
        "${SCRIPT_DIR}/run-singularity-library-job.sh" \
        "$MODEL_ID" \
        "$BATCH_LIST" \
        "$OUTPUT_DIR" \
        2>&1 | grep -oP 'Submitted batch job \K\d+')

    if [ -n "$ARRAY_ID" ]; then
        ARRAY_IDS+=("$ARRAY_ID")
        echo "Submitted job $ARRAY_ID — chunks ${START}-${END} (${BATCH_SIZE} tasks)"
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
echo "Model          : $MODEL_ID"
echo "Library        : $LIBRARY_NAME"
echo "Total chunks   : $NUM_CHUNKS"
echo "Array job IDs  : ${ARRAY_IDS[*]}"
echo ""
echo "Monitor:"
echo "  watch -n 10 'squeue -u \$USER'"
echo ""
echo "Check results when done:"
echo "  bash ${SCRIPT_DIR}/check-singularity-results.sh $MODEL_ID $LIBRARY_NAME"
echo "=========================================="

cat > "${OUTPUT_DIR}/job_info_${MODEL_ID}.txt" << EOF
Model: $MODEL_ID
Library: $LIBRARY_NAME
SIF: $SIF_FILE
Input Directory: $INPUT_DIR
Output Directory: $OUTPUT_DIR
Number of Chunks: $NUM_CHUNKS
Queue: $QUEUE
Submitted: $(date)
Array Job IDs: ${ARRAY_IDS[*]}
Chunk List: $CHUNK_LIST
EOF
