#!/bin/bash
# Auto-detect the MISSING output chunks for a model across all libraries, launch
# a binary-search (bisect) job for each, and automatically merge the results
# once every (recursively-spawned) bisect job has finished.
#
# A chunk is considered "missing" if its result file
#   /fsx/output/<library>/<model_id>/<model_id>_results_<chunk>.csv
# does not exist. (Libraries with no output at all are skipped — those never ran
# and belong in the normal batch pipeline, not bisect.)
#
# ── Modes ────────────────────────────────────────────────────────────────────
#   submit-ersilia-missing-bisect.sh <model_id> [queue]
#       Scan all libraries, bisect every missing chunk, and submit a
#       fire-and-forget merge-watcher job (survives logout).
#
#   submit-ersilia-missing-bisect.sh --merge-watch <model_id> <manifest> <queue> <iter>
#       INTERNAL — the Slurm watcher job. Waits for all bisect_<model>_* jobs to
#       drain (requeueing itself between checks so it doesn't hog a node), then
#       merges each chunk listed in <manifest>. Not meant to be run by hand.
#
# ── Tunables (env) ───────────────────────────────────────────────────────────
#   WATCH_INTERVAL   minutes between watcher checks           (default 5)
#   WATCH_MAX_ITERS  max watcher requeues before giving up    (default 1000)
#
# NOTE: this script re-submits itself as the watcher, so it must live on a
# shared path visible to the compute nodes (e.g. /shared/scripts).

set -uo pipefail

# ── Sibling scripts (fixed shared path) ──────────────────────────────────────
# Do NOT derive this from $BASH_SOURCE: sbatch runs a COPY of the script from
# its spool dir (/var/spool/slurmd/job*/slurm_script), so dirname would point
# there and the siblings would not be found when the watcher runs as a job.
SCRIPTS_DIR="${ERSILIA_SCRIPTS_DIR:-/shared/scripts}"
SELF="${SCRIPTS_DIR}/submit-ersilia-missing-bisect.sh"
BISECT_SCRIPT="${SCRIPTS_DIR}/bisect-ersilia-chunk.sh"
MERGE_SCRIPT="${SCRIPTS_DIR}/merge-bisect-results.sh"

# Memory for the watcher job — it runs merge-bisect-results.sh inline, which is
# RAM-hungry for high-column descriptor models. Override with WATCH_MEM=64G etc.
WATCH_MEM="${WATCH_MEM:-32G}"

LIBRARIES=(
    "Enamine_Hit_Locator_460K"
    "Coconut_715K"
    "Enamine_Liquid_Stock_2.5M"
    "Molport_Screening_Compounds_5.3M"
    "Enamine_Real_Sample_10.4M"
)

ME="${USER:-$(whoami)}"

# Print bisect job names currently in the queue (padded so long names are never
# truncated; awk strips the padding back to the bare name).
squeue_names() {
    squeue -u "$ME" -h -o "%200j" 2>/dev/null | awk '{print $1}'
}

