#!/bin/bash
#SBATCH --job-name=drugclip
#SBATCH --partition=gpu-queue
#SBATCH --nodes=1
#SBATCH --time=04:00:00
#SBATCH --output=/shared/logs/drugclip-%j.out
#SBATCH --error=/shared/logs/drugclip-%j.err

# Process one SMILES chunk through DrugCLIP to produce 128-dim embeddings.
#
# Called by submit-drugclip.sh via:
#   sbatch --partition=<queue> --array=0-N run-drugclip-job.sh <library_name> <chunk_list_file>
#
# Input  : CSV path read from chunk_list_file at line SLURM_ARRAY_TASK_ID+1
# Output : /fsx/output/<library>/drugclip/<library>_drugclip_<NNN>.h5
#
# Pipeline per chunk:
#   1. smiles_to_lmdb.py  — SMILES CSV → LMDB (RDKit 3D conformers)
#   2. extract_mol_embeddings.py — LMDB → HDF5 (128-dim DrugCLIP embeddings)

LIBRARY_NAME=$1
CHUNK_LIST=$2

if [ -z "$LIBRARY_NAME" ] || [ -z "$CHUNK_LIST" ]; then
    echo "ERROR: Usage: sbatch --array=0-N run-drugclip-job.sh <library_name> <chunk_list_file>"
    exit 1
fi

SIF_FILE="/shared/sif-files/drugclip.sif"
WEIGHTS="/shared/drugclip-weights/checkpoint_best.pt"
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

if [ ! -f "$WEIGHTS" ]; then
    echo "ERROR: Weights not found: $WEIGHTS"
    echo "  Run: aws s3 cp s3://ai2050-ersilia-cluster/drugclip-weights/checkpoint_best.pt $WEIGHTS"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: Input file not found: $INPUT_FILE"
    exit 1
fi

mkdir -p "$OUTPUT_BASE"

# ── GPU detection ─────────────────────────────────────────────────────────────
if nvidia-smi &>/dev/null; then
    CPU_FLAG=""
    echo "Device: GPU ($(nvidia-smi --query-gpu=name --format=csv,noheader | head -1))"
else
    CPU_FLAG="--cpu"
    echo "Device: CPU (no GPU detected)"
fi

# ── Temp workspace ────────────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d /tmp/drugclip_${SLURM_JOB_ID}_XXXX)
LMDB_PATH="${TMP_DIR}/mols.lmdb"
EMB_CACHE="${TMP_DIR}/emb_cache"
trap "rm -rf ${TMP_DIR}" EXIT

echo ""
echo "Step 1/2 — Converting SMILES CSV → LMDB ..."
echo "  Input : $INPUT_FILE"
echo "  Output: $LMDB_PATH"

apptainer exec \
    --nv \
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

echo ""
echo "Step 2/2 — Extracting DrugCLIP embeddings ..."
echo "  Input  : $LMDB_PATH"
echo "  Output : $OUTPUT_FILE"

apptainer exec \
    --nv \
    --bind /fsx:/fsx \
    --bind /shared:/shared \
    --bind "${TMP_DIR}:${TMP_DIR}" \
    "$SIF_FILE" \
    python /drugclip/extract_mol_embeddings.py \
        --lmdb        "$LMDB_PATH" \
        --checkpoint  "$WEIGHTS" \
        --output      "$OUTPUT_FILE" \
        --dict-dir    /drugclip/data \
        --batch-size  256 \
        --emb-cache   "$EMB_CACHE" \
        $CPU_FLAG

if [ -f "$OUTPUT_FILE" ]; then
    SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
    echo ""
    echo "SUCCESS: $OUTPUT_FILE ($SIZE)"
else
    echo "ERROR: Output HDF5 was not created"
    exit 1
fi

echo "=========================================="
echo "Job completed: $(date)"
echo "=========================================="
