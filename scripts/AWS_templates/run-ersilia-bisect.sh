#!/bin/bash
#SBATCH --job-name=ersilia-bisect
#SBATCH --nodes=1
#SBATCH --cpus-per-task=2
#SBATCH --time=24:00:00
#SBATCH --output=/shared/logs/bisect-%A_%a.out
#SBATCH --error=/shared/logs/bisect-%A_%a.err

# Run one sub-chunk of a binary search on a failed Ersilia chunk.
#
# Submitted by bisect-ersilia-chunk.sh (initial split) or recursively by
# this script itself (subsequent splits). Never call this script directly.
#
# Args: MODEL_ID BISECT_DIR LIBRARY_NAME CHUNK_NUM TASKS_FILE [QUEUE]
#
# TASKS_FILE has one "START END" pair per line; SLURM_ARRAY_TASK_ID selects
# the line. START/END are 0-based row indices in the original chunk (excl. header).

set -uo pipefail

MODEL_ID=$1
BISECT_DIR=$2
LIBRARY_NAME=$3
CHUNK_NUM=$4
TASKS_FILE=$5
QUEUE=${6:-cpu-queue}

TASK_ID=${SLURM_ARRAY_TASK_ID:-0}

# Read START and END for this task
TASK_LINE=$(sed -n "$((TASK_ID+1))p" "$TASKS_FILE")
START=$(echo "$TASK_LINE" | awk '{print $1}')
END=$(echo "$TASK_LINE" | awk '{print $2}')

SUB_CHUNK="${BISECT_DIR}/sub_${START}_${END}.csv"
SUB_RESULT="${BISECT_DIR}/result_${START}_${END}.csv"
SIF_FILE="/shared/sif-files/${MODEL_ID}.sif"
NUM_MOLS=$(( END - START + 1 ))

echo "=========================================="
echo "Ersilia Bisect Job"
echo "=========================================="
echo "Job ID:  ${SLURM_JOB_ID:-local}  Task: ${TASK_ID}"
echo "Node:    $(hostname)"
echo "Date:    $(date)"
echo "Model:   $MODEL_ID"
echo "Range:   [${START}..${END}] (${NUM_MOLS} molecules)"
echo "Input:   $SUB_CHUNK"
echo "Output:  $SUB_RESULT"
echo "=========================================="

# Validate
if [ ! -f "$SIF_FILE" ]; then
    echo "ERROR: SIF file not found: $SIF_FILE"
    exit 1
fi

if [ ! -f "$SUB_CHUNK" ]; then
    echo "ERROR: Sub-chunk file not found: $SUB_CHUNK"
    exit 1
fi

echo "Running ersilia-apptainer on ${NUM_MOLS} molecules..."

/shared/python39/bin/ersilia_apptainer \
    --sif "$SIF_FILE" \
    --input "$SUB_CHUNK" \
    --output "$SUB_RESULT" --verbose

ERSILIA_EXIT=$?

# ── Success ────────────────────────────────────────────────────────────────────
if [ $ERSILIA_EXIT -eq 0 ] && [ -f "$SUB_RESULT" ]; then
    echo "✓ Success: result_${START}_${END}.csv ($(wc -l < "$SUB_RESULT") lines)"
    exit 0
fi

# ── Failure ────────────────────────────────────────────────────────────────────
echo "✗ Failed on range [${START}..${END}]"

if [ $NUM_MOLS -eq 1 ]; then
    # ── Single bad molecule: write empty row ───────────────────────────────────
    echo "Single molecule failed — writing empty row"
    python3 - <<PYEOF
import csv, hashlib, glob, os

bisect_dir = "$BISECT_DIR"
library_name = "$LIBRARY_NAME"
model_id = "$MODEL_ID"
sub_chunk = "$SUB_CHUNK"
sub_result = "$SUB_RESULT"

# Read the SMILES from the sub-chunk
with open(sub_chunk, newline="") as f:
    reader = csv.reader(f)
    next(reader)  # skip header
    row = next(reader)
    smiles = row[0]

key = hashlib.md5(smiles.encode("utf-8")).hexdigest()

# Find property column names from any completed result in this bisect dir,
# falling back to the main output directory for this model
prop_cols = []
candidates = (
    glob.glob(os.path.join(bisect_dir, "result_*.csv")) +
    glob.glob(f"/fsx/output/{library_name}/{model_id}/{model_id}_results_*.csv")
)
for path in candidates:
    try:
        with open(path, newline="") as f:
            header = next(csv.reader(f))
        prop_cols = [c for c in header if c not in ("key", "input")]
        if prop_cols:
            break
    except Exception:
        continue

with open(sub_result, "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["key", "input"] + prop_cols)
    writer.writerow([key, smiles] + [""] * len(prop_cols))

print(f"Empty row written for key={key} smiles={smiles[:40]}...")
PYEOF

else
    # ── Multiple molecules: split into 10 pieces and resubmit ──────────────────
    echo "Splitting [${START}..${END}] into 10 pieces..."

    python3 - <<PYEOF
import csv, math, os

bisect_dir = "$BISECT_DIR"
sub_chunk  = "$SUB_CHUNK"
start      = $START
end        = $END
n_splits   = min(10, end - start + 1)   # never more pieces than molecules

with open(sub_chunk, newline="") as f:
    reader = csv.reader(f)
    header = next(reader)
    rows = list(reader)

piece = math.ceil(len(rows) / n_splits)
tasks_file = os.path.join(bisect_dir, f"tasks_{start}_{end}.txt")

with open(tasks_file, "w") as tf:
    for i in range(n_splits):
        s = start + i * piece
        e = min(s + piece - 1, end)
        if s > end:
            break
        sub_file = os.path.join(bisect_dir, f"sub_{s}_{e}.csv")
        with open(sub_file, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(header)
            writer.writerows(rows[i * piece : i * piece + (e - s + 1)])
        tf.write(f"{s} {e}\n")
        print(f"  [{s}..{e}] → {sub_file}")

print(f"Tasks file: {tasks_file}")
PYEOF
    PYTHON_EXIT=$?

    NEW_TASKS="${BISECT_DIR}/tasks_${START}_${END}.txt"

    if [ $PYTHON_EXIT -ne 0 ] || [ ! -f "$NEW_TASKS" ] || [ ! -s "$NEW_TASKS" ]; then
        echo "ERROR: Python failed to create sub-chunks or tasks file (exit ${PYTHON_EXIT})"
        exit 1
    fi

    N_TASKS=$(wc -l < "$NEW_TASKS" | tr -d ' ')

    JOB_OUTPUT=$(sbatch \
        --partition="$QUEUE" \
        --array=0-$((N_TASKS-1)) \
        --job-name="bisect_${MODEL_ID}_${CHUNK_NUM}_${START}_${END}" \
        --output="/shared/logs/bisect-%A_%a.out" \
        --error="/shared/logs/bisect-%A_%a.err" \
        /shared/scripts/run-ersilia-bisect.sh \
        "$MODEL_ID" \
        "$BISECT_DIR" \
        "$LIBRARY_NAME" \
        "$CHUNK_NUM" \
        "$NEW_TASKS" \
        "$QUEUE")

    JOB_ID=$(echo "$JOB_OUTPUT" | grep -oP '\d+$' || true)
    if [ -z "$JOB_ID" ]; then
        echo "ERROR: sbatch failed or returned unexpected output:"
        echo "$JOB_OUTPUT"
        exit 1
    fi
    echo "→ Submitted bisect array job: $JOB_ID for [${START}..${END}]"
fi

echo "=========================================="
echo "Bisect task done: $(date)"
echo "=========================================="
