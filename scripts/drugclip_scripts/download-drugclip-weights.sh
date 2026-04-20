#!/bin/bash
# Download DrugCLIP model weights from HuggingFace and upload to S3.
#
# Run this ONCE from your local machine (needs internet + AWS credentials).
# The weights are already downloaded as model_weights.zip — this script
# handles extraction and S3 upload.
#
# Usage:
#   bash scripts/drugclip_scripts/download-drugclip-weights.sh
#
# Weights location:
#   HuggingFace: bgao95/DrugCLIP_data — model_weights.zip
#   Contains:    model_weights/6_folds/fold_0.pt ... fold_5.pt
#
# S3 destination:
#   s3://ai2050-ersilia-cluster/drugclip-weights/model_weights/6_folds/fold_*.pt
#
# On cluster (one-time setup after this script):
#   mkdir -p /shared/drugclip-weights/model_weights/6_folds
#   aws s3 sync s3://ai2050-ersilia-cluster/drugclip-weights/model_weights/6_folds/ \
#       /shared/drugclip-weights/model_weights/6_folds/

set -e

S3_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"
S3_PREFIX="drugclip-weights/model_weights/6_folds"
LOCAL_DIR="./drugclip-weights"
EXTRACTED_DIR="${LOCAL_DIR}/extracted/model_weights/6_folds"

echo "=========================================="
echo "DrugCLIP Weights Download & Upload"
echo "=========================================="

# ── Install huggingface_hub if needed ─────────────────────────────────────────
pip install -q huggingface_hub

# ── Download model_weights.zip if not already present ────────────────────────
ZIP_FILE="${LOCAL_DIR}/model_weights.zip"

if [ ! -f "$ZIP_FILE" ]; then
    echo "Downloading model_weights.zip from HuggingFace (bgao95/DrugCLIP_data) ..."
    mkdir -p "$LOCAL_DIR"
    python3 - << 'PYEOF'
import sys
from huggingface_hub import hf_hub_download

try:
    path = hf_hub_download(
        repo_id="bgao95/DrugCLIP_data",
        repo_type="dataset",
        filename="model_weights.zip",
        local_dir="./drugclip-weights",
    )
    print(f"Downloaded: {path}")
except Exception as e:
    print(f"ERROR: {e}")
    print()
    print("Please download model_weights.zip manually from:")
    print("  https://huggingface.co/datasets/bgao95/DrugCLIP_data")
    print("and place it at: ./drugclip-weights/model_weights.zip")
    sys.exit(1)
PYEOF
else
    echo "model_weights.zip already present: $ZIP_FILE"
fi

# ── Extract fold weights ──────────────────────────────────────────────────────
if [ ! -d "$EXTRACTED_DIR" ] || [ -z "$(ls -A $EXTRACTED_DIR 2>/dev/null)" ]; then
    echo "Extracting model_weights.zip ..."
    unzip -q "$ZIP_FILE" -d "${LOCAL_DIR}/extracted/"
    echo "Extracted to: ${LOCAL_DIR}/extracted/"
else
    echo "Already extracted: $EXTRACTED_DIR"
fi

# Verify fold files exist
echo ""
echo "Fold weights found:"
ls -lh "${EXTRACTED_DIR}"/fold_*.pt 2>/dev/null || {
    echo "ERROR: fold_*.pt files not found in $EXTRACTED_DIR"
    echo "Contents: $(ls ${LOCAL_DIR}/extracted/ 2>/dev/null)"
    exit 1
}

# ── Upload all fold weights to S3 ────────────────────────────────────────────
echo ""
echo "Uploading fold weights to s3://${S3_BUCKET}/${S3_PREFIX}/ ..."
aws s3 sync "${EXTRACTED_DIR}/" "s3://${S3_BUCKET}/${S3_PREFIX}/"

echo ""
echo "Verifying S3 upload ..."
aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/"

echo ""
echo "=========================================="
echo "Done. Next steps on the cluster:"
echo "=========================================="
echo "  mkdir -p /shared/drugclip-weights/model_weights/6_folds"
echo "  aws s3 sync s3://${S3_BUCKET}/${S3_PREFIX}/ \\"
echo "      /shared/drugclip-weights/model_weights/6_folds/"
echo "=========================================="