# =============================================================================
#  WATCHER MODE
# =============================================================================
if [ "${1:-}" = "--merge-watch" ]; then
    shift
    MODEL_ID=${1:-}
    MANIFEST=${2:-}
    QUEUE=${3:-cpu-queue}
    ITER=${4:-0}
    WATCH_INTERVAL=${WATCH_INTERVAL:-5}
    WATCH_MAX_ITERS=${WATCH_MAX_ITERS:-1000}

    echo "[watch] model=$MODEL_ID iter=$ITER manifest=$MANIFEST  $(date)"

    if [ -z "$MODEL_ID" ] || [ ! -f "$MANIFEST" ]; then
        echo "[watch] ERROR: bad model id or manifest not found — aborting"
        exit 1
    fi

    REMAINING=$(squeue_names | grep -cE "^bisect_${MODEL_ID}_" || true)
    echo "[watch] bisect jobs still in queue for this model: ${REMAINING}"

    # Jobs still running → requeue self a bit later and stop occupying the node.
    if [ "${REMAINING:-0}" -gt 0 ] && [ "$ITER" -lt "$WATCH_MAX_ITERS" ]; then
        echo "[watch] not done yet — requeueing in ${WATCH_INTERVAL} min"
        sbatch --parsable \
            --partition="$QUEUE" \
            --job-name="bmerge_${MODEL_ID}" \
            --cpus-per-task=1 \
            --mem="$WATCH_MEM" \
            --time=02:00:00 \
            --begin="now+${WATCH_INTERVAL}minutes" \
            --output="/shared/logs/bmerge-%j.out" \
            --error="/shared/logs/bmerge-%j.err" \
            "$SELF" --merge-watch "$MODEL_ID" "$MANIFEST" "$QUEUE" $((ITER + 1))
        exit 0
    fi

    if [ "$ITER" -ge "$WATCH_MAX_ITERS" ]; then
        echo "[watch] WARNING: max iterations reached — attempting final merge anyway"
    fi

    # All bisect jobs done → merge every chunk in the manifest.
    echo "[watch] all bisect jobs finished — merging $(wc -l < "$MANIFEST") chunk(s)"
    OK=0; FAIL=0; FAILED_LIST=""
    while read -r LIB CHUNK; do
        [ -z "${LIB:-}" ] && continue
        echo "----- merge ${LIB} chunk ${CHUNK} -----"
        if "$MERGE_SCRIPT" "$MODEL_ID" "$LIB" "$CHUNK"; then
            OK=$((OK + 1))
        else
            FAIL=$((FAIL + 1))
            FAILED_LIST="${FAILED_LIST} ${LIB}:${CHUNK}"
        fi
    done < "$MANIFEST"

    echo "=========================================="
    echo "[watch] merge complete: ${OK} ok, ${FAIL} failed  $(date)"
    [ -n "$FAILED_LIST" ] && echo "[watch] incomplete merges (some molecules still uncovered):${FAILED_LIST}"
    echo "=========================================="
    exit 0
fi

# =============================================================================
#  SUBMIT MODE
# =============================================================================
MODEL_ID=${1:-}
QUEUE=${2:-cpu-queue}

if [ -z "$MODEL_ID" ]; then
    echo "Usage: $0 <model_id> [queue]"
    echo "Example: $0 eos4k4f_v1 cpu-queue"
    exit 1
fi

for req in "$BISECT_SCRIPT" "$MERGE_SCRIPT"; do
    if [ ! -f "$req" ]; then
        echo "ERROR: required script not found: $req"
        exit 1
    fi
done

SIF_FILE="/shared/sif-files/${MODEL_ID}.sif"
if [ ! -f "$SIF_FILE" ]; then
    echo "ERROR: SIF file not found: $SIF_FILE"
    echo "Run: /shared/scripts/download-ersilia-model.sh $MODEL_ID"
    exit 1
fi

WATCH_DIR="/fsx/output/bisect-watch/${MODEL_ID}"
mkdir -p "$WATCH_DIR"
STAMP=$(date +%Y%m%d_%H%M%S)
MANIFEST="${WATCH_DIR}/manifest_${STAMP}.txt"
: > "$MANIFEST"

echo "=========================================="
echo "Submit missing-chunk bisects"
echo "=========================================="
echo "Model:    $MODEL_ID"
echo "Queue:    $QUEUE"
echo "Manifest: $MANIFEST"
echo "=========================================="

# Snapshot of bisect jobs already running, so a re-run doesn't double-submit.
RUNNING_NAMES=$(squeue_names | grep -E "^bisect_${MODEL_ID}_" || true)

DEP_IDS=()
TOTAL_MISSING=0

