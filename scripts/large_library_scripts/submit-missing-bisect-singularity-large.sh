#!/bin/bash
# =============================================================================
# Missing-chunk bisect for a LARGE (S3-centric, wave-pipeline) library — SINGULARITY.
# =============================================================================
# Singularity counterpart of large_library_scripts/submit-missing-bisect-large.sh.
# For each output chunk that is MISSING in S3, launch a binary-search (bisect) job to
# isolate the poison molecule(s), then auto-merge AND upload each merged result back
# to S3 (evicting /fsx afterwards).
#
# Reuses the singularity bisect chain (bisect-singularity-library-chunk.sh ->
# run-singularity-library-bisect.sh -> merge-singularity-library-bisect.sh) deployed
# in /shared/scripts/singularity. Output naming is `<model_id>_<chunk_num>.csv`
# (NO `_results_`) to match that chain and submit-singularity-waves.sh.
#
# Two differences from the small-library bisect:
#   1. "Missing" is computed from S3, not /fsx — the wave orchestrator evicts
#      /fsx/output after every wave, so results live only in S3:
#        missing = (chunks in s3://<bucket>/input/<lib>/)
#                − (chunks in s3://<bucket>/output/<lib>/<model>/)
#   2. The merge-watcher UPLOADS each merged result to S3 and removes it (+ the
#      bisect workspace) from /fsx, because merge-singularity-library-bisect.sh only
#      writes /fsx.
#
# NOTE: bisect reads the raw input from /fsx/input/<lib>/ (auto-imported from
# s3 input/<lib>/). Run it while those raw chunks are still in place.
#
# Modes:
#   submit-missing-bisect-singularity-large.sh <model_id> [library] [queue]
#   submit-missing-bisect-singularity-large.sh --merge-watch <model_id> <library> <manifest> <queue> <iter>  (INTERNAL)
#
# Env: S3_BUCKET (default ai2050-ersilia-cluster), WATCH_INTERVAL=5 (min),
#      WATCH_MAX_ITERS=1000, WATCH_MEM=32G
# =============================================================================

set -uo pipefail

S3_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"
# Fixed shared paths (do NOT derive from BASH_SOURCE — sbatch runs a spool copy).
# This script deploys alongside the other large-library scripts; the reused
# singularity bisect chain (bisect/merge) lives in /shared/scripts/singularity.
LARGE_DIR="${ERSILIA_LARGE_DIR:-/shared/scripts/large_library_scripts}"
SING_DIR="${ERSILIA_SINGULARITY_DIR:-/shared/scripts/singularity}"
SELF="${LARGE_DIR}/submit-missing-bisect-singularity-large.sh"
BISECT_SCRIPT="${SING_DIR}/bisect-singularity-library-chunk.sh"
MERGE_SCRIPT="${SING_DIR}/merge-singularity-library-bisect.sh"
WATCH_MEM="${WATCH_MEM:-32G}"
ME="${USER:-$(whoami)}"

squeue_names() { squeue -u "$ME" -h -o "%200j" 2>/dev/null | awk '{print $1}'; }

