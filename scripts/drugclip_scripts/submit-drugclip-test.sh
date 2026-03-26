#!/bin/bash
# Submit a single DrugCLIP test job using test_smiles_100.csv from S3.
#
# Usage:
#   bash /shared/scripts/drugclip/submit-drugclip-test.sh [queue]
#
# Examples:
#   bash /shared/scripts/drugclip/submit-drugclip-test.sh
#   bash /shared/scripts/drugclip/submit-drugclip-test.sh gpu-queue
#   bash /shared/scripts/drugclip/submit-drugclip-test.sh cpu-queue
#
# What it does:
#   1. Downloads test_smiles_100.csv from S3 to /fsx/input/test/
#   2. Submits a single DrugCLIP job (not an array)
#   3. Output: /fsx/output/test/drugclip/test_drugclip_000.h5

QUEUE=${1:-gpu-queue}

S3_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"
TEST_INPUT_S3="s3://${S3_BUCKET}/input/test_smiles_100.csv"
TEST_INPUT_LOCAL="/fsx/input/test/test_smiles_100.csv"
TEST_OUTPUT_DIR="/fsx/output/test/drugclip"
TEST_OUTPUT_FILE="${TEST_OUTPUT_DIR}/test_drugclip_000.h5"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "DrugCLIP Test Submission"
echo "=========================================="
echo "Queue    : $QUEUE"
echo "Input S3 : $TEST_INPUT_S3"
echo "Output   : $TEST_OUTPUT_FILE"
echo "=========================================="

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if [ ! -f "/shared/sif-files/drugclip.sif" ]; then
    echo "ERROR: drugclip.sif not found at /shared/sif-files/drugclip.sif"
    echo "  Download: aws s3 cp s3://${S3_BUCKET}/sif-files/drugclip.sif /shared/sif-files/"
    exit 1
fi

if [ ! -f "/shared/drugclip-weights/checkpoint_best.pt" ]; then
    echo "ERROR: Weights not found at /shared/drugclip-weights/checkpoint_best.pt"
    echo "  Download: aws s3 cp s3://${S3_BUCKET}/drugclip-weights/checkpoint_best.pt /shared/drugclip-weights/"
    exit 1
fi

# ── Download test file from S3 ────────────────────────────────────────────────
mkdir -p "$(dirname "$TEST_INPUT_LOCAL")"

if [ ! -f "$TEST_INPUT_LOCAL" ]; then
    echo "Downloading test file from S3 ..."
    aws s3 cp "$TEST_INPUT_S3" "$TEST_INPUT_LOCAL"
    echo "Downloaded: $TEST_INPUT_LOCAL ($(( $(wc -l < "$TEST_INPUT_LOCAL") - 1 )) molecules)"
else
    echo "Test file already present: $TEST_INPUT_LOCAL"
fi

mkdir -p "$TEST_OUTPUT_DIR"

# ── Write a one-line chunk list for the job script ────────────────────────────
CHUNK_LIST="${TEST_OUTPUT_DIR}/chunk_list_test.txt"
echo "$TEST_INPUT_LOCAL" > "$CHUNK_LIST"

# ── Submit single job (array size 1) ─────────────────────────────────────────
JOB_ID=$(sbatch \
    --partition="$QUEUE" \
    --array=0-0 \
    --job-name=drugclip-test \
    "${SCRIPT_DIR}/run-drugclip-job.sh" \
    "test" \
    "$CHUNK_LIST" \
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
echo "  tail -f /shared/logs/drugclip-${JOB_ID}.out"
echo ""
echo "Check output when done:"
echo "  python3 -c \""
echo "    import h5py"
echo "    f = h5py.File('${TEST_OUTPUT_FILE}', 'r')"
echo "    print('Embeddings shape:', f['embeddings'].shape)"
echo "    print('First SMILES:', f['smiles'][0])"
echo "  \""
echo "=========================================="
