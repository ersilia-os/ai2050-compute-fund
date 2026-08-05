#!/bin/bash
# Master orchestrator for the DrugCLIP score validation (run on the head node).
#
# Chains every CLUSTER step (the plot is run separately on the laptop):
#   1. prepare_validation_mols.py  → molecule chunks + pockets_index.csv
#   2. submit-drugclip.sh          → encode the leader SMILES (array job, gpu-queue)
#   3. dependent job (afterok)     → score_validation.py + compare_validation.py + push to S3
#
# The pocket side is reused as-is (existing /fsx/input/targets/<ID>/pockets/pocket_reps.pkl);
# nothing about the pockets is re-encoded here.
#
# Usage:
#   bash run-validation.sh [scope=pilot] [queue=gpu-queue]
# Examples:
#   bash run-validation.sh pilot            # P00519 (or $PILOT_TARGETS) only
#   bash run-validation.sh all              # every pocket whose target is encoded
#   PILOT_TARGETS="P00519,O14757" bash run-validation.sh pilot

set -uo pipefail

SCOPE=${1:-pilot}
QUEUE=${2:-gpu-queue}
PILOT_TARGETS=${PILOT_TARGETS:-P00519}
S3_BUCKET=${S3_BUCKET:-ai2050-ersilia-cluster}
LIBRARY=validation_leaders

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"           # .../drugclip_scripts/validation
DRUGCLIP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"                          # .../drugclip_scripts
PY=/shared/python39/bin/python3.9

INPUT_DIR="/fsx/input/${LIBRARY}"
OUTPUT_DIR="/fsx/output/${LIBRARY}"
EMB_DIR="${OUTPUT_DIR}/drugclip"
SCREEN_DIR="${INPUT_DIR}/screen_results"
# Pocket source + output tag are overridable so an alternate pocket set (e.g. the
# probe-based one in /fsx/input/targets_probe) can be scored without clobbering the
# center-based results. VAL_TAG suffixes the output dir + summary + S3 keys.
TARGETS_BASE="${TARGETS_BASE:-/fsx/input/targets}"
VAL_TAG="${VAL_TAG:-}"
VAL_DIR="${OUTPUT_DIR}/validation${VAL_TAG:+_${VAL_TAG}}"
SUMMARY_CSV="${OUTPUT_DIR}/validation_summary${VAL_TAG:+_${VAL_TAG}}.csv"
S3_VAL="s3://${S3_BUCKET}/output/${LIBRARY}/validation${VAL_TAG:+_${VAL_TAG}}"
S3_SUMMARY="s3://${S3_BUCKET}/output/${LIBRARY}/validation_summary${VAL_TAG:+_${VAL_TAG}}.csv"

echo "=========================================="
echo "DrugCLIP validation — master orchestrator"
echo "=========================================="
echo "Scope   : $SCOPE" $([ "$SCOPE" = pilot ] && echo "($PILOT_TARGETS)")
echo "Queue   : $QUEUE"
echo "Library : $LIBRARY"
echo "Pockets : $TARGETS_BASE"
echo "Out tag : ${VAL_TAG:-<none>}  → $(basename "$VAL_DIR")"
echo "=========================================="

# ── rescore mode: re-run ONLY score+compare on existing embeddings, via the queue ──
# (no prep, no re-encode, no head-node compute — just an sbatch job)
if [ "$SCOPE" = "rescore" ]; then
    [ -f "${INPUT_DIR}/pockets_index.csv" ] || {
        echo "ERROR: ${INPUT_DIR}/pockets_index.csv missing — run a normal scope (pilot/all) first"; exit 1; }
    ls "${EMB_DIR}/${LIBRARY}_drugclip_"*.h5 >/dev/null 2>&1 || {
        echo "ERROR: no embeddings in ${EMB_DIR} — run a normal scope first"; exit 1; }
    mkdir -p /shared/logs
    RS_ID=$(sbatch \
        --partition="$QUEUE" --job-name="drugclip-validate" --nodes=1 --time=4:00:00 \
        --output=/shared/logs/drugclip-validate-%j.out --error=/shared/logs/drugclip-validate-%j.err \
        --wrap="set -e; \
            $PY ${SCRIPT_DIR}/score_validation.py --pockets-index ${INPUT_DIR}/pockets_index.csv \
                --targets-base ${TARGETS_BASE} --emb-dir ${EMB_DIR} --library ${LIBRARY} --out-dir ${VAL_DIR}; \
            $PY ${SCRIPT_DIR}/compare_validation.py --scores-dir ${VAL_DIR} \
                --out ${SUMMARY_CSV}; \
            aws s3 sync ${VAL_DIR} ${S3_VAL}/ --no-progress; \
            aws s3 cp ${SUMMARY_CSV} ${S3_SUMMARY}" \
        2>&1 | grep -oP 'Submitted batch job \K\d+')
    [ -n "$RS_ID" ] || { echo "ERROR: rescore submission failed"; exit 1; }
    echo "Submitted rescore job ${RS_ID} on ${QUEUE} (score + compare, existing embeddings)."
    echo "  Pockets : ${TARGETS_BASE}"
    echo "  Monitor : squeue -u \$USER | grep drugclip-validate"
    echo "  Log     : tail -f /shared/logs/drugclip-validate-${RS_ID}.out"
    echo "  Result  : cat ${SUMMARY_CSV}   (when done)"
    exit 0
fi

