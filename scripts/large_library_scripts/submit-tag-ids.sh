#!/bin/bash
# =============================================================================
# On-cluster id tagging orchestrator (billion-scale)
# =============================================================================
# Re-attaches the collection id to standardized SMILES, per chunk, and writes
# gzipped tagged shards (standardized_smiles,collection_id) to S3 — the compact
# (~30 GB) input the LOCAL dedup step then downloads.
#
# Unlike the wave orchestrator this does NOT touch /fsx (S3 in, /tmp work, S3 out),
# so there is no FSx eviction to manage. The join is cheap, so each array task
# processes many chunks (chunks_per_task).
#
# PREREQUISITE: the step-01 id shards must be in S3:
#   aws s3 sync <out>/<lib>/smiles_ids/  s3://<bucket>/smiles_ids/<lib>/
# (01_large_library_processing.py --upload-idmap-s3 does this for you.)
#
# Run on the head node (fast; minutes-to-an-hour). Resumable (skips tagged chunks).
#
# Usage: submit-tag-ids.sh <model_id> <library_name> [chunks_per_task=100] [queue=cpu-queue]
# =============================================================================

set -uo pipefail

MODEL_ID="${1:-}"
LIBRARY_NAME="${2:-}"
CHUNKS_PER_TASK="${3:-100}"
QUEUE="${4:-cpu-queue}"
S3_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"
POLL_SECONDS="${POLL_SECONDS:-30}"

if [ -z "$MODEL_ID" ] || [ -z "$LIBRARY_NAME" ]; then
    echo "Usage: $0 <model_id> <library_name> [chunks_per_task=100] [queue=cpu-queue]"
    exit 1
fi

S3_RESULTS="s3://${S3_BUCKET}/output/${LIBRARY_NAME}/${MODEL_ID}/"
S3_IDSHARDS="s3://${S3_BUCKET}/smiles_ids/${LIBRARY_NAME}/"
S3_TAGGED="s3://${S3_BUCKET}/tagged/${LIBRARY_NAME}/${MODEL_ID}/"
WORK="/fsx/output/${LIBRARY_NAME}/${MODEL_ID}/_tag_work"
SLICE_DIR="${WORK}/slices"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_JOB="${SCRIPT_DIR}/run-tag-ids-job.sh"
[ -f "$RUN_JOB" ] || RUN_JOB="/shared/scripts/run-tag-ids-job.sh"
if [ ! -f "$RUN_JOB" ]; then
    echo "ERROR: worker not found: $RUN_JOB (deploy run-tag-ids-job.sh + join_ids.py to /shared/scripts)"
    exit 1
fi

rm -rf "$SLICE_DIR"; mkdir -p "$SLICE_DIR"

echo "=========================================="
echo "Id Tagging Orchestrator"
echo "  Model    : $MODEL_ID"
echo "  Library  : $LIBRARY_NAME"
echo "  Results  : $S3_RESULTS"
echo "  Id shards: $S3_IDSHARDS"
echo "  Tagged   : $S3_TAGGED"
echo "=========================================="

# --- manifest: chunk numbers that have a result in S3 ---
MANIFEST="${WORK}/manifest.txt"
aws s3 ls "$S3_RESULTS" \
  | awk '{print $NF}' \
  | grep -oP "${MODEL_ID}_results_\K\d+(?=\.csv$)" \
  | sort -n > "$MANIFEST"
TOTAL=$(wc -l < "$MANIFEST" | tr -d ' ')
if [ "$TOTAL" -eq 0 ]; then
    echo "ERROR: no ${MODEL_ID}_results_*.csv under $S3_RESULTS"
    exit 1
fi

# --- id-shard sanity check ---
IDS_COUNT=$(aws s3 ls "$S3_IDSHARDS" 2>/dev/null | grep -c '_smiles_ids_.*\.csv\.gz$' || true)
echo "  Results found : $TOTAL   Id shards in S3: ${IDS_COUNT:-0}"
if [ "${IDS_COUNT:-0}" -eq 0 ]; then
    echo "ERROR: no id shards under $S3_IDSHARDS — upload them first:"
    echo "  aws s3 sync <out>/${LIBRARY_NAME}/smiles_ids/ $S3_IDSHARDS"
    exit 1
