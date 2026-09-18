#!/bin/bash
#SBATCH --job-name=pocket-encode
#SBATCH --partition=gpu-queue
#SBATCH --nodes=1
#SBATCH --time=2-00:00:00
#SBATCH --output=/shared/logs/pocket-encode-%j.out
#SBATCH --error=/shared/logs/pocket-encode-%j.err
#SBATCH --open-mode=append

# Encode binding pockets with DrugCLIP -> (n_pockets, 6, 128) embeddings.
#
# A copy of run-drugclip-pocket-job.sh with ONE difference: --max-pocket-atoms is a
# parameter instead of being hard-coded to 256.  The original is left untouched so the
# existing /fsx/input/targets pocket set stays exactly reproducible.
#
# Why this matters.  Upstream's own encode_pocket.sh uses 511; we shipped 256.  Measured
# on the production cavity pockets, 28% exceed 256 heavy atoms (median 225, max 434).
# Above the limit CroppingPocketDataset (unimol/data/cropping_dataset.py:45) takes a
# seeded random subsample weighted TOWARD the pocket centroid -- so it preferentially
# discards the periphery, which is where specificity-determining residues sit.  Silent,
# and it hits a quarter of the set.
#
# Usage (via submit-pocket-encode.sh, or directly):
#   sbatch run-pocket-encode.sh <target_name> <pocket_dir> [max_pocket_atoms]
#
# Input  : <pocket_dir>/*_LIG.pdb   (receptor heavy atoms + dummy/real LIG ligand)
# Output : <pocket_dir>/pocket_reps.pkl   -- (pocket_names, pocket_reps) tuple

TARGET_NAME=$1
POCKET_DIR=$2
MAX_POCKET_ATOMS=${3:-511}

if [ -z "$TARGET_NAME" ] || [ -z "$POCKET_DIR" ]; then
    echo "ERROR: Usage: sbatch run-pocket-encode.sh <target_name> <pocket_dir> [max_pocket_atoms]"
    exit 1
fi

