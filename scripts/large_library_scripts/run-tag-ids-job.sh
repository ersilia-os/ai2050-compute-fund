#!/bin/bash
#SBATCH --job-name=tag-ids
#SBATCH --partition=cpu-queue
#SBATCH --nodes=1
#SBATCH --cpus-per-task=2
#SBATCH --time=02:00:00
#SBATCH --output=/shared/logs/tag-ids-%A_%a.out
#SBATCH --error=/shared/logs/tag-ids-%A_%a.err
#
# Array-task worker for on-cluster id tagging (submit-tag-ids.sh).
#
# Each task processes a SLICE of chunk numbers (many chunks per task, since the
# join is cheap). For each chunk it pulls the standardization result + the step-01
# id shard from S3, runs join_ids.py to emit standardized_smiles,collection_id
# (row-aligned, verified, empties dropped), and uploads the gzipped tagged shard
# back to S3. Nothing is written to /fsx (S3 in, /tmp work, S3 out).
#
# Called as:
#   sbatch --array=0-(T-1) run-tag-ids-job.sh <model_id> <library_name> <slice_dir>
#     <slice_dir>/slice_<idx>.txt  holds this task's chunk numbers (one per line)

set -uo pipefail

MODEL_ID="${1:-}"
LIBRARY_NAME="${2:-}"
SLICE_DIR="${3:-}"
S3_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"
PY="${PY:-/shared/python39/bin/python3.9}"

if [ -z "$MODEL_ID" ] || [ -z "$LIBRARY_NAME" ] || [ -z "$SLICE_DIR" ]; then
    echo "ERROR: Usage: sbatch --array=0-N run-tag-ids-job.sh <model_id> <library_name> <slice_dir>"
    exit 1
fi
if [ -z "${SLURM_ARRAY_TASK_ID:-}" ]; then
    echo "ERROR: SLURM_ARRAY_TASK_ID not set — run as an array job."
    exit 1
fi

SLICE_FILE="${SLICE_DIR}/slice_$(printf '%04d' "$SLURM_ARRAY_TASK_ID").txt"
if [ ! -f "$SLICE_FILE" ]; then
    echo "ERROR: slice file not found: $SLICE_FILE"
    exit 1
fi

# Locate the joiner (repo folder first, then deployed /shared copy).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOINER="${SCRIPT_DIR}/join_ids.py"
[ -f "$JOINER" ] || JOINER="/shared/scripts/join_ids.py"
if [ ! -f "$JOINER" ]; then
    echo "ERROR: join_ids.py not found (deploy it to /shared/scripts)."
    exit 1
fi

S3_RESULTS="s3://${S3_BUCKET}/output/${LIBRARY_NAME}/${MODEL_ID}"
S3_IDSHARDS="s3://${S3_BUCKET}/smiles_ids/${LIBRARY_NAME}"
S3_TAGGED="s3://${S3_BUCKET}/tagged/${LIBRARY_NAME}/${MODEL_ID}"

N=$(wc -l < "$SLICE_FILE" | tr -d ' ')
echo "Tag task ${SLURM_ARRAY_TASK_ID}: $N chunk(s) from $SLICE_FILE on $(hostname)"

done_ok=0; skipped=0; failed=0
while read -r num; do
    [ -z "$num" ] && continue
    tagged_key="${S3_TAGGED}/${LIBRARY_NAME}_tagged_${num}.csv.gz"

    # Per-chunk resume: skip if already tagged in S3.
    if aws s3 ls "$tagged_key" >/dev/null 2>&1; then
        skipped=$((skipped + 1)); continue
    fi

    res_local="/tmp/${MODEL_ID}_results_${num}.csv"
    ids_local="/tmp/${LIBRARY_NAME}_smiles_ids_${num}.csv.gz"
    out_local="/tmp/${LIBRARY_NAME}_tagged_${num}.csv.gz"

    if ! aws s3 cp "${S3_RESULTS}/${MODEL_ID}_results_${num}.csv" "$res_local" >/dev/null 2>&1; then
        echo "  FAIL chunk ${num}: result not in S3"; failed=$((failed + 1)); continue
    fi
    if ! aws s3 cp "${S3_IDSHARDS}/${LIBRARY_NAME}_smiles_ids_${num}.csv.gz" "$ids_local" >/dev/null 2>&1; then
        echo "  FAIL chunk ${num}: id shard not in S3 (upload smiles_ids/ first)"
        rm -f "$res_local"; failed=$((failed + 1)); continue
    fi

    if "$PY" "$JOINER" --result "$res_local" --idshard "$ids_local" --out "$out_local"; then
        if aws s3 cp "$out_local" "$tagged_key" >/dev/null 2>&1; then
            done_ok=$((done_ok + 1))
        else
            echo "  FAIL chunk ${num}: tagged upload failed"; failed=$((failed + 1))
        fi
    else
        echo "  FAIL chunk ${num}: join_ids.py error (alignment?)"; failed=$((failed + 1))
    fi
    rm -f "$res_local" "$ids_local" "$out_local"
done < "$SLICE_FILE"

echo "Tag task ${SLURM_ARRAY_TASK_ID} done: ok=$done_ok skipped=$skipped failed=$failed"
[ "$failed" -eq 0 ]