# =============================================================================
#  WATCHER MODE  (merge + upload to S3 + evict /fsx)
# =============================================================================
if [ "${1:-}" = "--merge-watch" ]; then
    shift
    MODEL_ID=${1:-}; LIBRARY=${2:-}; MANIFEST=${3:-}; QUEUE=${4:-cpu-queue}; ITER=${5:-0}
    WATCH_INTERVAL=${WATCH_INTERVAL:-5}; WATCH_MAX_ITERS=${WATCH_MAX_ITERS:-1000}

    echo "[watch] model=$MODEL_ID lib=$LIBRARY iter=$ITER manifest=$MANIFEST  $(date)"
    if [ -z "$MODEL_ID" ] || [ ! -f "$MANIFEST" ]; then
        echo "[watch] ERROR: bad model id or manifest not found"; exit 1
    fi

    REMAINING=$(squeue_names | grep -cE "^bisect_${MODEL_ID}_" || true)
    echo "[watch] bisect jobs still in queue: ${REMAINING}"

    if [ "${REMAINING:-0}" -gt 0 ] && [ "$ITER" -lt "$WATCH_MAX_ITERS" ]; then
        echo "[watch] not done — requeue in ${WATCH_INTERVAL} min"
        sbatch --parsable --partition="$QUEUE" --job-name="bmerge_${MODEL_ID}" \
            --cpus-per-task=1 --mem="$WATCH_MEM" --time=02:00:00 \
            --begin="now+${WATCH_INTERVAL}minutes" \
            --output="/shared/logs/bmerge-%j.out" --error="/shared/logs/bmerge-%j.err" \
            --export=ALL,S3_BUCKET="$S3_BUCKET" \
            "$SELF" --merge-watch "$MODEL_ID" "$LIBRARY" "$MANIFEST" "$QUEUE" $((ITER + 1))
        exit 0
    fi
    [ "$ITER" -ge "$WATCH_MAX_ITERS" ] && echo "[watch] WARNING: max iters — final merge anyway"

    echo "[watch] merging + uploading $(wc -l < "$MANIFEST") chunk(s)"
    OK=0; FAIL=0; FAILED_LIST=""
    while read -r LIB CHUNK; do
        [ -z "${LIB:-}" ] && continue
        echo "----- merge+upload ${LIB} chunk ${CHUNK} -----"
        if "$MERGE_SCRIPT" "$MODEL_ID" "$LIB" "$CHUNK"; then
            RESULT="/fsx/output/${LIB}/${MODEL_ID}/${MODEL_ID}_${CHUNK}.csv"
            DEST="s3://${S3_BUCKET}/output/${LIB}/${MODEL_ID}/${MODEL_ID}_${CHUNK}.csv"
            if aws s3 cp "$RESULT" "$DEST"; then
                OK=$((OK + 1))
                rm -f "$RESULT"
                rm -rf "/fsx/output/${LIB}/${MODEL_ID}/bisect/${CHUNK}"
            else
                echo "[watch] S3 upload FAILED for chunk ${CHUNK} (left on /fsx)"
                FAIL=$((FAIL + 1)); FAILED_LIST="${FAILED_LIST} ${LIB}:${CHUNK}"
            fi
        else
            FAIL=$((FAIL + 1)); FAILED_LIST="${FAILED_LIST} ${LIB}:${CHUNK}"
        fi
    done < "$MANIFEST"

    echo "=========================================="
    echo "[watch] done: ${OK} uploaded, ${FAIL} failed  $(date)"
    [ -n "$FAILED_LIST" ] && echo "[watch] incomplete (molecules still uncovered):${FAILED_LIST}"
    echo "=========================================="
    exit 0
fi

# =============================================================================
#  SUBMIT MODE
# =============================================================================
MODEL_ID=${1:-}
LIBRARY=${2:-Enamine_Real_Sample_1.4B}
QUEUE=${3:-cpu-queue}

if [ -z "$MODEL_ID" ]; then
    echo "Usage: $0 <model_id> [library=Enamine_Real_Sample_1.4B] [queue=cpu-queue]"
    echo "Example: $0 mtb-public-models Enamine_Real_Sample_1.4B cpu-queue"
    exit 1
fi
for req in "$BISECT_SCRIPT" "$MERGE_SCRIPT"; do
    [ -f "$req" ] || { echo "ERROR: required script not found: $req"; exit 1; }
done
[ -f "/shared/sif-files/${MODEL_ID}.sif" ] || {
    echo "ERROR: SIF not found: /shared/sif-files/${MODEL_ID}.sif"; exit 1; }

S3_INPUT="s3://${S3_BUCKET}/input/${LIBRARY}/"
S3_OUTPUT="s3://${S3_BUCKET}/output/${LIBRARY}/${MODEL_ID}/"
WATCH_DIR="/fsx/output/bisect-watch/${MODEL_ID}"
mkdir -p "$WATCH_DIR"
STAMP=$(date +%Y%m%d_%H%M%S)
MANIFEST="${WATCH_DIR}/manifest_${LIBRARY}_${STAMP}.txt"; : > "$MANIFEST"

