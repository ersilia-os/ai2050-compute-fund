#!/bin/bash
# Submit Ersilia batch jobs for Enamine_Real_Sample_10.4M
# Handles >1000 chunks (Slurm MaxArraySize=1000 limit) by splitting into batches
#
# Usage: submit-ersilia-batch-ER10.4M.sh <model_id> [queue]
#
# Expected input structure:
#   /fsx/input/Enamine_Real_Sample_10.4M/Enamine_Real_Sample_10.4M_chunk_000.csv
#
# Output structure:
#   /fsx/output/Enamine_Real_Sample_10.4M/<model_id>/<model_id>_results_000.csv

MODEL_ID=$1
LIBRARY_NAME="Enamine_Real_Sample_10.4M"
QUEUE=${2:-cpu-queue}

if [ -z "$MODEL_ID" ]; then
    echo "Usage: $0 <model_id> [queue]"
    echo "Example: $0 eos42ez cpu-queue"
    exit 1
fi

INPUT_DIR="/fsx/input/${LIBRARY_NAME}"
OUTPUT_DIR="/fsx/output/${LIBRARY_NAME}/${MODEL_ID}"

if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory not found: $INPUT_DIR"
    exit 1
fi

# Model SIFs come only from s3://models-sif; fetched once into /shared/sif-files.
/shared/scripts/download-ersilia-model.sh "$MODEL_ID" || exit 1

mkdir -p "$OUTPUT_DIR"

# Collect chunk files
CHUNK_FILES=($(ls "$INPUT_DIR"/*.csv 2>/dev/null | grep '_chunk_'))
NUM_CHUNKS=${#CHUNK_FILES[@]}

if [ $NUM_CHUNKS -eq 0 ]; then
    echo "ERROR: No chunk files found in $INPUT_DIR"
    exit 1
fi

echo "=========================================="
echo "Ersilia Batch Job Submission"
echo "=========================================="
echo "Model    : $MODEL_ID"
echo "Library  : $LIBRARY_NAME"
echo "Input    : $INPUT_DIR"
echo "Output   : $OUTPUT_DIR"
echo "Chunks   : $NUM_CHUNKS"
echo "Queue    : $QUEUE"
echo ""

# Write master chunk list
CHUNK_LIST="${OUTPUT_DIR}/chunk_list.txt"
printf '%s\n' "${CHUNK_FILES[@]}" > "$CHUNK_LIST"
echo "Chunk list written: $CHUNK_LIST"

# Submit in batches of 1000 (Slurm MaxArraySize limit)
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
    sed -n "$((START+1)),$((END+1))p" "$CHUNK_LIST" > "$BATCH_LIST"

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
        echo "Submitted job $ARRAY_ID — chunks ${START}-${END} (batch list: $BATCH_LIST)"
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
echo "Library        : $LIBRARY_NAME"
echo "Model          : $MODEL_ID"
echo "Total chunks   : $NUM_CHUNKS"
echo "Array job IDs  : ${ARRAY_IDS[*]}"
echo ""
echo "Monitor:"
echo "  watch -n 10 'squeue -u \$USER'"
echo ""
echo "Check results when done:"
echo "  /shared/scripts/check-results.sh $LIBRARY_NAME $MODEL_ID"
echo "=========================================="

# Save job metadata
cat > "${OUTPUT_DIR}/job_info.txt" << EOF
Library: $LIBRARY_NAME
Model: $MODEL_ID
Input Directory: $INPUT_DIR
Output Directory: $OUTPUT_DIR
Number of Chunks: $NUM_CHUNKS
Queue: $QUEUE
Submitted: $(date)
Array Job IDs: ${ARRAY_IDS[*]}
Chunk List: $CHUNK_LIST
EOF
