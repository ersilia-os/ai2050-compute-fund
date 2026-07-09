#!/bin/bash
# Upload finished DrugCLIP pocket embeddings from FSx to S3.
#
# The pocket jobs write pocket_reps.pkl into /fsx/input/targets/<ID>/pockets/, which
# is FSx scratch and NOT auto-exported (FSx only exports /fsx/output).  This script
# copies each target's pocket_reps.pkl and manifest.csv to:
#
#   s3://<bucket>/output/targets/<ID>/pockets/pocket_reps.pkl
#   s3://<bucket>/output/targets/<ID>/pockets/manifest.csv
#
# The manifest is required downstream to group conformations back to their pocket
# (screening max-pools similarity scores across a pocket's conformations).
#
# Usage:
#   collect-drugclip-pockets.sh
#
# Env:
#   S3_BUCKET  (default: ai2050-ersilia-cluster)

set -uo pipefail

POCKET_BASE="${POCKET_BASE:-/fsx/input/targets}"
S3_BUCKET=${S3_BUCKET:-ai2050-ersilia-cluster}

if [ ! -d "$POCKET_BASE" ]; then
    echo "ERROR: $POCKET_BASE not found"
    exit 1
fi

POCKET_DIRS=($(ls -d "$POCKET_BASE"/*/pockets 2>/dev/null | sort || true))
if [ ${#POCKET_DIRS[@]} -eq 0 ]; then
    echo "No targets found under $POCKET_BASE"
    exit 0
fi

echo "=========================================="
echo "Collect DrugCLIP pocket embeddings → S3"
echo "=========================================="
echo "Dest: s3://${S3_BUCKET}/output/targets/<ID>/pockets/"
echo "=========================================="

UPLOADED=0
SKIPPED=0

for PDIR in "${POCKET_DIRS[@]}"; do
    TARGET=$(basename "$(dirname "$PDIR")")
    PKL="${PDIR}/pocket_reps.pkl"
    DEST="s3://${S3_BUCKET}/output/targets/${TARGET}/pockets"

    if [ ! -f "$PKL" ]; then
        echo "  SKIP  $TARGET (no pocket_reps.pkl)"
        SKIPPED=$(( SKIPPED + 1 ))
        continue
    fi

    echo -n "  $TARGET ... "
    if aws s3 cp "$PKL" "${DEST}/pocket_reps.pkl" --no-progress >/dev/null; then
        if [ -f "${PDIR}/manifest.csv" ]; then
            aws s3 cp "${PDIR}/manifest.csv" "${DEST}/manifest.csv" --no-progress >/dev/null || true
        fi
        echo "uploaded"
        UPLOADED=$(( UPLOADED + 1 ))
    else
        echo "UPLOAD FAILED"
    fi
done

echo "------------------------------------------"
echo "Uploaded: $UPLOADED   Skipped (no pkl): $SKIPPED"
echo "=========================================="
