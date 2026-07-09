#!/bin/bash
# Submit a DrugCLIP pocket encoding job for one target.
#
# Usage:
#   bash /shared/scripts/drugclip_scripts/submit-drugclip-pocket.sh <target_name> [pocket_dir]
#
# Examples:
#   bash /shared/scripts/drugclip_scripts/submit-drugclip-pocket.sh qcrB
#   bash /shared/scripts/drugclip_scripts/submit-drugclip-pocket.sh qcrB /fsx/input/qcrB/pockets
#
# Expects <pocket_dir> to contain {prefix}_pocket{N}_LIG.pdb files produced by:
#   python scripts/drugclip_scripts/prepare_fpocket_for_drugclip.py \
#       --protein <protein.pdb> --fpocket-dir <fpocket_out/pockets> \
#       --output-dir <pocket_dir> --prefix <target_name>
#
# Input  : <pocket_dir>/*.pdb
# Output : <pocket_dir>/pocket_reps.pkl  — (pocket_names, pocket_reps) where
#          pocket_reps.shape = (n_pockets, 6, 128)

TARGET_NAME=$1
POCKET_DIR=${2:-/fsx/input/${TARGET_NAME}/pockets}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$TARGET_NAME" ]; then
    echo "Usage: $0 <target_name> [pocket_dir]"
    echo ""
    echo "Examples:"
    echo "  $0 qcrB"
    echo "  $0 qcrB /fsx/input/qcrB/pockets"
    exit 1
fi

SIF_FILE="/shared/sif-files/drugclip_pocket.sif"
WEIGHTS_DIR="/shared/drugclip-weights"
OUTPUT_PKL="${POCKET_DIR}/pocket_reps.pkl"

echo "=========================================="
echo "DrugCLIP Pocket Encoding Submission"
echo "=========================================="
echo "Target     : $TARGET_NAME"
echo "Pocket dir : $POCKET_DIR"
echo "Output     : $OUTPUT_PKL"
echo "Queue      : gpu-queue"
echo "=========================================="

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if [ ! -f "$SIF_FILE" ]; then
    echo "ERROR: drugclip_pocket.sif not found at $SIF_FILE"
    echo "  Upload: aws s3 cp drugclip_pocket.sif s3://ai2050-ersilia-cluster/sif-files/drugclip_pocket.sif"
    echo "  Download on cluster: aws s3 cp s3://ai2050-ersilia-cluster/sif-files/drugclip_pocket.sif $SIF_FILE"
    exit 1
fi

if [ ! -f "${WEIGHTS_DIR}/6_folds/fold_0.pt" ]; then
    echo "ERROR: Weights not found at ${WEIGHTS_DIR}/6_folds/fold_0.pt"
    echo "  Run: aws s3 sync s3://ai2050-ersilia-cluster/drugclip-weights/model_weights/6_folds/ \\"
    echo "       ${WEIGHTS_DIR}/6_folds/"
    exit 1
fi

if [ ! -d "$POCKET_DIR" ]; then
    echo "ERROR: Pocket directory not found: $POCKET_DIR"
    echo "  Run prepare_fpocket_for_drugclip.py first to generate input PDB files"
    exit 1
fi

N_PDBS=$(ls "${POCKET_DIR}"/*.pdb 2>/dev/null | wc -l)
if [ "$N_PDBS" -eq 0 ]; then
    echo "ERROR: No .pdb files found in $POCKET_DIR"
    echo "  Run prepare_fpocket_for_drugclip.py first"
    exit 1
fi
echo "Found $N_PDBS pocket PDB files"

# ── Fix ownership if FSx imported the dir as root (common with S3 auto-import) ─
sudo chown ec2-user:ec2-user "$POCKET_DIR" 2>/dev/null || true

if [ -f "$OUTPUT_PKL" ]; then
    echo "WARNING: $OUTPUT_PKL already exists — job will skip encoding"
    echo "  Delete it first to re-run: rm $OUTPUT_PKL"
fi

mkdir -p /shared/logs

# ── Submit job ────────────────────────────────────────────────────────────────
JOB_ID=$(sbatch \
    --partition=gpu-queue \
    --job-name="drugclip-pocket-${TARGET_NAME}" \
    "${SCRIPT_DIR}/run-drugclip-pocket-job.sh" \
    "$TARGET_NAME" \
    "$POCKET_DIR" \
    2>&1 | grep -oP 'Submitted batch job \K\d+')

if [ -z "$JOB_ID" ]; then
    echo "ERROR: Job submission failed"
    exit 1
fi

echo ""
echo "Submitted job $JOB_ID"
echo ""
echo "Monitor:"
echo "  watch -n 5 'squeue -u \$USER'"
echo ""
echo "View log:"
echo "  tail -f /shared/logs/drugclip-pocket-${JOB_ID}.out"
echo ""
echo "Check output when done:"
echo "  /shared/python39/bin/python3.9 -c \""
echo "    import pickle"
echo "    names, reps = pickle.load(open('${OUTPUT_PKL}', 'rb'))"
echo "    print('pockets:', len(names), '| shape:', reps.shape)"
echo "  \""
echo "=========================================="
