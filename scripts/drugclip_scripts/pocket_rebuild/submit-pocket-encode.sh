#!/bin/bash
# Submit a DrugCLIP pocket-encoding job for every target under a pocket base dir.
#
# Self-contained replacement for submit-all-drugclip-pockets.sh + submit-drugclip-pocket.sh,
# so nothing under scripts/drugclip_scripts/ is modified and the production pocket set at
# /fsx/input/targets stays exactly reproducible.
#
# Two additions over the originals:
#   --max-pocket-atoms N   passed through to run-pocket-encode.sh (default 511, upstream's
#                          value; the production set used 256)
#   --clone-from DIR       copy DIR/<ID>/pockets/*.pdb + manifest.csv into POCKET_BASE first,
#                          WITHOUT pocket.lmdb / pocket_reps.pkl, so the re-encode writes
#                          fresh outputs and never touches the source set
#
# Phase 0 (the 256 -> 511 control) is then a one-liner:
#   POCKET_BASE=/fsx/input/targets_a511 \
#     bash submit-pocket-encode.sh --clone-from /fsx/input/targets --max-pocket-atoms 511
#
# Phase 4 (the true-ligand rebuild):
#   POCKET_BASE=/fsx/input/targets_ligand \
#     bash submit-pocket-encode.sh --max-pocket-atoms 511
#
# Usage:
#   [POCKET_BASE=...] submit-pocket-encode.sh [--force] [--max-pocket-atoms N]
#                                             [--clone-from DIR] [--max-pending N] [--dry-run]

set -uo pipefail

FORCE=0
MAX_PENDING=20
MAX_POCKET_ATOMS=511
QUEUE=gpu-queue
EXCLUSIVE=0
CLONE_FROM=
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --force)            FORCE=1 ;;
        --dry-run)          DRY_RUN=1 ;;
        --max-pocket-atoms) MAX_POCKET_ATOMS=$2; shift ;;
        --clone-from)       CLONE_FROM=$2; shift ;;
        --max-pending)      MAX_PENDING=$2; shift ;;
        --queue)            QUEUE=$2; shift ;;
        --exclusive)        EXCLUSIVE=1 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

POCKET_BASE="${POCKET_BASE:-/fsx/input/targets_ligand}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/run-pocket-encode.sh"
PATCHED_TASK="${SCRIPT_DIR}/patched/drugclip.py"

if [ ! -f "$RUNNER" ]; then
    echo "ERROR: run-pocket-encode.sh not found next to this script ($RUNNER)"
    exit 1
fi

# Refuse to write into the production set, whatever the flags say.
case "$POCKET_BASE" in
    /fsx/input/targets|/fsx/input/targets/)
        echo "ERROR: POCKET_BASE is the production set (/fsx/input/targets)."
        echo "       This script never writes there. Use a new base, e.g. /fsx/input/targets_a511."
        exit 1 ;;
esac

echo "=========================================="
echo "Submit pocket-encoding jobs"
echo "=========================================="
echo "Pocket base      : $POCKET_BASE"
echo "max-pocket-atoms : $MAX_POCKET_ATOMS"
echo "Clone from       : ${CLONE_FROM:-<none>}"
echo "Force resubmit   : $FORCE"
echo "Max pending      : $MAX_PENDING"
echo "Queue            : $QUEUE${ALLOW_CPU:+   (ALLOW_CPU=$ALLOW_CPU)}"
echo "Exclusive node   : $EXCLUSIVE"
echo "Pocket batch     : ${POCKET_BATCH_SIZE:-32 (sif default)}"
if [ -n "${POCKET_BATCH_SIZE:-}" ] && [ ! -f "$PATCHED_TASK" ]; then
    echo ""
    echo "ERROR: POCKET_BATCH_SIZE is set but the patched task file is missing:"
    echo "         $PATCHED_TASK"
    echo "       Run once on the head node:  bash ${SCRIPT_DIR}/patch-pocket-batch.sh"
    exit 1
fi
echo "Dry run          : $DRY_RUN"
echo "=========================================="

