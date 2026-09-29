#!/bin/bash
# =============================================================================
# Promote the deduped/standardized chunks to be the canonical input library.
# =============================================================================
# End state:
#   s3://<bucket>/input/raw/<LIB>/   <- the ORIGINAL raw chunks (archived backup)
#   s3://<bucket>/input/<LIB>/       <- the NEW standardized+deduped chunks
#                                       (100k rows, single 'smiles' column)
#
# Prerequisite: run dedup_and_map.py FIRST with
#   --dedup-library-name <LIB>   (so local chunks are named <LIB>_chunk_NNNNNN.csv)
#   (and WITHOUT --upload-chunks-s3, so nothing is uploaded before the raw archive)
#
# What it does:
#   0. Validate the local deduped chunks (single 'smiles' column).
#   1. Archive raw:   s3 input/<LIB>/  ->  s3 input/raw/<LIB>/   (aws s3 mv)
#   2. Upload deduped: local <src-dir> ->  s3 input/<LIB>/        (aws s3 sync)
#   3. Verify counts.
#
# Runs locally (where dedup_and_map.py wrote the chunks). aws does the S3 work.
#
# Usage:
#   promote-standardized-library.sh <library> <src-dir> [--dry-run]
#     <src-dir>  local dir with <library>_chunk_*.csv  (dedup_and_map dedup_chunks/)
#   S3_BUCKET env overrides the bucket (default ai2050-ersilia-cluster).
# =============================================================================

set -uo pipefail

LIB=${1:-}
SRC=${2:-}
DRY=${3:-}
BUCKET=${S3_BUCKET:-ai2050-ersilia-cluster}

if [ -z "$LIB" ] || [ -z "$SRC" ]; then
    echo "Usage: $0 <library> <src-dir> [--dry-run]"
    echo "Example: $0 Enamine_Real_Sample_1.4B ./dedup_work/dedup_chunks"
    exit 1
fi

INPUT_PREFIX="s3://$BUCKET/input/$LIB/"
RAW_PREFIX="s3://$BUCKET/input/raw/$LIB/"

run() {  # echo in dry-run, execute otherwise
    if [ "$DRY" = "--dry-run" ]; then echo "  [dry-run] $*"; else "$@"; fi
}

echo "=========================================="
echo "Promote standardized library: $LIB"
echo "  Source (local) : $SRC"
echo "  Archive raw -> : $RAW_PREFIX"
echo "  New library -> : $INPUT_PREFIX"
[ "$DRY" = "--dry-run" ] && echo "  DRY RUN"
echo "=========================================="

# --- 0. Validate local deduped chunks ---
shopt -s nullglob
files=("$SRC"/${LIB}_chunk_*.csv)
if [ ${#files[@]} -eq 0 ]; then
    echo "ERROR: no ${LIB}_chunk_*.csv found in $SRC"
    echo "       Did dedup_and_map.py run with --dedup-library-name $LIB ?"
    exit 1
fi
hdr=$(head -1 "${files[0]}" | tr -d '\r')
if [ "$hdr" != "smiles" ]; then
    echo "ERROR: first chunk header is '$hdr', expected 'smiles' — wrong format, aborting."
    exit 1
fi
echo "Local deduped chunks : ${#files[@]}  (header OK: 'smiles')"

# --- 1. Guard: never clobber an existing archive ---
if [ -n "$(aws s3 ls "$RAW_PREFIX" 2>/dev/null | head -1)" ]; then
    echo "ERROR: an archive already exists at $RAW_PREFIX"
    echo "       Refusing to overwrite the backup. Inspect/rename it first."
    exit 1
fi

RAW_N=$(aws s3 ls "$INPUT_PREFIX" 2>/dev/null | grep -c '_chunk_.*\.csv') || RAW_N=0
echo "Raw chunks in $INPUT_PREFIX : $RAW_N"
if [ "$RAW_N" -eq 0 ]; then
    echo "WARNING: no raw chunks found to archive at $INPUT_PREFIX (already swapped?)."
fi

# --- 2. Archive raw -> input/raw/<LIB>/  (move, so input/<LIB>/ is emptied) ---
echo "Archiving raw library ..."
run aws s3 mv "$INPUT_PREFIX" "$RAW_PREFIX" --recursive --exclude "*" --include "*_chunk_*.csv"

# --- 3. Upload deduped chunks -> input/<LIB>/ ---
echo "Uploading deduped chunks ..."
run aws s3 sync "$SRC/" "$INPUT_PREFIX" --exclude "*" --include "${LIB}_chunk_*.csv"

# --- 4. Verify ---
if [ "$DRY" != "--dry-run" ]; then
    NEW_N=$(aws s3 ls "$INPUT_PREFIX" 2>/dev/null | grep -c '_chunk_.*\.csv')
    ARCH_N=$(aws s3 ls "$RAW_PREFIX" 2>/dev/null | grep -c '_chunk_.*\.csv')
    echo "------------------------------------------"
    echo "  New standardized chunks in input/$LIB/     : $NEW_N  (expected ${#files[@]})"
    echo "  Archived raw chunks in input/raw/$LIB/     : $ARCH_N  (expected $RAW_N)"
    if [ "$NEW_N" -ne "${#files[@]}" ]; then
        echo "  WARNING: uploaded count != local count — re-run to finish the sync."
    fi
    echo "------------------------------------------"
fi

cat <<EOF

Done. Notes:
 * The final SMILES->ID map (dedup_and_map.py output) is separate — upload it for
   safekeeping if you haven't, e.g.:
     aws s3 cp <lib>_smiles_ids_dedup.csv.gz s3://$BUCKET/smiles_ids/${LIB}_dedup/
 * FSx auto-import is NEW_CHANGED (no deletes). On the HEAD NODE, clear stale raw
   copies so /fsx matches S3 (they lazily re-import the deduped set from S3):
     rm -rf /fsx/input/$LIB/*
   The wave orchestrator is safe regardless (it builds its manifest from S3).
EOF
