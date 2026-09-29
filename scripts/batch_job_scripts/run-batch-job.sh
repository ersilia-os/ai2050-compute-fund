#!/bin/bash
#SBATCH --job-name=ersilia-batch
#SBATCH --partition=cpu-queue
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=05:00:00
#SBATCH --output=/shared/logs/ersilia-batch-%A_%a.out
#SBATCH --error=/shared/logs/ersilia-batch-%A_%a.err

# Process one smiles chunk with an Ersilia model (array job mode)
#
# Called by submit-batch.sh via:
#   sbatch --array=0-N run-batch-job.sh <model_id> <chunk_list_file>
#
# Input  : /fsx/input/batch_inputs/smiles_NNN.csv
# Output : /fsx/output/batch_outputs/<model_id>_NNN.csv

MODEL_ID=$1
CHUNK_LIST=$2
OUTPUT_DIR="/fsx/output/batch_outputs"

if [ -z "$MODEL_ID" ] || [ -z "$CHUNK_LIST" ]; then
    echo "ERROR: Usage: sbatch --array=0-N run-batch-job.sh <model_id> <chunk_list_file>"
    exit 1
fi

# Pick input file by array index (1-based line in chunk list)
INPUT_FILE=$(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" "$CHUNK_LIST")

if [ -z "$INPUT_FILE" ]; then
    echo "ERROR: No file at index $SLURM_ARRAY_TASK_ID in $CHUNK_LIST"
    exit 1
fi

# Extract zero-padded chunk number from smiles_NNN.csv -> NNN
CHUNK_NUM=$(basename "$INPUT_FILE" .csv | grep -oP '\d+$')
# Strip version suffix (_v1, _v2, ...) from output filename
MODEL_OUT=$(echo "$MODEL_ID" | sed 's/_v[0-9]*$//')
OUTPUT_FILE="${OUTPUT_DIR}/${MODEL_OUT}_${CHUNK_NUM}.csv"

SIF_FILE="/shared/sif-files/${MODEL_ID}.sif"

echo "=========================================="
echo "Ersilia Batch Job"
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
    echo "Download it first: /shared/scripts/download-ersilia-model.sh $MODEL_ID"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: Input file not found: $INPUT_FILE"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "Processing $(( $(wc -l < "$INPUT_FILE") - 1 )) molecules..."

/shared/python39/bin/ersilia_apptainer \
    --sif "$SIF_FILE" \
    --input "$INPUT_FILE" \
    --output "$OUTPUT_FILE"

if [ -f "$OUTPUT_FILE" ]; then
    echo "SUCCESS: $OUTPUT_FILE ($(( $(wc -l < "$OUTPUT_FILE") - 1 )) rows)"
else
    echo "ERROR: Output file was not created: $OUTPUT_FILE"
    exit 1
fi

echo "=========================================="
echo "Job completed: $(date)"
echo "=========================================="
