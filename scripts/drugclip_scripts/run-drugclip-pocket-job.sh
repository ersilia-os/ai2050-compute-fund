#!/bin/bash
#SBATCH --job-name=drugclip-pocket
#SBATCH --partition=gpu-queue
#SBATCH --nodes=1
#SBATCH --time=2-00:00:00
#SBATCH --output=/shared/logs/drugclip-pocket-%j.out
#SBATCH --error=/shared/logs/drugclip-pocket-%j.err
#SBATCH --open-mode=append

# Encode binding pockets with DrugCLIP to produce (n_pockets, 6, 128) embeddings.
#
# Called by submit-drugclip-pocket.sh via:
#   sbatch run-drugclip-pocket-job.sh <target_name> <pocket_dir>
#
# Expects pocket_dir to already contain files named {prefix}_pocket{N}_LIG.pdb,
# prepared by scripts/drugclip_scripts/prepare_fpocket_for_drugclip.py.
#
# Input  : <pocket_dir>/*.pdb  (full protein + dummy LIG centroid per pocket)
# Output : <pocket_dir>/pocket_reps.pkl  — (pocket_names, pocket_reps) tuple
#          pocket_reps shape: (n_pockets, 6, 128)
#
# Weights bind-mounted (same 6-fold checkpoints as molecule encoder):
#   /shared/drugclip-weights  →  /drugclip/data/model_weights

TARGET_NAME=$1
POCKET_DIR=$2

if [ -z "$TARGET_NAME" ] || [ -z "$POCKET_DIR" ]; then
    echo "ERROR: Usage: sbatch run-drugclip-pocket-job.sh <target_name> <pocket_dir>"
    exit 1
fi

SIF_FILE="/shared/sif-files/drugclip_pocket.sif"
WEIGHTS_DIR="/shared/drugclip-weights"
OUTPUT_PKL="${POCKET_DIR}/pocket_reps.pkl"

echo "=========================================="
echo "DrugCLIP Pocket Encoding Job"
echo "=========================================="
echo "Job ID  : $SLURM_JOB_ID"
echo "Node    : $(hostname)"
echo "Date    : $(date)"
echo "Target  : $TARGET_NAME"
echo "Pockets : $POCKET_DIR"
echo "Output  : $OUTPUT_PKL"
echo "=========================================="

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if [ ! -f "$SIF_FILE" ]; then
    echo "ERROR: SIF not found: $SIF_FILE"
    echo "  Run: aws s3 cp s3://ai2050-ersilia-cluster/sif-files/drugclip_pocket.sif $SIF_FILE"
    exit 1
fi

if [ ! -f "${WEIGHTS_DIR}/6_folds/fold_0.pt" ]; then
    echo "ERROR: Weights not found: ${WEIGHTS_DIR}/6_folds/fold_0.pt"
    echo "  Run: aws s3 sync s3://ai2050-ersilia-cluster/drugclip-weights/model_weights/6_folds/ \\"
    echo "       ${WEIGHTS_DIR}/6_folds/"
    exit 1
fi

if [ ! -d "$POCKET_DIR" ]; then
    echo "ERROR: Pocket directory not found: $POCKET_DIR"
    exit 1
fi

N_PDBS=$(ls "${POCKET_DIR}"/*.pdb 2>/dev/null | wc -l)
if [ "$N_PDBS" -eq 0 ]; then
    echo "ERROR: No .pdb files found in $POCKET_DIR"
    echo "  Run prepare_fpocket_for_drugclip.py first"
    exit 1
fi
echo "Found $N_PDBS pocket PDB files"

# ── Skip if already done ──────────────────────────────────────────────────────
if [ -f "$OUTPUT_PKL" ]; then
    echo "Output already exists: $OUTPUT_PKL — skipping"
    exit 0
fi

# ── GPU check ─────────────────────────────────────────────────────────────────
if nvidia-smi &>/dev/null; then
    GPU_FLAG="--fp16"
    NV_FLAG="--nv"
    echo "Device: GPU ($(nvidia-smi --query-gpu=name --format=csv,noheader | head -1))"
else
    echo "ERROR: No GPU detected — this job requires gpu-queue"
    exit 1
fi

# ── Run pocket encoding ───────────────────────────────────────────────────────
echo ""
echo "Encoding pockets ..."

apptainer exec \
    $NV_FLAG \
    --pwd /drugclip \
    --bind /fsx:/fsx \
    --bind /shared:/shared \
    --bind "${POCKET_DIR}:${POCKET_DIR}" \
    --bind "${WEIGHTS_DIR}:/drugclip/data/model_weights" \
    "$SIF_FILE" \
    python /drugclip/unimol/encode_pockets.py \
        --user-dir /drugclip/unimol \
        /drugclip/dict \
        --valid-subset test \
        --num-workers 0 --ddp-backend=c10d \
        --task drugclip --loss in_batch_softmax --arch drugclip \
        --max-pocket-atoms 256 --seed 1 \
        --log-interval 10 --log-format simple \
        --pocket-dir "$POCKET_DIR" \
        --path /drugclip/data/model_weights/6_folds/fold_0.pt \
        $GPU_FLAG

# ── Validate output ───────────────────────────────────────────────────────────
if [ ! -f "$OUTPUT_PKL" ]; then
    echo "ERROR: pocket_reps.pkl was not created"
    exit 1
fi

/shared/python39/bin/python3.9 - "$OUTPUT_PKL" << 'PYEOF'
import pickle, sys
with open(sys.argv[1], "rb") as f:
    names, reps = pickle.load(f)
print(f"  Pockets  : {len(names)}")
print(f"  Reps shape: {reps.shape}  (n_pockets, n_folds, 128)")
print(f"  Names    : {names[:3]} ...")
PYEOF

echo ""
echo "SUCCESS: $OUTPUT_PKL"
echo "=========================================="
echo "Job completed: $(date)"
echo "=========================================="
