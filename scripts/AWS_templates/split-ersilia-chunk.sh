#!/bin/bash
# Split a single chunk into N sub-chunks and submit as a SLURM array job.
# A dependent merge job auto-runs when all sub-chunks complete successfully.
#
# Use for slow Ersilia models where a full chunk exceeds the wall-time limit.
#
# Usage:
#   split-ersilia-chunk.sh <model_id> <library_name> <chunk_num> [n_splits=100] [queue=cpu-queue]
#
# Example:
#   split-ersilia-chunk.sh eos4k4f_v1 Enamine_Real_Sample_10.4M 042

set -euo pipefail

MODEL_ID=${1:-}
LIBRARY_NAME=${2:-}
CHUNK_NUM=${3:-}
N_SPLITS=${4:-100}
QUEUE=${5:-cpu-queue}

if [ -z "$MODEL_ID" ] || [ -z "$LIBRARY_NAME" ] || [ -z "$CHUNK_NUM" ]; then
    echo "Usage: $0 <model_id> <library_name> <chunk_num> [n_splits=100] [queue=cpu-queue]"
    echo ""
    echo "Example:"
    echo "  $0 eos4k4f_v1 Enamine_Real_Sample_10.4M 042"
    exit 1
fi

INPUT_DIR="/fsx/input/${LIBRARY_NAME}"
OUTPUT_DIR="/fsx/output/${LIBRARY_NAME}/${MODEL_ID}"
SPLIT_DIR="${OUTPUT_DIR}/split/${CHUNK_NUM}"
SIF_FILE="/shared/sif-files/${MODEL_ID}.sif"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SIF_FILE" ]; then
    echo "ERROR: SIF file not found: $SIF_FILE"
    echo "Run: /shared/scripts/download-ersilia-model.sh $MODEL_ID"
    exit 1
fi

CHUNK_FILE=$(ls "${INPUT_DIR}/"*"_chunk_${CHUNK_NUM}.csv" 2>/dev/null | head -1)
if [ -z "$CHUNK_FILE" ]; then
    echo "ERROR: Could not find chunk ${CHUNK_NUM} in ${INPUT_DIR}"
    exit 1
fi

echo "=========================================="
echo "Split Ersilia Chunk"
echo "=========================================="
echo "Model:    $MODEL_ID"
echo "Library:  $LIBRARY_NAME"
echo "Chunk:    $CHUNK_NUM"
echo "Input:    $CHUNK_FILE"
echo "Splits:   $N_SPLITS"
echo "Split dir: $SPLIT_DIR"
echo "Queue:    $QUEUE"
echo "=========================================="

mkdir -p "$SPLIT_DIR"

# Split the chunk into N_SPLITS sub-files and write tasks.txt
python3 - <<EOF
import csv, math, os, sys

chunk_file = "$CHUNK_FILE"
split_dir  = "$SPLIT_DIR"
n_splits   = $N_SPLITS

with open(chunk_file, newline="") as f:
    reader = csv.reader(f)
    header = next(reader)
    rows = list(reader)

num_mols = len(rows)
if num_mols == 0:
    print("ERROR: Chunk file is empty", file=sys.stderr)
    sys.exit(1)

n_splits = min(n_splits, num_mols)
piece = math.ceil(num_mols / n_splits)

print(f"Total molecules : {num_mols}")
print(f"Splits          : {n_splits}  (~{piece} molecules each)")

tasks_file = os.path.join(split_dir, "tasks.txt")
with open(tasks_file, "w") as tf:
    for i in range(n_splits):
        start = i * piece
        end   = min(start + piece - 1, num_mols - 1)
        if start > num_mols - 1:
            break
        sub_file = os.path.join(split_dir, f"sub_{start}_{end}.csv")
        with open(sub_file, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(header)
            writer.writerows(rows[start : end + 1])
        tf.write(f"{start} {end}\n")
        print(f"  [{start}..{end}] -> {sub_file}")

print(f"Tasks file: {tasks_file}")
EOF

if [ ! -f "${SPLIT_DIR}/tasks.txt" ] || [ ! -s "${SPLIT_DIR}/tasks.txt" ]; then
    echo "ERROR: tasks.txt was not created — check Python output above"
    exit 1
fi

N_TASKS=$(wc -l < "${SPLIT_DIR}/tasks.txt" | tr -d ' ')
echo ""
echo "Submitting ${N_TASKS}-task array job..."

ARRAY_OUTPUT=$(sbatch \
    --partition="$QUEUE" \
    --array=0-$((N_TASKS-1)) \
    --job-name="split_${MODEL_ID}_${CHUNK_NUM}" \
    --output="/shared/logs/split-%A_%a.out" \
    --error="/shared/logs/split-%A_%a.err" \
    "${SCRIPT_DIR}/run-ersilia-split.sh" \
    "$MODEL_ID" \
    "$SPLIT_DIR" \
    "$LIBRARY_NAME" \
    "$CHUNK_NUM" \
    "${SPLIT_DIR}/tasks.txt")

ARRAY_JOB_ID=$(echo "$ARRAY_OUTPUT" | grep -oP '\d+$' || true)
if [ -z "$ARRAY_JOB_ID" ]; then
    echo "ERROR: Array job submission failed:"
    echo "$ARRAY_OUTPUT"
    exit 1
fi
echo "Submitted array job: $ARRAY_JOB_ID"

# Submit merge job — runs only when all array tasks succeed
FINAL_OUTPUT="${OUTPUT_DIR}/${MODEL_ID}_results_${CHUNK_NUM}.csv"

MERGE_OUTPUT=$(sbatch \
    --partition="$QUEUE" \
    --dependency=afterok:${ARRAY_JOB_ID} \
    --job-name="merge_${MODEL_ID}_${CHUNK_NUM}" \
    --output="/shared/logs/merge-split-%j.out" \
    --error="/shared/logs/merge-split-%j.err" \
    --nodes=1 \
    --cpus-per-task=1 \
    --time=01:00:00 \
    "${SCRIPT_DIR}/merge-split-results.sh" \
    "$MODEL_ID" \
    "$LIBRARY_NAME" \
    "$CHUNK_NUM")

MERGE_JOB_ID=$(echo "$MERGE_OUTPUT" | grep -oP '\d+$' || true)
if [ -z "$MERGE_JOB_ID" ]; then
    echo "WARNING: Merge job submission failed. Run manually when all splits are done:"
    echo "  merge-split-results.sh $MODEL_ID $LIBRARY_NAME $CHUNK_NUM"
else
    echo "Submitted merge job:  $MERGE_JOB_ID (depends on $ARRAY_JOB_ID)"
fi

echo ""
echo "=========================================="
echo "Chunk ${CHUNK_NUM} submitted"
echo "  Array job: $ARRAY_JOB_ID  (${N_TASKS} tasks)"
echo "  Merge job: ${MERGE_JOB_ID:-FAILED TO SUBMIT}"
echo "  Output:    $FINAL_OUTPUT"
echo ""
echo "Monitor:  watch -n 10 'squeue -u \$USER | grep -E \"split|merge\"'"
echo "If merge job fails: merge-split-results.sh $MODEL_ID $LIBRARY_NAME $CHUNK_NUM"
echo "=========================================="
