#!/bin/bash
# Upload pre-built true-ligand pocket inputs to S3 so FSx imports them.
#
# Unlike stage-drugclip-pockets.sh this does NOT run an adapter -- recover_template_ligands.py
# has already written <UNIPROT>/pockets/*_LIG.pdb + manifest.csv.  This only validates and
# uploads, into a NEW S3/FSx prefix so /fsx/input/targets is untouched.
#
#   <ligand_dir>/<ID>/pockets/*_LIG.pdb   ->  s3://<bucket>/input/<DEST_PREFIX>/<ID>/pockets/
#                                         ->  /fsx/input/<DEST_PREFIX>/<ID>/pockets/   (auto-import)
#
# Usage:
#   stage-ligand-pockets.sh <ligand_dir> [--dest-prefix targets_ligand] [--dry-run]
#                           [--only ID1,ID2,...]
#
# Example:
#   stage-ligand-pockets.sh /home/marina/Documents/AI2050/Targets/targets_ligand

set -euo pipefail

LIGAND_DIR=${1:-}
DEST_PREFIX=targets_ligand
DRY_RUN=0
ONLY=
S3_BUCKET=${S3_BUCKET:-ai2050-ersilia-cluster}

shift $(( $# >= 1 ? 1 : $# ))
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)     DRY_RUN=1 ;;
        --dest-prefix) DEST_PREFIX=$2; shift ;;
        --only)        ONLY=$2; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

if [ -z "$LIGAND_DIR" ]; then
    echo "Usage: $0 <ligand_dir> [--dest-prefix targets_ligand] [--dry-run] [--only IDs]"
    echo ""
    echo "  ligand_dir     - output of recover_template_ligands.py (<ID>/pockets/*_LIG.pdb)"
    echo "  --dest-prefix  - S3/FSx top folder (default targets_ligand; NEVER 'targets')"
    echo "  --only         - restrict to these UniProt IDs (comma-separated)"
    exit 1
fi

if [ ! -d "$LIGAND_DIR" ]; then
    echo "ERROR: ligand_dir not found: $LIGAND_DIR"
    exit 1
fi

# Guard: never overwrite the production pocket set.
if [ "$DEST_PREFIX" = "targets" ]; then
    echo "ERROR: --dest-prefix 'targets' is the production set and must not be overwritten."
    exit 1
fi

S3_DEST="s3://${S3_BUCKET}/input/${DEST_PREFIX}/"

echo "=========================================="
echo "Stage true-ligand pockets"
echo "=========================================="
echo "Ligand dir : $LIGAND_DIR"
echo "S3 dest    : ${S3_DEST}<ID>/pockets/"
echo "FSx path   : /fsx/input/${DEST_PREFIX}/<ID>/pockets/"
echo "Only       : ${ONLY:-<all>}"
echo "Dry run    : $DRY_RUN"
echo "=========================================="

N_TARGETS=0; N_PDBS=0; N_BAD=0
for d in "$LIGAND_DIR"/*/; do
    [ -d "$d" ] || continue
    TARGET=$(basename "$d")
    PDIR="${d}pockets"
    [ -d "$PDIR" ] || continue
    if [ -n "$ONLY" ] && ! echo ",$ONLY," | grep -q ",$TARGET,"; then
        continue
    fi

    COUNT=$(ls "$PDIR"/*_LIG.pdb 2>/dev/null | wc -l)
    if [ ! -f "$PDIR/manifest.csv" ]; then
        echo "  WARN $TARGET: no manifest.csv - skipping"
        N_BAD=$(( N_BAD + 1 )); continue
    fi
    # manifest rows must match the PDBs on disk, or the pocket_key join silently loses rows.
    ROWS=$(( $(wc -l < "$PDIR/manifest.csv") - 1 ))
    if [ "$COUNT" -ne "$ROWS" ]; then
        echo "  WARN $TARGET: $COUNT pdb but $ROWS manifest rows - skipping"
        N_BAD=$(( N_BAD + 1 )); continue
    fi
    echo "  $TARGET: $COUNT conformation PDBs"
    N_TARGETS=$(( N_TARGETS + 1 )); N_PDBS=$(( N_PDBS + COUNT ))
done

echo "------------------------------------------"
echo "Ready: $N_TARGETS target(s), $N_PDBS conformation PDBs"
[ "$N_BAD" -gt 0 ] && echo "Skipped: $N_BAD target(s) failing validation"

if [ "$N_TARGETS" -eq 0 ]; then
    echo "ERROR: nothing to upload"
    exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would sync: aws s3 sync \"$LIGAND_DIR/\" \"$S3_DEST\""
    exit 0
fi

echo ""
echo "Uploading to $S3_DEST ..."
# --delete is REQUIRED, not tidiness. Without it, a conformation dropped locally (e.g. one
# rejected for having no protein contact) survives in S3, syncs back to FSx, and leaves the
# pocket dir with more PDBs than manifest rows -- which the encode's completeness guard then
# refuses, correctly but confusingly.
#
# Scoped to the *_LIG.pdb / manifest.csv pattern, so --delete can only ever remove files this
# script is responsible for. When --only is set, each target is deleted within its own prefix
# so a filtered run cannot touch targets it was not asked about.
SYNC_FILTER=(--exclude '*' --include '*/pockets/*_LIG.pdb' --include '*/pockets/manifest.csv')
if [ -n "$ONLY" ]; then
    IFS=',' read -ra _ONLY <<< "$ONLY"
    for T in "${_ONLY[@]}"; do
        [ -d "${LIGAND_DIR}/${T}" ] || continue
        echo "  $T ..."
        aws s3 sync "${LIGAND_DIR}/${T}/" "${S3_DEST}${T}/" \
            --exclude '*' --include 'pockets/*_LIG.pdb' --include 'pockets/manifest.csv' \
            --delete --no-progress
    done
else
    aws s3 sync "$LIGAND_DIR/" "$S3_DEST" "${SYNC_FILTER[@]}" --delete --no-progress
fi

echo ""
echo "Done. Files auto-import to /fsx/input/${DEST_PREFIX}/<ID>/pockets/ on first access."
echo "Next, on the head node:"
echo "  POCKET_BASE=/fsx/input/${DEST_PREFIX} \\"
echo "    bash submit-pocket-encode.sh --max-pocket-atoms 511"
echo "=========================================="