for LIBRARY in "${LIBRARIES[@]}"; do
    INPUT_DIR="/fsx/input/${LIBRARY}"
    OUTPUT_DIR="/fsx/output/${LIBRARY}/${MODEL_ID}"

    if [ ! -d "$INPUT_DIR" ]; then
        echo "[$LIBRARY] no input dir — skipping"
        continue
    fi

    # Skip libraries the model never ran on (no output at all) — bisecting an
    # entire un-run library would be wrong; that's a normal-batch job.
    N_OUT=$(ls "$OUTPUT_DIR"/"${MODEL_ID}"_results_*.csv 2>/dev/null | wc -l)
    if [ ! -d "$OUTPUT_DIR" ] || [ "$N_OUT" -eq 0 ]; then
        echo "[$LIBRARY] no output yet — skipping (run the normal batch first)"
        continue
    fi

    mapfile -t INPUT_CHUNKS < <(ls "${INPUT_DIR}"/*_chunk_*.csv 2>/dev/null | sort)
    TOTAL=${#INPUT_CHUNKS[@]}
    LIB_MISSING=0

    for INPUT_FILE in "${INPUT_CHUNKS[@]}"; do
        CHUNK=$(basename "$INPUT_FILE" .csv | grep -oP '\d+$')
        OUT_FILE="${OUTPUT_DIR}/${MODEL_ID}_results_${CHUNK}.csv"
        [ -f "$OUT_FILE" ] && continue

        LIB_MISSING=$((LIB_MISSING + 1))
        TOTAL_MISSING=$((TOTAL_MISSING + 1))

        # Already being bisected? Don't resubmit, but still merge it later.
        if printf '%s\n' "$RUNNING_NAMES" | grep -qE "^bisect_${MODEL_ID}_${CHUNK}(_|$)"; then
            echo "[$LIBRARY] chunk ${CHUNK}: bisect already in progress — will merge"
            echo "${LIBRARY} ${CHUNK}" >> "$MANIFEST"
            continue
        fi

        # Launch a fresh bisect and capture its array job id.
        BISECT_OUT=$("$BISECT_SCRIPT" "$MODEL_ID" "$LIBRARY" "$CHUNK" "$QUEUE" 2>&1)
        JID=$(printf '%s\n' "$BISECT_OUT" | grep -oP 'Submitted array job: \K\d+' || true)
        if [ -n "$JID" ]; then
            echo "[$LIBRARY] chunk ${CHUNK}: bisect submitted (job ${JID})"
            DEP_IDS+=("$JID")
            echo "${LIBRARY} ${CHUNK}" >> "$MANIFEST"
        else
            echo "[$LIBRARY] chunk ${CHUNK}: BISECT SUBMIT FAILED"
            printf '%s\n' "$BISECT_OUT" | sed 's/^/      /'
        fi
    done

    [ "$LIB_MISSING" -gt 0 ] && echo "[$LIBRARY] ${LIB_MISSING} missing of ${TOTAL} chunks"
done

if [ ! -s "$MANIFEST" ]; then
    echo ""
    echo "No missing chunks for ${MODEL_ID} — nothing to bisect."
    rm -f "$MANIFEST"
    exit 0
fi

N_CHUNKS=$(wc -l < "$MANIFEST" | tr -d ' ')

# ── Submit the fire-and-forget merge-watcher ─────────────────────────────────
# afterany on the initial arrays so its first check runs once they're done; it
# then polls for any recursive descendants and requeues itself until all clear.
DEP_ARG=""
if [ ${#DEP_IDS[@]} -gt 0 ]; then
    DEP_ARG="--dependency=afterany:$(IFS=:; echo "${DEP_IDS[*]}")"
fi

WATCH_JID=$(sbatch --parsable \
    --partition="$QUEUE" \
    --job-name="bmerge_${MODEL_ID}" \
    --cpus-per-task=1 \
    --mem="$WATCH_MEM" \
    --time=02:00:00 \
    --output="/shared/logs/bmerge-%j.out" \
    --error="/shared/logs/bmerge-%j.err" \
    $DEP_ARG \
    "$SELF" --merge-watch "$MODEL_ID" "$MANIFEST" "$QUEUE" 0)

echo ""
echo "=========================================="
echo "Submitted bisects for ${N_CHUNKS} chunk(s); ${#DEP_IDS[@]} new array job(s)."
echo "Merge-watcher job: ${WATCH_JID:-<submit failed>}"
echo "  → auto-merges every chunk once all bisect jobs finish."
echo ""
echo "Monitor:     squeue -u ${ME} | grep -E 'bisect|bmerge'"
echo "Watcher log: /shared/logs/bmerge-${WATCH_JID}.out"
echo "Manifest:    $MANIFEST"
echo "=========================================="
