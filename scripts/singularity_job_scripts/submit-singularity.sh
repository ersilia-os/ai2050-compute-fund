#!/bin/bash
# Submit Singularity batch jobs for all smiles chunks
#
# Usage: submit-singularity.sh <model_id> [queue]
#
# Input  : /fsx/input/batch_inputs/smiles_000.csv ... smiles_NNN.csv
# Output : /fsx/output/batch_outputs/<model_id>_000.csv ...
# SIF    : /shared/sif-files/<model_id>.sif
#
# The SIF is invoked as: singularity run <sif> <input.csv> <output.csv>
#
# Example:
#   bash submit-singularity.sh mtb-public-models
#   bash submit-singularity.sh mtb-public-models cpu-queue

MODEL_ID=$1
QUEUE=${2:-cpu-queue}

if [ -z "$MODEL_ID" ]; then
    echo "Usage: $0 <model_id> [queue]"
    echo "Example: $0 mtb-public-models cpu-queue"
    exit 1
fi

INPUT_DIR="/fsx/input/batch_inputs"
OUTPUT_DIR="/fsx/output/batch_outputs"
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

mapfile -t CHUNK_FILES < <(ls "$INPUT_DIR"/smiles_*.csv 2>/dev/null | sort)
NUM_CHUNKS=${#CHUNK_FILES[@]}

if [ "$NUM_CHUNKS" -eq 0 ]; then
    echo "ERROR: No smiles_*.csv files found in $INPUT_DIR"
    exit 1
fi

echo "=========================================="
echo "Singularity Batch Job Submission"
echo "=========================================="
echo "Model    : $MODEL_ID"
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
        "${SCRIPT_DIR}/run-singularity-job.sh" \
        "$MODEL_ID" \
        "$BATCH_LIST" \
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
echo "Total chunks   : $NUM_CHUNKS"
echo "Array job IDs  : ${ARRAY_IDS[*]}"
echo ""
echo "Monitor:"
echo "  watch -n 10 'squeue -u \$USER'"
echo ""
echo "Check results when done:"
echo "  bash ${SCRIPT_DIR}/check-singularity-results.sh $MODEL_ID"
echo "=========================================="

cat > "${OUTPUT_DIR}/job_info_${MODEL_ID}.txt" << EOF
Model: $MODEL_ID
SIF: $SIF_FILE
Input Directory: $INPUT_DIR
Output Directory: $OUTPUT_DIR
Number of Chunks: $NUM_CHUNKS
Queue: $QUEUE
Submitted: $(date)
Array Job IDs: ${ARRAY_IDS[*]}
Chunk List: $CHUNK_LIST
EOF
