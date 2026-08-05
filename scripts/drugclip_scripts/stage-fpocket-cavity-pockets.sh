#!/bin/bash
# Build fpocket-cavity pockets for all targets and upload to S3 (→ FSx).
#
# Runs LOCALLY, and needs the `fpocket` binary on PATH — run it inside the conda env
# that has fpocket, e.g.:
#     conda run -n pymol bash stage-fpocket-cavity-pockets.sh <targets_dir> <staging_dir>
#
# For each target it calls prepare_fpocket_cavity_for_drugclip.py (fpocket → cavity-shaped
# pseudo-ligand → *_LIG.pdb, same filenames/pocket_keys as the single-atom prep), laid out
# as <staging>/<dest-prefix>/<ID>/pockets/, then `aws s3 sync`s to
# s3://<bucket>/input/<dest-prefix>/  →  /fsx/input/<dest-prefix>/<ID>/pockets/.
#
# Usage:
#   stage-fpocket-cavity-pockets.sh <targets_dir> <staging_dir>
#       [--dest-prefix targets_fpocket] [--only ID1,ID2] [--cavity-radius 8.0]
#       [--dry-run] [--no-upload]

set -euo pipefail

TARGETS_DIR=${1:-}
STAGING_DIR=${2:-}
DEST_PREFIX=targets_fpocket
ONLY=
CAVITY_RADIUS=8.0
DRY_RUN=0
UPLOAD=1
S3_BUCKET=${S3_BUCKET:-ai2050-ersilia-cluster}

shift $(( $# >= 2 ? 2 : $# ))
while [ $# -gt 0 ]; do
    case "$1" in
        --dest-prefix)   DEST_PREFIX=$2; shift ;;
        --only)          ONLY=$2; shift ;;
        --cavity-radius) CAVITY_RADIUS=$2; shift ;;
        --dry-run)       DRY_RUN=1 ;;
        --no-upload)     UPLOAD=0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

if [ -z "$TARGETS_DIR" ] || [ -z "$STAGING_DIR" ]; then
    echo "Usage: $0 <targets_dir> <staging_dir> [--dest-prefix targets_fpocket] [--only IDs] [--cavity-radius R] [--dry-run] [--no-upload]"
    exit 1
fi
[ -d "$TARGETS_DIR" ] || { echo "ERROR: targets_dir not found: $TARGETS_DIR"; exit 1; }
command -v fpocket >/dev/null 2>&1 || { echo "ERROR: fpocket not on PATH — run inside the env that has it (e.g. conda run -n pymol ...)"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="${SCRIPT_DIR}/prepare_fpocket_cavity_for_drugclip.py"
S3_DEST="s3://${S3_BUCKET}/input/"

echo "=========================================="
echo "Stage fpocket-cavity pockets"
echo "=========================================="
echo "Targets dir  : $TARGETS_DIR"
echo "Staging dir  : $STAGING_DIR"
echo "S3 dest      : ${S3_DEST}${DEST_PREFIX}/<ID>/pockets/"
echo "Cavity radius: $CAVITY_RADIUS A"
echo "Only         : ${ONLY:-<all>}"
echo "Dry run      : $DRY_RUN   Upload: $UPLOAD"
echo "=========================================="

N=0
for d in "$TARGETS_DIR"/*/; do
    [ -d "$d" ] || continue
    TARGET=$(basename "$d")
    ls "$d"/*_center.txt >/dev/null 2>&1 || continue
    if [ -n "$ONLY" ] && ! echo ",$ONLY," | grep -q ",$TARGET,"; then continue; fi
    OUT_DIR="${STAGING_DIR}/${DEST_PREFIX}/${TARGET}/pockets"
    if [ "$DRY_RUN" -eq 1 ]; then
        python3 "$ADAPTER" --target-dir "$d" --out-dir "$OUT_DIR" --cavity-radius "$CAVITY_RADIUS" --dry-run
    else
        python3 "$ADAPTER" --target-dir "$d" --out-dir "$OUT_DIR" --cavity-radius "$CAVITY_RADIUS"
    fi
    N=$(( N + 1 ))
done

echo "------------------------------------------"
echo "Prepared $N target(s)"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would sync: aws s3 sync \"$STAGING_DIR/\" \"$S3_DEST\""
    exit 0
fi
if [ "$UPLOAD" -eq 0 ]; then
    echo "Skipping upload (--no-upload). Local files under: $STAGING_DIR/${DEST_PREFIX}/"
    exit 0
fi
echo "Uploading to ${S3_DEST}${DEST_PREFIX}/ ..."
aws s3 sync "$STAGING_DIR/${DEST_PREFIX}/" "${S3_DEST}${DEST_PREFIX}/" --no-progress
echo "Done → auto-imports to /fsx/input/${DEST_PREFIX}/<ID>/pockets/"
echo "Next (on the queue): POCKET_BASE=/fsx/input/${DEST_PREFIX} bash /shared/scripts/drugclip_scripts/submit-all-drugclip-pockets.sh 500"
echo "=========================================="
