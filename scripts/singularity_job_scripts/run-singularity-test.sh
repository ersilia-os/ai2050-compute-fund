#!/bin/bash
#SBATCH --job-name=singularity-test
#SBATCH --partition=cpu-queue
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=/shared/logs/singularity-test-%j.out
#SBATCH --error=/shared/logs/singularity-test-%j.err

# Run a test singularity job on /fsx/input/test/test_smiles_100.csv
#
# Usage: sbatch run-singularity-test.sh <model_id>
# Example: sbatch run-singularity-test.sh mtb-public-models

MODEL_ID=$1

if [ -z "$MODEL_ID" ]; then
    echo "Usage: sbatch $0 <model_id>"
    echo "Example: sbatch $0 mtb-public-models"
    exit 1
fi

INPUT_FILE="/fsx/input/test/test_smiles_100.csv"
OUTPUT_DIR="/fsx/output/test"
OUTPUT_FILE="${OUTPUT_DIR}/${MODEL_ID}_test_results.csv"
SIF_FILE="/shared/sif-files/${MODEL_ID}.sif"

echo "=========================================="
echo "Singularity Test Job"
echo "=========================================="
echo "Job ID : $SLURM_JOB_ID"
echo "Node   : $(hostname)"
echo "Date   : $(date)"
echo "Model  : $MODEL_ID"
echo "Input  : $INPUT_FILE"
echo "Output : $OUTPUT_FILE"
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
