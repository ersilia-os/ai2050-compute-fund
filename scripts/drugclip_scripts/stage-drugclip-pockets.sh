#!/bin/bash
# Prepare DrugCLIP pocket inputs for all AI2050 targets and upload them to S3.
#
# For every UniProt target folder under <targets_dir>, runs
# prepare_centers_for_drugclip.py to turn its pocket-center files + refined
# ensemble into <stem>_LIG.pdb files, laid out locally as:
#
#   <staging_dir>/targets/<ID>/pockets/*.pdb
#   <staging_dir>/targets/<ID>/pockets/manifest.csv
#
# then `aws s3 sync`s <staging_dir>/ to s3://<bucket>/input/ so the files land at
#   s3://<bucket>/input/targets/<ID>/pockets/...
# which FSx auto-imports (AutoImportPolicy: NEW_CHANGED) to
#   /fsx/input/targets/<ID>/pockets/...
#
# Usage:
#   stage-drugclip-pockets.sh <targets_dir> <staging_dir> [--dry-run] [--no-upload]
#
# Example:
#   stage-drugclip-pockets.sh /home/marina/Documents/AI2050/Targets/targets ./staging

set -euo pipefail

TARGETS_DIR=${1:-}
STAGING_DIR=${2:-}
DRY_RUN=0
UPLOAD=1
S3_BUCKET=${S3_BUCKET:-ai2050-ersilia-cluster}

for arg in "${@:3}"; do
    case "$arg" in
        --dry-run)   DRY_RUN=1 ;;
        --no-upload) UPLOAD=0 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

if [ -z "$TARGETS_DIR" ] || [ -z "$STAGING_DIR" ]; then
    echo "Usage: $0 <targets_dir> <staging_dir> [--dry-run] [--no-upload]"
    echo ""
    echo "  targets_dir  - folder of UniProt target subfolders (P00519/, Q9UM73/, ...)"
    echo "  staging_dir  - local dir to build targets/<ID>/pockets/ before upload"
    echo "  --dry-run    - report per-target counts only; write nothing, upload nothing"
    echo "  --no-upload  - prepare files locally but skip the S3 sync"
    exit 1
fi

if [ ! -d "$TARGETS_DIR" ]; then
    echo "ERROR: targets_dir not found: $TARGETS_DIR"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="${SCRIPT_DIR}/prepare_centers_for_drugclip.py"
S3_DEST="s3://${S3_BUCKET}/input/"

echo "=========================================="
echo "Stage DrugCLIP pockets"
echo "=========================================="
echo "Targets dir : $TARGETS_DIR"
echo "Staging dir : $STAGING_DIR"
echo "S3 dest     : ${S3_DEST}targets/<ID>/pockets/"
echo "Dry run     : $DRY_RUN"
echo "Upload      : $UPLOAD"
echo "=========================================="

N_TARGETS=0
for d in "$TARGETS_DIR"/*/; do
    [ -d "$d" ] || continue
    TARGET=$(basename "$d")
    # Skip folders with no pocket-center files (e.g. non-target dirs)
    if ! ls "$d"/*_center.txt >/dev/null 2>&1; then
        continue
    fi
    OUT_DIR="${STAGING_DIR}/targets/${TARGET}/pockets"
    if [ "$DRY_RUN" -eq 1 ]; then
        python3 "$ADAPTER" --target-dir "$d" --out-dir "$OUT_DIR" --dry-run
    else
        python3 "$ADAPTER" --target-dir "$d" --out-dir "$OUT_DIR"
    fi
    N_TARGETS=$(( N_TARGETS + 1 ))
done

echo "------------------------------------------"
echo "Prepared $N_TARGETS target(s)"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would sync: aws s3 sync \"$STAGING_DIR/\" \"$S3_DEST\""
    exit 0
fi

if [ "$UPLOAD" -eq 0 ]; then
    echo "Skipping upload (--no-upload). Local files are under: $STAGING_DIR/targets/"
    exit 0
fi

echo ""
echo "Uploading to $S3_DEST ..."
aws s3 sync "$STAGING_DIR/" "$S3_DEST" --no-progress
echo ""
echo "Done. Files will auto-import to /fsx/input/targets/<ID>/pockets/ on first access."
echo "Next: on the head node run submit-all-drugclip-pockets.sh"
echo "=========================================="
