#!/bin/bash
# Divide-and-conquer resubmission for a failed singularity batch chunk.
#
# Usage:
#   bisect-singularity-chunk.sh <model_id> <chunk_num> [queue]
#
# Example:
#   bisect-singularity-chunk.sh mtb-public-models 020

set -euo pipefail

MODEL_ID=${1:-}
CHUNK_NUM=${2:-}
QUEUE=${3:-cpu-queue}

if [ -z "$MODEL_ID" ] || [ -z "$CHUNK_NUM" ]; then
    echo "Usage: $0 <model_id> <chunk_num> [queue]"
    echo "Example: $0 mtb-public-models 020"
    exit 1
fi

INPUT_FILE="/fsx/input/batch_inputs/smiles_${CHUNK_NUM}.csv"
OUTPUT_DIR="/fsx/output/batch_outputs"
BISECT_DIR="${OUTPUT_DIR}/bisect/${MODEL_ID}/${CHUNK_NUM}"
SIF_FILE="/shared/sif-files/${MODEL_ID}.sif"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SIF_FILE" ]; then
    echo "ERROR: SIF file not found: $SIF_FILE"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: Input file not found: $INPUT_FILE"
    exit 1
fi

echo "=========================================="
echo "Bisect Singularity Chunk"
echo "=========================================="
echo "Model:    $MODEL_ID"
echo "Chunk:    $CHUNK_NUM"
echo "Input:    $INPUT_FILE"
echo "Bisect:   $BISECT_DIR"
echo "Queue:    $QUEUE"
echo "=========================================="

mkdir -p "$BISECT_DIR"

N_SPLITS=10

python3 - <<EOF
import csv, math, os, sys

input_file = "$INPUT_FILE"
bisect_dir = "$BISECT_DIR"
n_splits   = $N_SPLITS

with open(input_file, newline="") as f:
    reader = csv.reader(f)
    header = next(reader)
    rows = list(reader)

num_mols = len(rows)
if num_mols == 0:
    print("ERROR: Input file is empty", file=sys.stderr)
    sys.exit(1)

n_splits = min(n_splits, num_mols)
piece = math.ceil(num_mols / n_splits)

print(f"Total molecules : {num_mols}")
print(f"Splits          : {n_splits}  (~{piece} molecules each)")

tasks_file = os.path.join(bisect_dir, "tasks.txt")
with open(tasks_file, "w") as tf:
    for i in range(n_splits):
        start = i * piece
        end   = min(start + piece - 1, num_mols - 1)
        if start > num_mols - 1:
            break
        sub_file = os.path.join(bisect_dir, f"sub_{start}_{end}.csv")
        with open(sub_file, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(header)
            writer.writerows(rows[start : end + 1])
        tf.write(f"{start} {end}\n")
        print(f"  [{start}..{end}] → {sub_file}")

print(f"Tasks file: {tasks_file}")
EOF

if [ ! -f "${BISECT_DIR}/tasks.txt" ] || [ ! -s "${BISECT_DIR}/tasks.txt" ]; then
    echo "ERROR: tasks.txt was not created — check Python output above"
    exit 1
fi

N_TASKS=$(wc -l < "${BISECT_DIR}/tasks.txt" | tr -d ' ')
echo ""
echo "Submitting ${N_TASKS}-task array job..."

JOB_OUTPUT=$(sbatch \
    --partition="$QUEUE" \
    --array=0-$((N_TASKS-1)) \
    --job-name="bisect_${MODEL_ID}_${CHUNK_NUM}" \
    --output="/shared/logs/bisect-%A_%a.out" \
    --error="/shared/logs/bisect-%A_%a.err" \
    "${SCRIPT_DIR}/run-singularity-bisect.sh" \
    "$MODEL_ID" \
    "$CHUNK_NUM" \
    "$BISECT_DIR" \
    "${BISECT_DIR}/tasks.txt" \
    "$QUEUE")

JOB_ID=$(echo "$JOB_OUTPUT" | grep -oP '\d+$' || true)
if [ -z "$JOB_ID" ]; then
    echo "ERROR: sbatch failed or returned unexpected output:"
    echo "$JOB_OUTPUT"
    exit 1
fi

echo "Submitted array job: $JOB_ID"
echo ""
echo "Monitor:  watch -n 10 'squeue -u \$USER | grep bisect'"
echo "Merge:    bash ${SCRIPT_DIR}/merge-singularity-bisect.sh $MODEL_ID $CHUNK_NUM"