# ── Preflight ─────────────────────────────────────────────────────────────────
[ -f /shared/sif-files/drugclip.sif ] || {
    echo "ERROR: /shared/sif-files/drugclip.sif missing"
    echo "  aws s3 cp s3://${S3_BUCKET}/sif-files/drugclip.sif /shared/sif-files/"; exit 1; }

# Molecule encoder needs weights at BOTH paths the scripts check
for w in /shared/drugclip-weights/6_folds/fold_0.pt /shared/drugclip-weights/model_weights/6_folds/fold_0.pt; do
    [ -f "$w" ] || {
        echo "ERROR: weights missing: $w"
        echo "  Ensure both /shared/drugclip-weights/6_folds and .../model_weights/6_folds resolve"
        echo "  (symlink one to the other, or aws s3 sync s3://${S3_BUCKET}/drugclip-weights/model_weights/6_folds/ ...)"
        exit 1; }
done

[ -d "$SCREEN_DIR" ] || {
    echo "ERROR: ground truth not on cluster: $SCREEN_DIR"
    echo "  From the laptop, upload it once:"
    echo "  aws s3 sync /home/marina/Documents/AI2050/Targets/screen_results \\"
    echo "      s3://${S3_BUCKET}/input/${LIBRARY}/screen_results/"
    exit 1; }

[ -d "$TARGETS_BASE" ] || { echo "ERROR: $TARGETS_BASE not found (pockets not staged)"; exit 1; }

# FSx S3-import often creates /fsx/input/<lib> owned by root — make it writable so we
# can drop the chunk CSVs + pockets_index.csv there (same fix as submit-drugclip-pocket.sh).
mkdir -p "$INPUT_DIR" 2>/dev/null || true
sudo chown ec2-user:ec2-user "$INPUT_DIR" 2>/dev/null || true

# ── Step 1: prepare molecule chunks + pockets index ───────────────────────────
echo ""
echo "[1/3] Preparing validation molecules ..."
"$PY" "${SCRIPT_DIR}/prepare_validation_mols.py" \
    --screen-results-dir "$SCREEN_DIR" \
    --targets-base "$TARGETS_BASE" \
    --input-dir "$INPUT_DIR" \
    --library "$LIBRARY" \
    --scope "$SCOPE" \
    --pilot-targets "$PILOT_TARGETS" || { echo "ERROR: prepare step failed"; exit 1; }

N_CHUNKS=$(ls "${INPUT_DIR}/${LIBRARY}_chunk_"*.csv 2>/dev/null | wc -l)
[ "$N_CHUNKS" -gt 0 ] || { echo "ERROR: no chunks produced"; exit 1; }

# ── Step 2: encode leader SMILES (array job on the chosen queue) ───────────────
echo ""
echo "[2/3] Submitting encoding (${N_CHUNKS} chunks) on ${QUEUE} ..."
SUBMIT_OUT=$(bash "${DRUGCLIP_DIR}/submit-drugclip.sh" "$LIBRARY" "$QUEUE" 2>&1)
echo "$SUBMIT_OUT"
ENCODE_IDS=$(echo "$SUBMIT_OUT" | grep -oP 'Submitted job \K\d+' | paste -sd: -)
[ -n "$ENCODE_IDS" ] || { echo "ERROR: could not parse encode job id(s)"; exit 1; }

# ── Step 3: dependent scoring + comparison + push to S3 ───────────────────────
echo ""
echo "[3/3] Submitting dependent scoring job (afterok:${ENCODE_IDS}) ..."
mkdir -p /shared/logs
SCORE_ID=$(sbatch \
    --partition="$QUEUE" \
    --job-name="drugclip-validate" \
    --nodes=1 \
    --time=4:00:00 \
    --dependency=afterok:"${ENCODE_IDS}" \
    --output=/shared/logs/drugclip-validate-%j.out \
    --error=/shared/logs/drugclip-validate-%j.err \
    --wrap="set -e; \
        $PY ${SCRIPT_DIR}/score_validation.py --pockets-index ${INPUT_DIR}/pockets_index.csv \
            --targets-base ${TARGETS_BASE} --emb-dir ${EMB_DIR} --library ${LIBRARY} --out-dir ${VAL_DIR}; \
        $PY ${SCRIPT_DIR}/compare_validation.py --scores-dir ${VAL_DIR} \
            --out ${SUMMARY_CSV}; \
        aws s3 sync ${VAL_DIR} ${S3_VAL}/ --no-progress; \
        aws s3 cp ${SUMMARY_CSV} ${S3_SUMMARY}" \
    2>&1 | grep -oP 'Submitted batch job \K\d+')
[ -n "$SCORE_ID" ] || { echo "ERROR: dependent scoring job submission failed"; exit 1; }

echo ""
echo "=========================================="
echo "Submitted. Encode job(s): ${ENCODE_IDS}   Scoring job: ${SCORE_ID}"
echo "Monitor : watch -n 15 'squeue -u \$USER'"
echo "Logs    : tail -f /shared/logs/drugclip-validate-${SCORE_ID}.out"
echo "Results : ${VAL_DIR}/<pocket>/scores.csv  +  ${SUMMARY_CSV}"
echo "          (also pushed to ${S3_VAL}/)"
echo ""
echo "Then plot locally:"
echo "  aws s3 sync ${S3_VAL}/ ./validation_out/"
echo "  python scripts/drugclip_scripts/validation/plot_validation.py ./validation_out/"
echo "=========================================="
