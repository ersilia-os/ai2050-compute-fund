#!/bin/bash
# =============================================================================
# Build the Enamine_Real_h3d_selected input library (50k-row chunks).
# =============================================================================
# Input : ONE gzip file with two columns, `key` and `input`, as produced by the
#         selection step over the standardized 1.4B library.
#           key   -> 32-char hex molecule key   -> becomes collection_id
#           input -> standardized SMILES        -> becomes the chunk smiles
#
# Output (same layout/format as every other library in this pipeline):
#   <out>/Enamine_Real_h3d_selected/
#   ├── Enamine_Real_h3d_selected_chunk_000000.csv          # 'smiles' only, 50k rows
#   ├── ...                                                  # ~2,000 files for 100M
#   ├── smiles_ids/
#   │   └── Enamine_Real_h3d_selected_smiles_ids_000000.csv.gz   # smiles,collection_id
#   └── _manifest.json
#
# This is step 01 ONLY. The molecules are already standardized and deduplicated,
# so steps 1.5 (standardize) / 2a (tag) / 2b (dedup) are NOT rerun — the id map is
# written directly here, row-aligned with each chunk. Downstream models run straight
# off this library via the wave orchestrator.
#
# Usage:
#   prepare-h3d-selected-library.sh <selected.csv.gz> [output-dir]
#
#   LIMIT=200000  ./prepare-h3d-selected-library.sh file.gz ./smoke   # smoke test
#   NO_UPLOAD=1   ./prepare-h3d-selected-library.sh file.gz           # local only
#
# Env overrides: LIB, CHUNK_SIZE, S3_BUCKET, SMILES_COL, ID_COL, DELIM, LIMIT,
#                NO_UPLOAD, PYTHON
# Re-running the same command RESUMES from the last committed chunk.
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT=${1:-}
OUTDIR=${2:-./output}

LIB=${LIB:-Enamine_Real_h3d_selected}
CHUNK_SIZE=${CHUNK_SIZE:-50000}
BUCKET=${S3_BUCKET:-ai2050-ersilia-cluster}
SMILES_COL=${SMILES_COL:-input}
ID_COL=${ID_COL:-key}
LIMIT=${LIMIT:-0}
PYTHON=${PYTHON:-python3}

if [ -z "$INPUT" ]; then
    echo "Usage: $0 <selected.csv.gz> [output-dir]"
    exit 1
fi
if [ ! -f "$INPUT" ]; then
    echo "ERROR: input file not found: $INPUT"
    exit 1
fi

# --- Sniff the header so a schema surprise fails here, not 3 hours in ----------
# (safe on a still-downloading file: we only read the first line)
HEADER=$(gzip -cd -- "$INPUT" 2>/dev/null | head -1 | tr -d '\r')
if [ -z "$HEADER" ]; then
    echo "ERROR: could not read a header line from $INPUT (not gzip? empty?)."
    exit 1
fi

if [ -n "${DELIM:-}" ]; then
    :
elif [[ "$HEADER" == *","* ]]; then
    DELIM=","
elif [[ "$HEADER" == *$'\t'* ]]; then
    DELIM='\t'
else
    echo "ERROR: header has neither a comma nor a tab: '$HEADER'"
    echo "       Set DELIM= explicitly if the file uses something else."
    exit 1
fi

echo "=========================================="
echo "Ingest selected library: $LIB"
echo "  Input       : $INPUT"
echo "  Header      : $HEADER"
echo "  Columns     : smiles='$SMILES_COL'  id='$ID_COL'  delim='$DELIM'"
echo "  Chunk size  : $CHUNK_SIZE"
echo "  Output dir  : $OUTDIR/$LIB"
[ "$LIMIT" != "0" ] && echo "  LIMIT       : first $LIMIT molecules (smoke test)"
[ -n "${NO_UPLOAD:-}" ] && echo "  Upload      : DISABLED (local only)"
echo "=========================================="

# Warn (don't block) if the expected column names are missing — the Python step
# resolves them case-insensitively and errors out with the real header anyway.
for col in "$SMILES_COL" "$ID_COL"; do
    if [[ ",${HEADER,,}," != *",${col,,},"* && $'\t'"${HEADER,,}"$'\t' != *$'\t'"${col,,}"$'\t'* ]]; then
        echo "WARNING: column '$col' not obviously present in the header above."
    fi
done

# Partial-download guard: gzip streams truncate mid-file. A short run is fine for a
# smoke test, but a full run on an incomplete download would silently stop early.
if [ "$LIMIT" = "0" ] && [ -z "${SKIP_INTEGRITY_CHECK:-}" ]; then
    echo "Verifying gzip integrity (full pass — skip with SKIP_INTEGRITY_CHECK=1) ..."
    if ! gzip -t -- "$INPUT"; then
        echo "ERROR: gzip integrity check failed — the download is probably still running."
        echo "       Wait for it to finish, or smoke-test now with LIMIT=200000."
        exit 1
    fi
    echo "  gzip OK — file is complete."
fi

ARGS=(
    "$HERE/01_large_library_processing.py"
    --input "$INPUT"
    --output-dir "$OUTDIR"
    --library-name "$LIB"
    --chunk-size "$CHUNK_SIZE"
    --smiles-col "$SMILES_COL"
    --id-col "$ID_COL"
    --delimiter "$DELIM"
)
[ "$LIMIT" != "0" ] && ARGS+=(--limit "$LIMIT")
if [ -z "${NO_UPLOAD:-}" ] && [ "$LIMIT" = "0" ]; then
    ARGS+=(
        --upload-s3       "s3://$BUCKET/input/$LIB/"
        --upload-idmap-s3 "s3://$BUCKET/smiles_ids/$LIB/"
    )
fi

"$PYTHON" "${ARGS[@]}"
rc=$?
[ $rc -ne 0 ] && exit $rc

cat <<EOF

------------------------------------------
Next steps
  1. Sanity-check locally:
       ls $OUTDIR/$LIB/${LIB}_chunk_*.csv | wc -l     # ~2,000 for 100M @ 50k
       head -3 $OUTDIR/$LIB/${LIB}_chunk_000000.csv   # header must be exactly: smiles
       cat  $OUTDIR/$LIB/_manifest.json
  2. Confirm S3 (FSx auto-imports input/ on NEW_CHANGED):
       aws s3 ls s3://$BUCKET/input/$LIB/       | grep -c '_chunk_.*\.csv'
       aws s3 ls s3://$BUCKET/smiles_ids/$LIB/  | grep -c '_smiles_ids_.*\.csv\.gz'
  3. Run a model on the cluster, in tmux on the head node:
       S3_BUCKET=$BUCKET /shared/scripts/large_library_scripts/submit-ersilia-waves.sh \\
         <model_id> $LIB <wave_size> cpu-queue
     Size the wave to the model's output width (see README): ~1000 for light output,
     ~30-40 for fingerprints/embeddings.
------------------------------------------
EOF
