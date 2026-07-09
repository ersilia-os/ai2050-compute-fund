#!/bin/bash
#SBATCH --job-name=singularity-batch
#SBATCH --partition=cpu-queue
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=72:00:00
#SBATCH --output=/shared/logs/singularity-batch-%A_%a.out
#SBATCH --error=/shared/logs/singularity-batch-%A_%a.err

# Process one chunk from a named chemical library (array job mode)
#
# Called by submit-singularity-library.sh via:
#   sbatch --array=0-N run-singularity-library-job.sh <model_id> <chunk_list_file> <output_dir>
#
# Input  : /fsx/input/<library_name>/<library_name>_chunk_NNN.csv
# Output : <output_dir>/<model_id>_NNN.csv

MODEL_ID=$1
CHUNK_LIST=$2
OUTPUT_DIR=$3

if [ -z "$MODEL_ID" ] || [ -z "$CHUNK_LIST" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "ERROR: Usage: sbatch --array=0-N run-singularity-library-job.sh <model_id> <chunk_list_file> <output_dir>"
    exit 1
fi

INPUT_FILE=$(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" "$CHUNK_LIST")

if [ -z "$INPUT_FILE" ]; then
    echo "ERROR: No file at index $SLURM_ARRAY_TASK_ID in $CHUNK_LIST"
    exit 1
fi

CHUNK_NUM=$(basename "$INPUT_FILE" .csv | grep -oP '\d+$')
OUTPUT_FILE="${OUTPUT_DIR}/${MODEL_ID}_${CHUNK_NUM}.csv"
SIF_FILE="/shared/sif-files/${MODEL_ID}.sif"

echo "=========================================="
echo "Singularity Library Job"
echo "=========================================="
echo "Job ID     : $SLURM_JOB_ID"
echo "Array index: $SLURM_ARRAY_TASK_ID"
echo "Node       : $(hostname)"
echo "Date       : $(date)"
echo "Model      : $MODEL_ID"
echo "Input      : $INPUT_FILE"
echo "Output     : $OUTPUT_FILE"
echo "=========================================="

if [ ! -f "$SIF_FILE" ]; then
    echo "ERROR: SIF file not found: $SIF_FILE"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: Input file not found: $INPUT_FILE"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "Processing $(( $(wc -l < "$INPUT_FILE") - 1 )) molecules..."

singularity run --bind /fsx:/fsx --bind /shared:/shared "$SIF_FILE" "$INPUT_FILE" "$OUTPUT_FILE"

if [ -f "$OUTPUT_FILE" ]; then
    echo "SUCCESS: $OUTPUT_FILE ($(( $(wc -l < "$OUTPUT_FILE") - 1 )) rows)"
else
    echo "ERROR: Output file was not created: $OUTPUT_FILE"
    exit 1
fi

echo "=========================================="
echo "Job completed: $(date)"
echo "=========================================="