# This job writes pocket_reps.pkl into POCKET_DIR and deletes a stale pocket.lmdb there.
# The production set at /fsx/input/targets holds the current best embeddings and must never
# be a target, however this script is invoked. submit-pocket-encode.sh guards POCKET_BASE;
# this guards the per-target dir as well, in case the job is ever launched by hand.
case "$(readlink -f "$POCKET_DIR" 2>/dev/null || echo "$POCKET_DIR")" in
    /fsx/input/targets/*)
        echo "ERROR: refusing to encode into the production set: $POCKET_DIR"
        echo "       Clone it to a new base first, e.g.:"
        echo "         POCKET_BASE=/fsx/input/targets_a511 bash submit-pocket-encode.sh \\"
        echo "           --clone-from /fsx/input/targets --max-pocket-atoms 511"
        exit 1 ;;
esac

SIF_FILE="/shared/sif-files/drugclip_pocket.sif"
# NOT derived from BASH_SOURCE: sbatch copies this script into Slurm's spool directory, so
# $(dirname "${BASH_SOURCE[0]}") resolves to /var/spool/slurm/... at runtime, not to the
# script's real location. submit-pocket-encode.sh exports PATCHED_TASK; this is the fallback.
PATCHED_TASK="${PATCHED_TASK:-/shared/scripts/drugclip_scripts/pocket_rebuild/patched/drugclip.py}"
WEIGHTS_DIR="/shared/drugclip-weights"
OUTPUT_PKL="${POCKET_DIR}/pocket_reps.pkl"

echo "=========================================="
echo "DrugCLIP Pocket Encoding (pocket_rebuild)"
echo "=========================================="
echo "Job ID          : $SLURM_JOB_ID"
echo "Node            : $(hostname)"
echo "Date            : $(date)"
echo "Target          : $TARGET_NAME"
echo "Pockets         : $POCKET_DIR"
echo "max-pocket-atoms: $MAX_POCKET_ATOMS"
echo "Output          : $OUTPUT_PKL"
echo "=========================================="

# -- Pre-flight checks --------------------------------------------------------
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
    exit 1
fi
echo "Found $N_PDBS pocket PDB files"

# -- Skip if already done -----------------------------------------------------
if [ -f "$OUTPUT_PKL" ]; then
    echo "Output already exists: $OUTPUT_PKL - skipping"
    exit 0
fi

# encode_pockets.py only builds pocket.lmdb when it is absent; a stale one from a
# previous run at a different --max-pocket-atoms would be silently reused.  The crop
# happens after the lmdb, so this is belt-and-braces rather than strictly required.
if [ -e "${POCKET_DIR}/pocket.lmdb" ]; then
    echo "Removing stale pocket.lmdb so it is rebuilt for this run"
    rm -rf "${POCKET_DIR}/pocket.lmdb"
fi

# -- GPU check ----------------------------------------------------------------
if nvidia-smi &>/dev/null; then
    GPU_FLAG="--fp16"
    NV_FLAG="--nv"
    echo "Device: GPU ($(nvidia-smi --query-gpu=name --format=csv,noheader | head -1))"
elif [ "${ALLOW_CPU:-0}" != "0" ]; then
    # NOTE: GPU is the intended path for all DrugCLIP work (Marina, 2026-09-15). This branch
    # exists only as an explicit, opt-in escape hatch and should not be used by default.
    # Pocket encoding is tiny next to the molecule deck -- a few hundred conformations, not
    # 36k molecules -- so CPU is a viable fallback when gpu-queue has no capacity
    # (eu-north-1a runs out of g6/g6e/g4dn regularly). No --fp16: half precision is a GPU
    # path, and forcing it on CPU either errors or silently degrades the embeddings.
    GPU_FLAG=""
    NV_FLAG=""
    echo "Device: CPU (ALLOW_CPU=1; no --fp16)"
    echo "  NOTE embeddings will be fp32 here and fp16 on GPU. Cosine agreement between the"
    echo "       two is ~0.9999, but do not mix devices within one comparison if you can"
    echo "       avoid it -- encode every set in a comparison the same way."
else
    echo "ERROR: No GPU detected - this job requires gpu-queue"
    echo "  To run on CPU instead (viable for pocket encoding): ALLOW_CPU=1"
    exit 1
fi

# -- Run pocket encoding ------------------------------------------------------
echo ""
echo "Encoding pockets ..."

# POCKET_BATCH_SIZE lowers the hardcoded DataLoader batch (32) in
# encode_pockets_multi_folds, whose (batch, N, N, 128) Gaussian tensor OOMs on large
# pockets. Bind-mounting the patched task file avoids rebuilding the sif. This changes
# only HOW MANY conformations are encoded at once -- never the embeddings themselves.
BATCH_BIND=""
BATCH_ENV=""
if [ -n "${POCKET_BATCH_SIZE:-}" ]; then
    if [ ! -f "$PATCHED_TASK" ]; then
        echo "ERROR: POCKET_BATCH_SIZE set but $PATCHED_TASK is missing."
        echo "       Run: bash /shared/scripts/drugclip_scripts/pocket_rebuild/patch-pocket-batch.sh"
        exit 1
    fi
    BATCH_BIND="--bind ${PATCHED_TASK}:/drugclip/unimol/tasks/drugclip.py"
    BATCH_ENV="--env POCKET_BATCH_SIZE=${POCKET_BATCH_SIZE}"
    echo "Pocket batch size: ${POCKET_BATCH_SIZE} (patched task bind-mounted)"
else
    echo "Pocket batch size: 32 (sif default)"
fi

apptainer exec \
    $NV_FLAG \
    $BATCH_BIND $BATCH_ENV \
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
        --max-pocket-atoms "$MAX_POCKET_ATOMS" --seed 1 \
        --log-interval 10 --log-format simple \
        --pocket-dir "$POCKET_DIR" \
        --path /drugclip/data/model_weights/6_folds/fold_0.pt \
        $GPU_FLAG
RC=$?

if [ $RC -ne 0 ]; then
    echo "ERROR: encode_pockets.py exited $RC"
    exit $RC
fi

# -- Validate output ----------------------------------------------------------
if [ ! -f "$OUTPUT_PKL" ]; then
    echo "ERROR: pocket_reps.pkl was not created"
    exit 1
fi

# process_one_pdbdir swallows per-file errors with `except: pass`, so a malformed PDB
# vanishes from the lmdb without a trace.  Compare counts rather than trusting the run.
/shared/python39/bin/python3.9 - "$OUTPUT_PKL" "$N_PDBS" << 'PYEOF'
import pickle, sys
import numpy as np
with open(sys.argv[1], "rb") as f:
    names, reps = pickle.load(f)
expected = int(sys.argv[2])
print(f"  Pockets   : {len(names)}  (expected {expected} from *.pdb)")
print(f"  Reps shape: {reps.shape}  (n_pockets, n_folds, 128)")
print(f"  Names     : {list(names[:3])} ...")
norms = np.linalg.norm(np.asarray(reps), axis=2)
print(f"  Per-fold norms: min {norms.min():.4f} max {norms.max():.4f}  (expect ~1.0)")
if len(names) != expected:
    print(f"  WARNING: {expected - len(names)} pocket(s) silently dropped by "
          f"process_one_pdbdir's bare except")
if norms.min() < 0.9:
    print("  WARNING: some embeddings are not unit-norm - encode was incomplete")
PYEOF

echo ""
echo "SUCCESS: $OUTPUT_PKL"
echo "=========================================="
echo "Job completed: $(date)"
echo "=========================================="
