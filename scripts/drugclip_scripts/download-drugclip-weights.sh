#!/bin/bash
# Download DrugCLIP model weights and upload to S3.
#
# Run this ONCE from your local machine (needs internet + AWS credentials).
# The weights are then available to the cluster via S3.
#
# Usage:
#   bash scripts/drugclip_scripts/download-drugclip-weights.sh
#
# Download strategy (tries in order):
#   1. HuggingFace dataset THU-ATOM/DrugCLIP_data — benchmark_weights.zip
#      (pretrained screening model — what we want for embedding)
#   2. Google Drive folder (fallback, requires gdown)
#      https://drive.google.com/drive/folders/1zW1MGpgunynFxTKXC2Q4RgWxZmg6CInV
#
# On cluster (one-time setup after this script):
#   mkdir -p /shared/drugclip-weights
#   aws s3 cp s3://ai2050-ersilia-cluster/drugclip-weights/checkpoint_best.pt \
#       /shared/drugclip-weights/checkpoint_best.pt

set -e

S3_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"
S3_KEY="drugclip-weights/checkpoint_best.pt"
LOCAL_DIR="./drugclip-weights"
WEIGHTS_FILE="${LOCAL_DIR}/checkpoint_best.pt"

echo "=========================================="
echo "DrugCLIP Weights Download"
echo "=========================================="

mkdir -p "$LOCAL_DIR"

# ── Install dependencies ──────────────────────────────────────────────────────
pip install -q huggingface_hub gdown

# ── Strategy 1: HuggingFace — download benchmark_weights.zip and extract ──────
echo ""
echo "Strategy 1: HuggingFace (THU-ATOM/DrugCLIP_data) ..."

python3 - << 'PYEOF'
import os, sys, zipfile
from huggingface_hub import hf_hub_download

LOCAL_DIR = "./drugclip-weights"

# The HuggingFace dataset has benchmark_weights.zip (pretrained screening model)
# and model_weights.zip (wet-lab fine-tuned). We want benchmark_weights.zip.
zip_candidates = [
    ("THU-ATOM/DrugCLIP_data", "dataset", "benchmark_weights.zip"),
    ("THU-ATOM/DrugCLIP_data", "dataset", "model_weights.zip"),
]

zip_path = None
for repo_id, repo_type, filename in zip_candidates:
    try:
        print(f"  Trying {filename} ...")
        zip_path = hf_hub_download(
            repo_id=repo_id,
            repo_type=repo_type,
            filename=filename,
            local_dir=LOCAL_DIR,
        )
        print(f"  Downloaded: {zip_path}")
        break
    except Exception as e:
        print(f"  Not found: {e}")

if zip_path is None:
    print("  HuggingFace download failed — will try Google Drive next.")
    sys.exit(1)

# Extract and find checkpoint_best.pt
print(f"  Extracting {zip_path} ...")
with zipfile.ZipFile(zip_path, "r") as z:
    names = z.namelist()
    print(f"  ZIP contents: {names[:10]}")

    # Find checkpoint_best.pt anywhere in the zip
    ckpt_names = [n for n in names if os.path.basename(n) == "checkpoint_best.pt"]
    if not ckpt_names:
        print(f"  checkpoint_best.pt not found in ZIP. All files: {names}")
        sys.exit(1)

    # Use the first match (prefer shortest path = least nested)
    ckpt_name = sorted(ckpt_names, key=len)[0]
    print(f"  Extracting: {ckpt_name}")
    source = z.open(ckpt_name)
    dest   = os.path.join(LOCAL_DIR, "checkpoint_best.pt")
    with open(dest, "wb") as f:
        f.write(source.read())
    print(f"  Saved to: {dest}")

print("  HuggingFace download successful.")
PYEOF

HF_SUCCESS=$?

# ── Strategy 2: Google Drive fallback ────────────────────────────────────────
if [ $HF_SUCCESS -ne 0 ] || [ ! -f "$WEIGHTS_FILE" ]; then
    echo ""
    echo "Strategy 2: Google Drive (gdown) ..."
    echo "  Folder: https://drive.google.com/drive/folders/1zW1MGpgunynFxTKXC2Q4RgWxZmg6CInV"
    echo ""
    echo "  Attempting to download checkpoint_best.pt from Google Drive folder ..."

    # gdown folder download — downloads all files in the folder
    python3 - << 'PYEOF'
import os, sys, glob

try:
    import gdown
except ImportError:
    import subprocess
    subprocess.check_call(["pip", "install", "-q", "gdown"])
    import gdown

LOCAL_DIR = "./drugclip-weights"
FOLDER_ID = "1zW1MGpgunynFxTKXC2Q4RgWxZmg6CInV"

print(f"  Downloading from Google Drive folder {FOLDER_ID} ...")
try:
    gdown.download_folder(
        id=FOLDER_ID,
        output=LOCAL_DIR,
        quiet=False,
        use_cookies=False,
    )
except Exception as e:
    print(f"  Folder download failed: {e}")
    print("  Trying direct file download ...")
    # Try common direct file IDs if folder fails
    sys.exit(1)

# Find checkpoint_best.pt in downloaded files
matches = glob.glob(f"{LOCAL_DIR}/**/checkpoint_best.pt", recursive=True)
if not matches:
    print(f"  checkpoint_best.pt not found in downloaded files.")
    print(f"  Files downloaded: {os.listdir(LOCAL_DIR)}")
    sys.exit(1)

src = matches[0]
dst = os.path.join(LOCAL_DIR, "checkpoint_best.pt")
if src != dst:
    import shutil
    shutil.copy2(src, dst)
    print(f"  Copied {src} -> {dst}")

print("  Google Drive download successful.")
PYEOF

fi

# ── Final check ───────────────────────────────────────────────────────────────
if [ ! -f "$WEIGHTS_FILE" ]; then
    echo ""
    echo "ERROR: Automatic download failed."
    echo ""
    echo "Please download manually:"
    echo "  1. Go to: https://drive.google.com/drive/folders/1zW1MGpgunynFxTKXC2Q4RgWxZmg6CInV"
    echo "  2. Download checkpoint_best.pt"
    echo "  3. Place it at: ${WEIGHTS_FILE}"
    echo "  4. Then re-run this script from Step 'Upload to S3':"
    echo "       aws s3 cp ${WEIGHTS_FILE} s3://${S3_BUCKET}/${S3_KEY}"
    exit 1
fi

SIZE=$(du -h "$WEIGHTS_FILE" | cut -f1)
echo ""
echo "Checkpoint ready: $WEIGHTS_FILE ($SIZE)"

# ── Upload to S3 ──────────────────────────────────────────────────────────────
echo ""
echo "Uploading to s3://${S3_BUCKET}/${S3_KEY} ..."
aws s3 cp "$WEIGHTS_FILE" "s3://${S3_BUCKET}/${S3_KEY}"
aws s3 ls "s3://${S3_BUCKET}/${S3_KEY}"

echo ""
echo "=========================================="
echo "Done. Next steps on the cluster:"
echo "=========================================="
echo "  mkdir -p /shared/drugclip-weights"
echo "  aws s3 cp s3://${S3_BUCKET}/${S3_KEY} /shared/drugclip-weights/checkpoint_best.pt"
echo "=========================================="
