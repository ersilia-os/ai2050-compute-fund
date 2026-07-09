#!/bin/bash
#SBATCH --job-name=drugclip-bisect
#SBATCH --nodes=1
#SBATCH --time=2-00:00:00
#SBATCH --output=/shared/logs/drugclip-bisect-%A_%a.out
#SBATCH --error=/shared/logs/drugclip-bisect-%A_%a.err
#SBATCH --open-mode=append

# Run one sub-chunk of a bisect on a failed DrugCLIP chunk.
#
# Submitted by run-drugclip-job.sh (initial split) or recursively by
# this script itself (subsequent splits). Never call directly.
#
# Args: LIBRARY_NAME CHUNK_NUM BISECT_DIR TASKS_FILE [QUEUE]
# TASKS_FILE: one sub-chunk CSV path per line; SLURM_ARRAY_TASK_ID selects the line.
#
# On success : writes BISECT_DIR/result_<sub_name>.csv
# On failure with N>1 : splits in half, submits new array job
# On failure with N==1: writes empty row to BISECT_DIR/result_<sub_name>.csv

LIBRARY_NAME=$1
CHUNK_NUM=$2
BISECT_DIR=$3
TASKS_FILE=$4
QUEUE=${5:-${SLURM_JOB_PARTITION:-gpu-queue}}

TASK_ID=${SLURM_ARRAY_TASK_ID:-0}

SUB_CHUNK=$(sed -n "$((TASK_ID+1))p" "$TASKS_FILE")
SUB_NAME=$(basename "$SUB_CHUNK" .csv)
SUB_RESULT="${BISECT_DIR}/result_${SUB_NAME}.csv"
N_ROWS=$(( $(wc -l < "$SUB_CHUNK") - 1 ))

SIF_FILE="/shared/sif-files/drugclip.sif"
WEIGHTS_DIR="/shared/drugclip-weights"

echo "=========================================="
echo "DrugCLIP Bisect Job"
echo "=========================================="
echo "Job: ${SLURM_JOB_ID:-local}  Task: ${TASK_ID}"
echo "Node: $(hostname)  Date: $(date)"
echo "Library: $LIBRARY_NAME  Chunk: $CHUNK_NUM"
echo "Sub-chunk: $(basename "$SUB_CHUNK") ($N_ROWS molecules)"
echo "Output: $SUB_RESULT"
echo "=========================================="

if [ ! -f "$SUB_CHUNK" ]; then
    echo "ERROR: Sub-chunk not found: $SUB_CHUNK"
    exit 1
fi

# GPU/CPU detection
if nvidia-smi &>/dev/null; then
    GPU_FLAG="--fp16"; NV_FLAG="--nv"
    echo "Device: GPU ($(nvidia-smi --query-gpu=name --format=csv,noheader | head -1))"
else
    GPU_FLAG="--cpu"; NV_FLAG=""
    echo "Device: CPU"
fi

TMP_DIR=$(mktemp -d /tmp/drugclip_bisect_${SLURM_JOB_ID:-$$}_XXXX)
trap "rm -rf $TMP_DIR" EXIT

LMDB_PATH="${TMP_DIR}/mols.lmdb"
H5_DIR="${TMP_DIR}/h5out"
mkdir -p "$H5_DIR"

# ── Step 1: SMILES → LMDB ────────────────────────────────────────────────────
echo "Step 1/2 — SMILES → LMDB ..."
apptainer exec \
    $NV_FLAG \
    --bind /fsx:/fsx \
    --bind /shared:/shared \
    --bind "${TMP_DIR}:${TMP_DIR}" \
    "$SIF_FILE" \
    python /drugclip/smiles_to_lmdb.py \
        --input  "$SUB_CHUNK" \
        --output "$LMDB_PATH"

# ── Step 2: LMDB → H5 ────────────────────────────────────────────────────────
if [ -d "$LMDB_PATH" ]; then
    echo "Step 2/2 — LMDB → H5 ..."
    apptainer exec \
        $NV_FLAG \
        --pwd /drugclip \
        --bind /fsx:/fsx \
        --bind /shared:/shared \
        --bind "${TMP_DIR}:${TMP_DIR}" \
        --bind "${WEIGHTS_DIR}:/drugclip/data/model_weights" \
        "$SIF_FILE" \
        python /drugclip/unimol/encode_mols.py \
            --user-dir /drugclip/unimol \
            /drugclip/dict \
            --valid-subset test \
            --num-workers 0 --ddp-backend=c10d --batch-size 256 \
            --task drugclip --loss in_batch_softmax --arch drugclip \
            --max-pocket-atoms 256 --seed 1 \
            --log-interval 100 --log-format simple \
            --mol-path "$LMDB_PATH" \
            --save-dir "$H5_DIR" \
            --write-h5 \
            $GPU_FLAG
fi

H5_FILE="${H5_DIR}/mol_reps.h5"
if [ ! -f "$H5_FILE" ]; then
    H5_FILE=$(ls "${H5_DIR}"/mol_reps*.h5 2>/dev/null | head -1)
