#!/bin/bash
#SBATCH --job-name=drugclip
#SBATCH --partition=gpu-queue
#SBATCH --nodes=1
#SBATCH --time=2-00:00:00
#SBATCH --output=/shared/logs/drugclip-%A_%a.out
#SBATCH --error=/shared/logs/drugclip-%A_%a.err
#SBATCH --open-mode=append

# Process one SMILES chunk through DrugCLIP to produce 768-dim embeddings.
#
# Called by submit-drugclip.sh via:
#   sbatch --partition=<queue> --array=0-N run-drugclip-job.sh <library_name> <chunk_list_file>
#
# Input  : CSV path read from chunk_list_file at line SLURM_ARRAY_TASK_ID+1
# Output : /fsx/output/<library>/drugclip/<library>_drugclip_<NNN>.h5
#
# Pipeline per chunk:
#   1. smiles_to_lmdb.py  — SMILES CSV → LMDB (RDKit 3D conformers)
#   2. encode_mols.py     — LMDB → HDF5 (768-dim DrugCLIP 6-fold ensemble embeddings)
#
# Weights are bind-mounted:
#   /shared/drugclip-weights  →  /drugclip/data/model_weights
# satisfying the hardcoded path in drugclip.py:
#   ./data/model_weights/6_folds/fold_{i}.pt

LIBRARY_NAME=$1
CHUNK_LIST=$2

if [ -z "$LIBRARY_NAME" ] || [ -z "$CHUNK_LIST" ]; then
    echo "ERROR: Usage: sbatch --array=0-N run-drugclip-job.sh <library_name> <chunk_list_file>"
    exit 1
fi

SIF_FILE="/shared/sif-files/drugclip.sif"
WEIGHTS_DIR="/shared/drugclip-weights"
OUTPUT_BASE="/fsx/output/${LIBRARY_NAME}/drugclip"

