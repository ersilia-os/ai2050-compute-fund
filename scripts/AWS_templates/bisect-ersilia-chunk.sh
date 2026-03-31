#!/bin/bash
# Binary search resubmission for a failed Ersilia chunk.
#
# Usage:
#   bisect-ersilia-chunk.sh <model_id> <library_name> <chunk_num> [queue]
#
# Example:
#   bisect-ersilia-chunk.sh eos4k4f_v1 Enamine_Real_Sample_10.4M 042
#
# This script splits the failed chunk in two and submits both halves as a
# 2-task Slurm array job. The job script (run-ersilia-bisect.sh) handles
# recursive splitting until bad molecules are isolated and empty rows written.
# When all bisect jobs are done, run merge-bisect-results.sh to produce the
# final output file.

set -euo pipefail

MODEL_ID=${1:-}
LIBRARY_NAME=${2:-}
CHUNK_NUM=${3:-}
QUEUE=${4:-cpu-queue}

if [ -z "$MODEL_ID" ] || [ -z "$LIBRARY_NAME" ] || [ -z "$CHUNK_NUM" ]; then
    echo "Usage: $0 <model_id> <library_name> <chunk_num> [queue]"
    exit 1
fi

INPUT_DIR="/fsx/input/${LIBRARY_NAME}"
OUTPUT_DIR="/fsx/output/${LIBRARY_NAME}/${MODEL_ID}"
BISECT_DIR="${OUTPUT_DIR}/bisect/${CHUNK_NUM}"
SIF_FILE="/shared/sif-files/${MODEL_ID}.sif"

# Validate
if [ ! -f "$SIF_FILE" ]; then
    echo "ERROR: SIF file not found: $SIF_FILE"
    echo "Run: /shared/scripts/download-ersilia-model.sh $MODEL_ID"
    exit 1
fi

# Find the input chunk file (handles both naming conventions)
CHUNK_FILE=$(ls "${INPUT_DIR}/"*"_chunk_${CHUNK_NUM}.csv" 2>/dev/null | head -1)
if [ -z "$CHUNK_FILE" ]; then
    echo "ERROR: Could not find chunk ${CHUNK_NUM} in ${INPUT_DIR}"
    exit 1
fi

echo "=========================================="
echo "Bisect Ersilia Chunk"
echo "=========================================="
echo "Model:    $MODEL_ID"
echo "Library:  $LIBRARY_NAME"
echo "Chunk:    $CHUNK_NUM"
echo "Input:    $CHUNK_FILE"
echo "Bisect:   $BISECT_DIR"
echo "Queue:    $QUEUE"
echo "=========================================="

mkdir -p "$BISECT_DIR"

N_SPLITS=10

# Split chunk into N_SPLITS pieces and write tasks file
python3 - <<EOF
import csv, math, os, sys

chunk_file  = "$CHUNK_FILE"
bisect_dir  = "$BISECT_DIR"
n_splits    = $N_SPLITS

with open(chunk_file, newline="") as f:
    reader = csv.reader(f)
    header = next(reader)
    rows = list(reader)

num_mols = len(rows)
if num_mols == 0:
    print("ERROR: Chunk file is empty", file=sys.stderr)
    sys.exit(1)

n_splits = min(n_splits, num_mols)   # never more pieces than molecules
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
    /shared/scripts/run-ersilia-bisect.sh \
    "$MODEL_ID" \
    "$BISECT_DIR" \
    "$LIBRARY_NAME" \
    "$CHUNK_NUM" \
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
echo "Merge:    /shared/scripts/merge-bisect-results.sh $MODEL_ID $LIBRARY_NAME $CHUNK_NUM"