fi

# --- resume: skip chunks already tagged ---
DONE="${WORK}/done.txt"
aws s3 ls "$S3_TAGGED" 2>/dev/null \
  | awk '{print $NF}' \
  | grep -oP "_tagged_\K\d+(?=\.csv\.gz$)" \
  | sort -n > "$DONE" || true
REMAINING="${WORK}/remaining.txt"
comm -23 "$MANIFEST" "$DONE" > "$REMAINING"
REMAINING_COUNT=$(wc -l < "$REMAINING" | tr -d ' ')
echo "  Already tagged: $(wc -l < "$DONE" | tr -d ' ')   Remaining: $REMAINING_COUNT"
if [ "$REMAINING_COUNT" -eq 0 ]; then
    echo "Nothing to do — all chunks already tagged in S3."
    exit 0
fi

# --- keep the task count within one array (<=1000): bump chunks_per_task if needed ---
MIN_CPT=$(( (REMAINING_COUNT + 999) / 1000 ))
if [ "$CHUNKS_PER_TASK" -lt "$MIN_CPT" ]; then
    echo "  Bumping chunks_per_task $CHUNKS_PER_TASK -> $MIN_CPT to keep tasks <= 1000."
    CHUNKS_PER_TASK=$MIN_CPT
fi

# --- slice remaining into slice_0000.txt ... (one file per array task) ---
split -l "$CHUNKS_PER_TASK" -d -a 4 --additional-suffix=.txt "$REMAINING" "${SLICE_DIR}/slice_"
NUM_TASKS=$(ls "${SLICE_DIR}"/slice_*.txt | wc -l | tr -d ' ')
echo "  Tasks: $NUM_TASKS ($CHUNKS_PER_TASK chunks each)"

ARRAY_ID=$(sbatch --partition="$QUEUE" --array=0-$((NUM_TASKS - 1)) \
    "$RUN_JOB" "$MODEL_ID" "$LIBRARY_NAME" "$SLICE_DIR" 2>&1 \
  | grep -oP 'Submitted batch job \K\d+')
if [ -z "$ARRAY_ID" ]; then
    echo "ERROR: sbatch submission failed."
    exit 1
fi
echo "  Submitted array job $ARRAY_ID; waiting ..."
# Robust wait: declare the array done only after squeue reports NO active tasks on 3
# CONSECUTIVE polls. A single transient empty/failed squeue must NOT end the wait —
# while the cluster scales Spot nodes (state CF/CONFIGURING) the controller is busy and
# squeue can momentarily return nothing, which would otherwise trip a premature
# "0 tagged" completion. CONFIGURING is included so powering-up nodes count as active,
# and a failed squeue is treated as "still active" rather than "done".
sleep "$POLL_SECONDS"
empties=0
while :; do
    out=$(squeue -h -j "$ARRAY_ID" -t PENDING,RUNNING,COMPLETING,CONFIGURING,SUSPENDED 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        n=$(printf '%s' "$out" | grep -c .)             # active tasks (0 if none)
    elif printf '%s' "$out" | grep -qi 'invalid job id'; then
        n=0                                             # job purged from controller = DONE
    else
        n=1                                             # transient squeue failure -> keep waiting
    fi
    if [ "$n" -gt 0 ]; then
        empties=0
    else
        empties=$((empties + 1))
        [ "$empties" -ge 3 ] && break
    fi
    sleep "$POLL_SECONDS"
done

# --- verify: count tagged vs expected ---
TAGGED_NOW=$(aws s3 ls "$S3_TAGGED" 2>/dev/null | grep -c '_tagged_.*\.csv\.gz$' || true)
echo "=========================================="
echo "Tagging complete. Tagged in S3: ${TAGGED_NOW:-0} / expected $TOTAL"
if [ "${TAGGED_NOW:-0}" -lt "$TOTAL" ]; then
    echo "WARNING: fewer tagged shards than results — re-run this script to retry the gaps"
    echo "         (check /shared/logs/tag-ids-*.err for join/alignment errors)."
    exit 1
fi
echo "Next (local): dedup_and_map.py --model-id $MODEL_ID --library-name $LIBRARY_NAME"
echo "=========================================="