# ── Pick input file by array index ───────────────────────────────────────────
INPUT_FILE=$(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" "$CHUNK_LIST")

if [ -z "$INPUT_FILE" ]; then
    echo "ERROR: No file at index $SLURM_ARRAY_TASK_ID in $CHUNK_LIST"
    exit 1
fi

# Extract zero-padded chunk number: Library_chunk_042.csv → 042
CHUNK_NUM=$(basename "$INPUT_FILE" .csv | grep -oP '\d+$')
OUTPUT_FILE="${OUTPUT_BASE}/${LIBRARY_NAME}_drugclip_${CHUNK_NUM}.h5"
CSV_OUTPUT="${OUTPUT_BASE}/${LIBRARY_NAME}_drugclip_${CHUNK_NUM}.csv"

echo "=========================================="
echo "DrugCLIP Embedding Job"
echo "=========================================="
echo "Job ID     : $SLURM_JOB_ID"
echo "Array index: $SLURM_ARRAY_TASK_ID"
echo "Node       : $(hostname)"
echo "Date       : $(date)"
echo "Library    : $LIBRARY_NAME"
echo "Chunk      : $CHUNK_NUM"
echo "Input      : $INPUT_FILE"
echo "Output     : $OUTPUT_FILE"
echo "=========================================="

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if [ ! -f "$SIF_FILE" ]; then
    echo "ERROR: SIF not found: $SIF_FILE"
    echo "  Run: aws s3 cp s3://ai2050-ersilia-cluster/sif-files/drugclip.sif $SIF_FILE"
    exit 1
fi

if [ ! -d "${WEIGHTS_DIR}/model_weights/6_folds" ]; then
    echo "ERROR: Weights not found: ${WEIGHTS_DIR}/model_weights/6_folds/"
    echo "  Run: aws s3 sync s3://ai2050-ersilia-cluster/drugclip-weights/model_weights/6_folds/ \\"
    echo "       ${WEIGHTS_DIR}/model_weights/6_folds/"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: Input file not found: $INPUT_FILE"
    exit 1
fi

mkdir -p "$OUTPUT_BASE"

# ── GPU/CPU detection ─────────────────────────────────────────────────────────
if nvidia-smi &>/dev/null; then
    GPU_FLAG="--fp16"
    NV_FLAG="--nv"
    echo "Device: GPU ($(nvidia-smi --query-gpu=name --format=csv,noheader | head -1))"
else
    GPU_FLAG="--cpu"
    NV_FLAG=""
    echo "Device: CPU (no GPU detected)"
fi

# ── Temp workspace ────────────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d /tmp/drugclip_${SLURM_JOB_ID}_XXXX)
LMDB_PATH="${TMP_DIR}/mols.lmdb"
TMP_OUTPUT="${TMP_DIR}/embeddings"
mkdir -p "$TMP_OUTPUT"
trap "rm -rf ${TMP_DIR}" EXIT

# ── Step 1: SMILES CSV → LMDB ────────────────────────────────────────────────
echo ""
echo "Step 1/2 — Converting SMILES CSV → LMDB ..."
echo "  Input : $INPUT_FILE"
echo "  Output: $LMDB_PATH"

apptainer exec \
    $NV_FLAG \
    --bind /fsx:/fsx \
    --bind /shared:/shared \
    --bind "${TMP_DIR}:${TMP_DIR}" \
    "$SIF_FILE" \
    python /drugclip/smiles_to_lmdb.py \
        --input  "$INPUT_FILE" \
        --output "$LMDB_PATH"

if [ ! -d "$LMDB_PATH" ]; then
    echo "ERROR: LMDB was not created"
    exit 1
fi

# ── Step 2: LMDB → HDF5 (768-dim 6-fold embeddings) ─────────────────────────
echo ""
echo "Step 2/2 — Extracting DrugCLIP embeddings ..."
echo "  Input  : $LMDB_PATH"
echo "  Output : $TMP_OUTPUT/mol_reps.h5"

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
        --save-dir "$TMP_OUTPUT" \
        --write-h5 \
        $GPU_FLAG

# ── Move output to final path ─────────────────────────────────────────────────
# encode_mols.py outputs: mol_reps.h5 (no start/end → no suffix)
TMP_H5="${TMP_OUTPUT}/mol_reps.h5"

if [ ! -f "$TMP_H5" ]; then
    # Try with empty start/end suffix just in case
    TMP_H5=$(ls "${TMP_OUTPUT}"/mol_reps*.h5 2>/dev/null | head -1)
fi

if [ -z "$TMP_H5" ] || [ ! -f "$TMP_H5" ]; then
    echo "ERROR: Output HDF5 not found in $TMP_OUTPUT"
    ls -la "$TMP_OUTPUT" || true
    exit 1
fi

# Validate H5 is not empty before accepting it
N_EMBEDDINGS=$(/shared/python39/bin/python3.9 -c "
import h5py, sys
try:
    with h5py.File('$TMP_H5', 'r') as f:
        print(f['mol_reps'].shape[0])
except Exception:
    print(0)
" 2>/dev/null)

if [ -z "$N_EMBEDDINGS" ] || [ "$N_EMBEDDINGS" -le 0 ]; then
    echo "WARNING: HDF5 is empty — launching bisect for chunk $CHUNK_NUM"

    BISECT_DIR="${OUTPUT_BASE}/bisect_${CHUNK_NUM}"
    mkdir -p "$BISECT_DIR"
    QUEUE=${SLURM_JOB_PARTITION:-gpu-queue}

    # Split into 2 sub-chunks
    TASKS_FILE="${BISECT_DIR}/tasks_initial.txt"
    /shared/python39/bin/python3.9 - "$INPUT_FILE" "$BISECT_DIR" "$TASKS_FILE" << 'PYEOF'
import csv, sys, os
with open(sys.argv[1], newline="") as f:
    reader = csv.DictReader(f)
    rows = list(reader)
    fn = reader.fieldnames
bisect_dir, tasks_file = sys.argv[2], sys.argv[3]
half = (len(rows) + 1) // 2
with open(tasks_file, "w") as tf:
    for i, piece in enumerate([rows[:half], rows[half:]]):
        if not piece:
            continue
        path = os.path.join(bisect_dir, f"sub_p{i}.csv")
        with open(path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fn)
            w.writeheader()
            w.writerows(piece)
        tf.write(path + "\n")
        print(f"  piece {i}: {os.path.basename(path)} ({len(piece)} molecules)")
PYEOF

    N_TASKS=$(wc -l < "$TASKS_FILE" | tr -d ' ')
    JOB_OUTPUT=$(sbatch \
        --partition="$QUEUE" \
        --array=0-$((N_TASKS-1)) \
        --job-name="drugclip-bisect" \
        /shared/scripts/drugclip_scripts/run-drugclip-bisect.sh \
        "$LIBRARY_NAME" "$CHUNK_NUM" "$BISECT_DIR" "$TASKS_FILE" "$QUEUE")

    JOB_ID=$(echo "$JOB_OUTPUT" | grep -oP '\d+$' || true)
    if [ -z "$JOB_ID" ]; then
        echo "ERROR: bisect submission failed: $JOB_OUTPUT"
        exit 1
    fi
    echo "→ Submitted bisect job $JOB_ID ($N_TASKS tasks) for chunk $CHUNK_NUM"
    echo "  Bisect dir : $BISECT_DIR"
    echo "  Merge when done: bash /shared/scripts/drugclip_scripts/merge-drugclip-bisect.sh $LIBRARY_NAME $CHUNK_NUM"
    exit 0
fi

echo "  Embeddings: $N_EMBEDDINGS rows"
mv "$TMP_H5" "$OUTPUT_FILE"

# Move companion SMILES index (same row order as h5 embeddings)
TMP_SMILES="${LMDB_PATH%.lmdb}.smiles.txt"
SMILES_INDEX="${OUTPUT_BASE}/${LIBRARY_NAME}_drugclip_${CHUNK_NUM}.smiles.txt"
if [ -f "$TMP_SMILES" ]; then
    mv "$TMP_SMILES" "$SMILES_INDEX"
fi

SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)

# ── Step 3: HDF5 + SMILES index → ersilia-format CSV ─────────────────────────
echo ""
echo "Step 3/3 — Converting to ersilia CSV format ..."

if [ ! -f "$SMILES_INDEX" ]; then
    echo "WARNING: SMILES index not found ($SMILES_INDEX) — skipping CSV conversion"
else
    /shared/python39/bin/python3.9 /shared/scripts/drugclip_scripts/h5_to_csv.py \
        --input        "$INPUT_FILE" \
        --h5           "$OUTPUT_FILE" \
        --smiles-index "$SMILES_INDEX" \
        --output       "$CSV_OUTPUT" \
    && echo "  CSV: $CSV_OUTPUT ($(du -h "$CSV_OUTPUT" | cut -f1))" \
    || echo "ERROR: CSV conversion failed (h5 is still available at $OUTPUT_FILE)"
fi

echo ""
echo "SUCCESS: $OUTPUT_FILE ($SIZE)"
echo "=========================================="
echo "Job completed: $(date)"
echo "=========================================="
