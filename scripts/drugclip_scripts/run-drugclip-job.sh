#!/bin/bash
#SBATCH --job-name=drugclip
#SBATCH --partition=gpu-queue
#SBATCH --nodes=1
#SBATCH --time=04:00:00
#SBATCH --output=/shared/logs/drugclip-%j.out
#SBATCH --error=/shared/logs/drugclip-%j.err

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

mv "$TMP_H5" "$OUTPUT_FILE"

# Move companion SMILES index (same row order as h5 embeddings)
TMP_SMILES="${LMDB_PATH%.lmdb}.smiles.txt"
if [ -f "$TMP_SMILES" ]; then
    mv "$TMP_SMILES" "${OUTPUT_BASE}/${LIBRARY_NAME}_drugclip_${CHUNK_NUM}.smiles.txt"
fi

SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)

echo ""
echo "SUCCESS: $OUTPUT_FILE ($SIZE)"
echo "=========================================="
echo "Job completed: $(date)"
echo "=========================================="