fi

# Validate H5
N_EMB=0
if [ -n "$H5_FILE" ] && [ -f "$H5_FILE" ]; then
    N_EMB=$(/shared/python39/bin/python3.9 -c "
import h5py
try:
    with h5py.File('$H5_FILE', 'r') as f:
        print(f['mol_reps'].shape[0])
except: print(0)
" 2>/dev/null)
fi

# ── Success ───────────────────────────────────────────────────────────────────
if [ -n "$N_EMB" ] && [ "$N_EMB" -gt 0 ]; then
    SMILES_INDEX="${LMDB_PATH%.lmdb}.smiles.txt"
    /shared/python39/bin/python3.9 /shared/scripts/drugclip_scripts/h5_to_csv.py \
        --input        "$SUB_CHUNK" \
        --h5           "$H5_FILE" \
        --smiles-index "$SMILES_INDEX" \
        --output       "$SUB_RESULT"
    echo "✓ Success: $(basename "$SUB_RESULT") ($N_EMB embeddings)"
    exit 0
fi

# ── Failure ───────────────────────────────────────────────────────────────────
echo "✗ Failed on $(basename "$SUB_CHUNK") ($N_ROWS molecules)"

if [ "$N_ROWS" -le 1 ]; then
    # Single molecule — write empty row
    echo "Single molecule failed — writing empty row"
    /shared/python39/bin/python3.9 - "$SUB_CHUNK" "$SUB_RESULT" << 'PYEOF'
import csv, hashlib, sys
SMILES_COLS = {"smiles", "canonical_smiles", "input"}
HEADERS = (["key", "input"]
           + [f"fold-{f}-dim-{d:03d}" for f in range(6) for d in range(128)])
EMPTY = [""] * 768
with open(sys.argv[1], newline="") as fin, open(sys.argv[2], "w", newline="") as fout:
    reader = csv.DictReader(fin)
    lower = [c.strip().lower() for c in (reader.fieldnames or [])]
    col = next((o for o, l in zip(reader.fieldnames, lower) if l in SMILES_COLS), None)
    writer = csv.writer(fout)
    writer.writerow(HEADERS)
    for row in reader:
        smi = row[col].strip()
        writer.writerow([hashlib.md5(smi.encode()).hexdigest(), smi] + EMPTY)
PYEOF
    echo "Empty row written for $(basename "$SUB_CHUNK")"

else
    # Split in half and resubmit
    echo "Splitting $N_ROWS molecules in half and resubmitting..."
    NEW_TASKS="${BISECT_DIR}/tasks_${SUB_NAME}.txt"

    /shared/python39/bin/python3.9 - "$SUB_CHUNK" "$BISECT_DIR" "$NEW_TASKS" << 'PYEOF'
import csv, sys, os
with open(sys.argv[1], newline="") as f:
    reader = csv.DictReader(f)
    rows = list(reader)
    fn = reader.fieldnames
bisect_dir, tasks_file = sys.argv[2], sys.argv[3]
sub_name = os.path.basename(sys.argv[1]).replace(".csv", "")
half = (len(rows) + 1) // 2
with open(tasks_file, "w") as tf:
    for i, piece in enumerate([rows[:half], rows[half:]]):
        if not piece:
            continue
        path = os.path.join(bisect_dir, f"{sub_name}_p{i}.csv")
        with open(path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fn)
            w.writeheader()
            w.writerows(piece)
        tf.write(path + "\n")
        print(f"  piece {i}: {os.path.basename(path)} ({len(piece)} molecules)")
PYEOF

    if [ ! -f "$NEW_TASKS" ] || [ ! -s "$NEW_TASKS" ]; then
        echo "ERROR: Failed to create sub-chunks"
        exit 1
    fi

    N_TASKS=$(wc -l < "$NEW_TASKS" | tr -d ' ')
    JOB_OUTPUT=$(sbatch \
        --partition="$QUEUE" \
        --array=0-$((N_TASKS-1)) \
        --job-name="drugclip-bisect" \
        --output="/shared/logs/drugclip-bisect-%A_%a.out" \
        --error="/shared/logs/drugclip-bisect-%A_%a.err" \
        /shared/scripts/drugclip_scripts/run-drugclip-bisect.sh \
        "$LIBRARY_NAME" \
        "$CHUNK_NUM" \
        "$BISECT_DIR" \
        "$NEW_TASKS" \
        "$QUEUE")

    JOB_ID=$(echo "$JOB_OUTPUT" | grep -oP '\d+$' || true)
    if [ -z "$JOB_ID" ]; then
        echo "ERROR: sbatch failed: $JOB_OUTPUT"
        exit 1
    fi
    echo "→ Submitted bisect job $JOB_ID ($N_TASKS tasks)"
fi

echo "=========================================="
echo "Bisect task done: $(date)"
echo "=========================================="