echo "=========================================="
echo "Missing-chunk bisect (large library, singularity)"
echo "  Model   : $MODEL_ID"
echo "  Library : $LIBRARY"
echo "  Queue   : $QUEUE"
echo "  Manifest: $MANIFEST"
echo "=========================================="

# --- Missing = S3 input nums - S3 output nums ---
INF=$(mktemp); OUTF=$(mktemp)
aws s3 ls "$S3_INPUT"  | grep -oP '_chunk_\K\d+(?=\.csv$)'      | sort > "$INF"
aws s3 ls "$S3_OUTPUT" | grep -oP "${MODEL_ID}_\K\d+(?=\.csv$)" | sort > "$OUTF" || true
N_IN=$(wc -l < "$INF"); N_OUT=$(wc -l < "$OUTF")
echo "Input chunks in S3 : $N_IN"
echo "Output chunks in S3: $N_OUT"
if [ "$N_IN" -eq 0 ]; then echo "ERROR: no input chunks in $S3_INPUT"; rm -f "$INF" "$OUTF"; exit 1; fi
if [ "$N_OUT" -eq 0 ]; then
    echo "ERROR: no outputs at all — run the wave orchestrator first, not bisect."
    rm -f "$INF" "$OUTF"; exit 1
fi
mapfile -t MISSING < <(comm -23 "$INF" "$OUTF")
rm -f "$INF" "$OUTF"
echo "Missing chunks     : ${#MISSING[@]}"
if [ ${#MISSING[@]} -eq 0 ]; then echo "Nothing missing — done."; rm -f "$MANIFEST"; exit 0; fi

RUNNING_NAMES=$(squeue_names | grep -E "^bisect_${MODEL_ID}_" || true)
DEP_IDS=()
for CHUNK in "${MISSING[@]}"; do
    if printf '%s\n' "$RUNNING_NAMES" | grep -qE "^bisect_${MODEL_ID}_${CHUNK}(_|$)"; then
        echo "chunk ${CHUNK}: bisect already running — will merge"
        echo "${LIBRARY} ${CHUNK}" >> "$MANIFEST"; continue
    fi
    BOUT=$("$BISECT_SCRIPT" "$MODEL_ID" "$LIBRARY" "$CHUNK" "$QUEUE" 2>&1)
    JID=$(printf '%s\n' "$BOUT" | grep -oP 'Submitted array job: \K\d+' || true)
    if [ -n "$JID" ]; then
        echo "chunk ${CHUNK}: bisect submitted (job ${JID})"
        DEP_IDS+=("$JID"); echo "${LIBRARY} ${CHUNK}" >> "$MANIFEST"
    else
        echo "chunk ${CHUNK}: BISECT SUBMIT FAILED"; printf '%s\n' "$BOUT" | sed 's/^/      /'
    fi
done

[ -s "$MANIFEST" ] || { echo "Nothing submitted."; rm -f "$MANIFEST"; exit 0; }
N_CHUNKS=$(wc -l < "$MANIFEST" | tr -d ' ')

DEP_ARG=""
[ ${#DEP_IDS[@]} -gt 0 ] && DEP_ARG="--dependency=afterany:$(IFS=:; echo "${DEP_IDS[*]}")"

WATCH_JID=$(sbatch --parsable --partition="$QUEUE" --job-name="bmerge_${MODEL_ID}" \
    --cpus-per-task=1 --mem="$WATCH_MEM" --time=02:00:00 \
    --output="/shared/logs/bmerge-%j.out" --error="/shared/logs/bmerge-%j.err" \
    --export=ALL,S3_BUCKET="$S3_BUCKET" \
    $DEP_ARG \
    "$SELF" --merge-watch "$MODEL_ID" "$LIBRARY" "$MANIFEST" "$QUEUE" 0)

echo ""
echo "=========================================="
echo "Submitted bisects for ${N_CHUNKS} chunk(s); ${#DEP_IDS[@]} new array job(s)."
echo "Merge-watcher job: ${WATCH_JID:-<submit failed>}  (merges + uploads to S3 when bisects finish)"
echo "Monitor:  squeue -u ${ME} | grep -E 'bisect|bmerge'"
echo "Manifest: $MANIFEST"
echo "=========================================="
