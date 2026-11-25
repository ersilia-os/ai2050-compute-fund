#!/bin/bash
# Submit Ersilia batch jobs for pre-chunked input files
# Usage: submit-ersilia-batch.sh <model_id> <library_name> [queue]
#
# Expected structure:
#   /fsx/input/<library_name>/chunk_0001.csv
#   /fsx/input/<library_name>/chunk_0002.csv
#   ...
#
# Output structure:
#   /fsx/output/<library_name>/<model_id>/<model_id>_results_0001.csv
#   /fsx/output/<library_name>/<model_id>/<model_id>_results_0002.csv
#   ...

MODEL_ID=$1
LIBRARY_NAME=$2
QUEUE=${3:-cpu-queue}

# Validation
if [ -z "$MODEL_ID" ] || [ -z "$LIBRARY_NAME" ]; then
    echo "Usage: $0 <model_id> <library_name> [queue]"
    echo ""
    echo "Arguments:"
    echo "  model_id      - Ersilia model ID with major version (e.g., eos2r5a_v1)"
    echo "  library_name  - Library folder name (e.g., library_001)"
    echo "  queue         - Optional: test-queue, cpu-queue (default), gpu-queue"
    echo ""
    echo "Expected input structure:"
    echo "  /fsx/input/<library_name>/chunk_0001.csv"
    echo "  /fsx/input/<library_name>/chunk_0002.csv"
    echo "  ..."
    echo ""
    echo "Output structure:"
    echo "  /fsx/output/<library_name>/<model_id>/<model_id>_results_0001.csv"
    echo "  /fsx/output/<library_name>/<model_id>/<model_id>_results_0002.csv"
    echo "  ..."
    echo ""
    echo "Example:"
    echo "  $0 eos2r5a_v1 library_001 cpu-queue"
    exit 1
fi

# Define paths
INPUT_DIR="/fsx/input/${LIBRARY_NAME}"
OUTPUT_DIR="/fsx/output/${LIBRARY_NAME}/${MODEL_ID}"

# Check if input directory exists
if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory not found: $INPUT_DIR"
    echo ""
    echo "Please ensure your chunks are uploaded to:"
    echo "  /fsx/input/${LIBRARY_NAME}/chunk_XXXX.csv"
    exit 1
fi

# Model SIFs come only from s3://models-sif; fetched once into /shared/sif-files.
/shared/scripts/download-ersilia-model.sh "$MODEL_ID" || exit 1

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Find all chunk files (matches both chunk_0001.csv and Library_chunk_000.csv)
CHUNK_FILES=($(ls "$INPUT_DIR"/*.csv 2>/dev/null | grep '_chunk_'))
NUM_CHUNKS=${#CHUNK_FILES[@]}

if [ $NUM_CHUNKS -eq 0 ]; then
    echo "ERROR: No chunk files found in $INPUT_DIR"
    echo "Expected files containing '_chunk_': chunk_0001.csv or LibraryName_chunk_000.csv"
    exit 1
fi

echo "=========================================="
echo "Ersilia Batch Job Submission (Array)"
echo "=========================================="
echo "Model: $MODEL_ID"
echo "Library: $LIBRARY_NAME"
echo "Input directory: $INPUT_DIR"
echo "Output directory: $OUTPUT_DIR"
echo "Number of chunks: $NUM_CHUNKS"
echo "Queue: $QUEUE"
echo ""

# Write chunk list file (one path per line, used by array job tasks)
CHUNK_LIST="${OUTPUT_DIR}/chunk_list.txt"
printf '%s\n' "${CHUNK_FILES[@]}" > "$CHUNK_LIST"
echo "Chunk list written: $CHUNK_LIST"

# Submit as a single Slurm array job
ARRAY_ID=$(sbatch \
    --partition="$QUEUE" \
    --array=0-$((NUM_CHUNKS-1)) \
    /shared/scripts/run-ersilia-job.sh \
    "$MODEL_ID" \
    "$CHUNK_LIST" \
    "$OUTPUT_DIR" \
    2>&1 | grep -oP 'Submitted batch job \K\d+')

echo ""
echo "=========================================="
echo "Submission Summary"
echo "=========================================="
echo "Library: $LIBRARY_NAME"
echo "Model: $MODEL_ID"
echo "Total chunks: $NUM_CHUNKS"

if [ -n "$ARRAY_ID" ]; then
    echo "Array Job ID: $ARRAY_ID"
    echo ""
    echo "Monitor jobs:"
    echo "  squeue -u \$USER"
    echo "  watch -n 5 'squeue -u \$USER'"
    echo ""
    echo "Cancel entire library:"
    echo "  scancel $ARRAY_ID"
else
    echo "ERROR: Array job submission failed"
    exit 1
fi

echo ""
echo "When complete, merge results:"
echo "  /shared/scripts/merge-results.sh $OUTPUT_DIR ${OUTPUT_DIR}/../${MODEL_ID}_final.csv"
echo ""
echo "Or upload individual results to S3:"
echo "  aws s3 sync $OUTPUT_DIR s3://\$S3_BUCKET/output/${LIBRARY_NAME}/${MODEL_ID}/"
echo "=========================================="

# Save job info
JOB_INFO_FILE="${OUTPUT_DIR}/job_info.txt"
cat > "$JOB_INFO_FILE" << EOF
Library: $LIBRARY_NAME
Model: $MODEL_ID
Input Directory: $INPUT_DIR
Output Directory: $OUTPUT_DIR
Number of Chunks: $NUM_CHUNKS
Queue: $QUEUE
Submitted: $(date)
Array Job ID: $ARRAY_ID
Chunk List: $CHUNK_LIST
EOF

echo "Job info saved: $JOB_INFO_FILE"