# -- Optional clone -----------------------------------------------------------
if [ -n "$CLONE_FROM" ]; then
    if [ ! -d "$CLONE_FROM" ]; then
        echo "ERROR: --clone-from dir not found: $CLONE_FROM"
        exit 1
    fi
    echo ""
    echo "Cloning pocket inputs $CLONE_FROM -> $POCKET_BASE (pdb + manifest only) ..."
    N_CLONED=0
    for SRC in "$CLONE_FROM"/*/pockets; do
        [ -d "$SRC" ] || continue
        ID=$(basename "$(dirname "$SRC")")
        DST="${POCKET_BASE}/${ID}/pockets"
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "  [dry-run] $ID: $(ls "$SRC"/*.pdb 2>/dev/null | wc -l) pdb -> $DST"
        else
            mkdir -p "$DST"
            # Deliberately NOT --delete, and deliberately excluding the encode outputs.
            rsync -a --include='*.pdb' --include='manifest.csv' --exclude='*' \
                  "$SRC"/ "$DST"/
        fi
        N_CLONED=$(( N_CLONED + 1 ))
    done
    echo "  cloned $N_CLONED target(s)"
fi

# In --dry-run the clone above copied nothing, so POCKET_BASE may not exist yet. Enumerate
# from the clone source instead, so a dry run still reports what would be submitted.
LIST_BASE="$POCKET_BASE"
if [ ! -d "$POCKET_BASE" ]; then
    if [ "$DRY_RUN" -eq 1 ] && [ -n "$CLONE_FROM" ]; then
        echo ""
        echo "[dry-run] $POCKET_BASE does not exist yet - listing from the clone source."
        LIST_BASE="$CLONE_FROM"
    else
        echo "ERROR: $POCKET_BASE not found - stage or clone the pockets first"
        exit 1
    fi
fi

POCKET_DIRS=($(ls -d "$LIST_BASE"/*/pockets 2>/dev/null | sort || true))
if [ ${#POCKET_DIRS[@]} -eq 0 ]; then
    echo "ERROR: no <ID>/pockets dirs under $LIST_BASE"
    exit 1
fi
echo ""
echo "Targets: ${#POCKET_DIRS[@]}"

[ "$DRY_RUN" -eq 1 ] || mkdir -p /shared/logs

SUBMITTED=0; SKIPPED=0; FAILED=0; INCOMPLETE=0

for LDIR in "${POCKET_DIRS[@]}"; do
    TARGET=$(basename "$(dirname "$LDIR")")
    # Always encode into the DESTINATION, even when we enumerated from the clone source --
    # otherwise a dry run would test the source's pocket_reps.pkl and "skip" every target.
    PDIR="${POCKET_BASE}/${TARGET}/pockets"

    if [ "$FORCE" -eq 0 ] && [ -f "${PDIR}/pocket_reps.pkl" ]; then
        echo "  SKIP  $TARGET (pocket_reps.pkl already exists)"
        SKIPPED=$(( SKIPPED + 1 ))
        continue
    fi

    N_PDBS=$(ls "${LDIR}"/*.pdb 2>/dev/null | wc -l)
    if [ "$N_PDBS" -eq 0 ]; then
        echo "  SKIP  $TARGET (no .pdb files)"
        SKIPPED=$(( SKIPPED + 1 ))
        continue
    fi

    # Guard against a PARTIAL FSx import. FSx pulls S3 objects lazily, so a submit fired
    # moments after staging can see only some of a target's conformations. The manifest is
    # the source of truth for how many there should be. Encoding a partially-imported dir
    # writes a truncated pocket_reps.pkl, and because this script (and run-pocket-encode.sh)
    # skip any target that already has a pkl, that truncation would then be permanent and
    # silent -- the same failure that voided the molecule embeddings.
    MAN="${LDIR}/manifest.csv"
    if [ ! -f "$MAN" ]; then
        echo "  SKIP  $TARGET (no manifest.csv - cannot verify completeness)"
        INCOMPLETE=$(( INCOMPLETE + 1 ))
        continue
    fi
    N_ROWS=$(( $(wc -l < "$MAN") - 1 ))
    if [ "$N_PDBS" -ne "$N_ROWS" ]; then
        echo "  SKIP  $TARGET (INCOMPLETE: $N_PDBS pdb but $N_ROWS manifest rows)"
        INCOMPLETE=$(( INCOMPLETE + 1 ))
        continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [dry-run] would submit $TARGET ($N_PDBS pdb, max-pocket-atoms $MAX_POCKET_ATOMS)"
        SUBMITTED=$(( SUBMITTED + 1 ))
        continue
    fi

    # FSx S3 auto-import can land dirs owned by root; encode writes into the pocket dir.
    sudo chown ec2-user:ec2-user "$PDIR" 2>/dev/null || true

    # Throttle so we never flood gpu-queue.
    if [ "$(squeue -u "$USER" -h | wc -l)" -ge "$MAX_PENDING" ]; then
        echo "  Queue at limit ($MAX_PENDING) - waiting..."
        while [ "$(squeue -u "$USER" -h | wc -l)" -ge "$MAX_PENDING" ]; do
            sleep 30
        done
    fi

    echo -n "  Submitting $TARGET ($N_PDBS pdb) ... "
    # One encoder per node. A g6.4xlarge has a single GPU, so co-scheduled jobs share it
    # and the largest pockets OOM first -- the same packing failure that truncated the
    # molecule chunks in September. Cheap insurance: these jobs take minutes.
    EXCL_FLAG=""
    [ "$EXCLUSIVE" -eq 1 ] && EXCL_FLAG="--exclusive"
    JOB_ID=$(sbatch --partition="$QUEUE" $EXCL_FLAG \
                    --export=ALL${ALLOW_CPU:+,ALLOW_CPU=$ALLOW_CPU}${POCKET_BATCH_SIZE:+,POCKET_BATCH_SIZE=$POCKET_BATCH_SIZE,PATCHED_TASK=$PATCHED_TASK} \
                    --job-name="pocket-encode-${TARGET}" \
                    "$RUNNER" "$TARGET" "$PDIR" "$MAX_POCKET_ATOMS" \
             2>&1 | grep -oP 'Submitted batch job \K\d+')
    if [ -n "$JOB_ID" ]; then
        echo "job $JOB_ID"
        SUBMITTED=$(( SUBMITTED + 1 ))
    else
        echo "ERROR"
        FAILED=$(( FAILED + 1 ))
    fi
done

echo ""
echo "=========================================="
echo "Submitted: $SUBMITTED   Skipped: $SKIPPED   Failed: $FAILED   Incomplete: $INCOMPLETE"
if [ "$INCOMPLETE" -gt 0 ]; then
    echo ""
    echo "WARNING: $INCOMPLETE target(s) had fewer PDBs than manifest rows and were NOT"
    echo "         submitted. FSx imports from S3 lazily, so this usually means the"
    echo "         import is still catching up. Re-run this script once these match:"
    echo "           find $POCKET_BASE -name '*_LIG.pdb' | wc -l"
fi
echo "Monitor:   watch -n 10 'squeue -u \$USER'"
echo "Then:      TARGETS_BASE=$POCKET_BASE VAL_TAG=<tag> \\"
echo "             bash /shared/scripts/drugclip_scripts/validation/run-validation.sh enrich cpu-queue"
echo "=========================================="
[ "$FAILED" -eq 0 ] && [ "$INCOMPLETE" -eq 0 ]
