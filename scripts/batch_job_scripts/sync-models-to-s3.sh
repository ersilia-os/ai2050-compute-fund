#!/bin/bash
# Sync FSx output to S3 for specified model IDs (all libraries), then optionally clean up.
#
# For each model ID, finds every matching /fsx/output/<library>/<model_id>/ directory
# and syncs it to s3://ai2050-ersilia-cluster/output/<library>/<model_id>/.
# Verifies file counts before any deletion.
#
# Usage:
#   bash /shared/scripts/sync-models-to-s3.sh [--cleanup] <model_id1> [model_id2 ...]
#
# Options:
#   --cleanup   After a verified sync, delete the model directory from FSx.
#               Without this flag the script only syncs (no deletion).
#
# Examples:
#   bash /shared/scripts/sync-models-to-s3.sh eos7d58_v1 eos1af5_v1
#   bash /shared/scripts/sync-models-to-s3.sh --cleanup eos7d58_v1 eos1af5_v1

S3_BUCKET="s3://ai2050-ersilia-cluster"
FSX_OUTPUT="/fsx/output"

CLEANUP=false
MODELS=()

for arg in "$@"; do
    if [ "$arg" = "--cleanup" ]; then
        CLEANUP=true
    else
        MODELS+=("$arg")
    fi
done

if [ ${#MODELS[@]} -eq 0 ]; then
    echo "Usage: $0 [--cleanup] <model_id1> [model_id2 ...]"
    echo ""
    echo "Examples:"
    echo "  $0 eos7d58_v1 eos1af5_v1"
    echo "  $0 --cleanup eos7d58_v1 eos1af5_v1"
    exit 1
fi

if [ ! -d "$FSX_OUTPUT" ]; then
    echo "ERROR: FSx output dir not found: $FSX_OUTPUT"
    exit 1
fi

echo "=========================================="
echo "Ersilia batch output FSx → S3 sync"
echo "=========================================="
echo "Date     : $(date)"
echo "Cleanup  : $CLEANUP"
echo "Models   : ${MODELS[*]}"
echo "=========================================="
echo ""

OVERALL_OK=true

for MODEL_ID in "${MODELS[@]}"; do
    echo "=========================================="
    echo "Model: $MODEL_ID"
    echo "=========================================="

    # Find all library directories that contain this model's output
    MODEL_DIRS=( $(find "$FSX_OUTPUT" -mindepth 2 -maxdepth 2 -type d -name "$MODEL_ID" 2>/dev/null | sort) )

    if [ ${#MODEL_DIRS[@]} -eq 0 ]; then
        echo "  SKIP: no directories found matching $FSX_OUTPUT/*/$MODEL_ID"
        echo ""
        continue
    fi

    for LOCAL_DIR in "${MODEL_DIRS[@]}"; do
        # Derive library name from path: /fsx/output/<library>/<model_id>
        LIBRARY=$(basename "$(dirname "$LOCAL_DIR")")
        S3_PATH="${S3_BUCKET}/output/${LIBRARY}/${MODEL_ID}"

        echo "  Library : $LIBRARY"
        echo "  Local   : $LOCAL_DIR"
        echo "  S3      : $S3_PATH"

        LOCAL_COUNT=$(find "$LOCAL_DIR" -maxdepth 1 -name "*.csv" | wc -l)

        if [ "$LOCAL_COUNT" -eq 0 ]; then
            echo "  SKIP: no .csv files found"
            echo ""
            continue
        fi

        echo "  Local CSV files: $LOCAL_COUNT"

        # ── Sync to S3 ────────────────────────────────────────────────────────
        aws s3 sync "$LOCAL_DIR" "$S3_PATH" \
            --exclude "*" \
            --include "*.csv" \
            --no-delete \
            --no-progress

        SYNC_EXIT=$?

        if [ $SYNC_EXIT -ne 0 ]; then
            echo "  ERROR: aws s3 sync failed (exit $SYNC_EXIT)"
            OVERALL_OK=false
            echo ""
            continue
        fi

        # ── Verify: count .csv objects now in S3 ─────────────────────────────
        S3_COUNT=$(aws s3 ls "${S3_PATH}/" \
            | awk '{print $4}' \
            | grep '\.csv$' \
            | wc -l)

        echo "  S3 CSV files   : $S3_COUNT"

        if [ "$S3_COUNT" -lt "$LOCAL_COUNT" ]; then
            echo "  ERROR: S3 count ($S3_COUNT) < local count ($LOCAL_COUNT) — skipping cleanup"
            OVERALL_OK=false
            echo ""
            continue
        fi

        echo "  Sync verified OK"

        # ── Optional cleanup ──────────────────────────────────────────────────
        if [ "$CLEANUP" = true ]; then
            echo "  Removing $LOCAL_DIR from FSx ..."
            rm -rf "$LOCAL_DIR"
            if [ $? -eq 0 ]; then
                echo "  Cleanup done"
            else
                echo "  ERROR: cleanup failed"
                OVERALL_OK=false
            fi
        fi

        echo ""
    done
done

echo "=========================================="
if [ "$OVERALL_OK" = true ]; then
    echo "Done. All specified models synced successfully."
else
    echo "WARNING: one or more libraries had errors — review output above."
    exit 1
fi
echo "=========================================="
