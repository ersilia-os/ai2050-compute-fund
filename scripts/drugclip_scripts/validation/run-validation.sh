#!/bin/bash
# Master orchestrator for the DrugCLIP validation (run on the head node).
#
# Chains every CLUSTER step (the plots are run separately on the laptop):
#   1. prepare_validation_mols.py  → molecule chunks + pockets_index.csv
#   2. submit-drugclip.sh          → encode the leader SMILES (array job, gpu-queue)
#   3. dependent job (afterok)     → score + compare + ENRICHMENT + push to S3
#
# The headline analysis is the ENRICHMENT one (enrichment_validation.py): the paper's
# absolute z-scores are not reproducible with a 36k background instead of their 500M
# library, but the per-pocket RANKING is — so we ask whether each target's own leader
# molecules float to the top of the pooled deck. The older score/compare step is kept
# because it costs nothing and its per-pocket scores.csv is still useful.
#
# The pocket side is reused as-is (existing /fsx/input/targets/<ID>/pockets/pocket_reps.pkl);
# nothing about the pockets is re-encoded here.
#
# Usage:
#   bash run-validation.sh [scope=pilot] [queue=gpu-queue]
# Examples:
#   bash run-validation.sh pilot            # P00519 (or $PILOT_TARGETS) only, NO enrichment
#   bash run-validation.sh all              # encode the full deck, then score + enrich
#   bash run-validation.sh rescore          # re-run score + compare + enrich on existing embeddings
#   bash run-validation.sh enrich           # re-run ONLY the enrichment (fast iteration, ~3 min)
#   PILOT_TARGETS="P00519,O14757" bash run-validation.sh pilot
#   EF_FRACTIONS=0.005,0.01,0.02,0.05 bash run-validation.sh enrich
#   CENTER_MOLECULES=1 VAL_TAG=centered bash run-validation.sh enrich   # hubness correction
#
# Enrichment needs the FULL deck — every other target's leaders are the decoys — so it is
# skipped for scope=pilot and enrichment_validation.py refuses a too-small index anyway.

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

ENR_DIR="${OUTPUT_DIR}/enrichment${VAL_TAG:+_${VAL_TAG}}"
S3_ENR="s3://${S3_BUCKET}/output/${LIBRARY}/enrichment${VAL_TAG:+_${VAL_TAG}}"
EF_FRACTIONS="${EF_FRACTIONS:-0.01,0.05,0.10}"
BEDROC_ALPHAS="${BEDROC_ALPHAS:-20,80.5}"
N_SHUFFLES="${N_SHUFFLES:-5}"

# CENTER_MOLECULES=1 subtracts each molecule's mean score across targets before ranking,
# cancelling the hubness that lets a shared pool of molecules monopolise the top of every
# pocket's ranking. Pair it with VAL_TAG to keep centred and uncentred results side by side.
CENTER_FLAG=""
[ "${CENTER_MOLECULES:-0}" != "0" ] && CENTER_FLAG="--center-molecules"

# DECOY_LIBRARY=<name> appends that encoded library to the deck as decoys (e.g. a ChEMBL
# subset), instead of relying on the other targets' leaders. Decoys are never labelled active.
DECOY_FLAGS=""
if [ -n "${DECOY_LIBRARY:-}" ]; then
    DECOY_FLAGS="--decoy-library ${DECOY_LIBRARY} \
        --decoy-emb-dir ${DECOY_EMB_DIR:-/fsx/output/${DECOY_LIBRARY}/drugclip} \
        --decoy-input-dir ${DECOY_INPUT_DIR:-/fsx/input/${DECOY_LIBRARY}}"
fi

# Expanded on the head node at submit time, like the other --wrap payloads.
enrich_cmd() {
    echo "$PY ${SCRIPT_DIR}/enrichment_validation.py \
        --pockets-index ${INPUT_DIR}/pockets_index.csv \
        --targets-base ${TARGETS_BASE} --emb-dir ${EMB_DIR} --library ${LIBRARY} \
        --input-dir ${INPUT_DIR} \
        --out-dir ${ENR_DIR} --ef-fractions ${EF_FRACTIONS} --bedroc-alphas ${BEDROC_ALPHAS} \
        --n-shuffles ${N_SHUFFLES} --dump-npz ${CENTER_FLAG} ${DECOY_FLAGS}"
}

echo "=========================================="
echo "DrugCLIP validation — master orchestrator"
echo "=========================================="
echo "Scope   : $SCOPE" $([ "$SCOPE" = pilot ] && echo "($PILOT_TARGETS)")
echo "Queue   : $QUEUE"
echo "Library : $LIBRARY"
echo "Pockets : $TARGETS_BASE"
echo "Out tag : ${VAL_TAG:-<none>}  → $(basename "$VAL_DIR")"
echo "=========================================="

# ── rescore / enrich: re-run the ANALYSIS on existing embeddings, via the queue ──
# (no prep, no re-encode, no head-node compute — just an sbatch job)
#   rescore → score + compare + enrichment
#   enrich  → enrichment only; this is the loop to iterate the analysis in, ~3 min a turn
if [ "$SCOPE" = "rescore" ] || [ "$SCOPE" = "enrich" ]; then
    [ -f "${INPUT_DIR}/pockets_index.csv" ] || {
        echo "ERROR: ${INPUT_DIR}/pockets_index.csv missing — run a normal scope (pilot/all) first"; exit 1; }
    ls "${EMB_DIR}/${LIBRARY}_drugclip_"*.h5 >/dev/null 2>&1 || {
        echo "ERROR: no embeddings in ${EMB_DIR} — run a normal scope first"; exit 1; }
    mkdir -p /shared/logs

    # The analysis is CPU-bound BLAS: give it threads or the GEMMs are the bottleneck.
    PRE="set -e; export PYTHONDONTWRITEBYTECODE=1; export OMP_NUM_THREADS=\${SLURM_CPUS_PER_TASK:-8}"
    if [ "$SCOPE" = "enrich" ]; then
        JOB=drugclip-enrich
        WRAP="${PRE}; $(enrich_cmd); aws s3 sync ${ENR_DIR} ${S3_ENR}/ --no-progress"
    else
        JOB=drugclip-validate
        WRAP="${PRE}; \
            $PY ${SCRIPT_DIR}/score_validation.py --pockets-index ${INPUT_DIR}/pockets_index.csv \
                --targets-base ${TARGETS_BASE} --emb-dir ${EMB_DIR} --library ${LIBRARY} --input-dir ${INPUT_DIR} --out-dir ${VAL_DIR}; \
            $PY ${SCRIPT_DIR}/compare_validation.py --scores-dir ${VAL_DIR} \
                --out ${SUMMARY_CSV}; \
            $(enrich_cmd); \
            aws s3 sync ${VAL_DIR} ${S3_VAL}/ --no-progress; \
            aws s3 cp ${SUMMARY_CSV} ${S3_SUMMARY}; \
            aws s3 sync ${ENR_DIR} ${S3_ENR}/ --no-progress"
    fi

    RS_ID=$(sbatch \
        --partition="$QUEUE" --job-name="$JOB" --nodes=1 --cpus-per-task=8 --time=4:00:00 \
        --output=/shared/logs/${JOB}-%j.out --error=/shared/logs/${JOB}-%j.err \
        --wrap="$WRAP" \
        2>&1 | grep -oP 'Submitted batch job \K\d+')
    [ -n "$RS_ID" ] || { echo "ERROR: ${SCOPE} submission failed"; exit 1; }
    echo "Submitted ${SCOPE} job ${RS_ID} on ${QUEUE} (existing embeddings)."
    echo "  Pockets : ${TARGETS_BASE}"
    echo "  Monitor : squeue -u \$USER | grep ${JOB}"
    echo "  Log     : tail -f /shared/logs/${JOB}-${RS_ID}.out"
    echo "  Result  : ${ENR_DIR}/enrichment_pockets.csv  (+ _targets, _controls, _summary)"
    [ "$SCOPE" = "rescore" ] && echo "            ${SUMMARY_CSV}"
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

# Enrichment only makes sense on the full deck: with scope=pilot the "decoys" would be a
# handful of leaders from one target. (enrichment_validation.py refuses it too.)
ENRICH_STEP=""
if [ "$SCOPE" = "all" ]; then
    ENRICH_STEP="$(enrich_cmd); aws s3 sync ${ENR_DIR} ${S3_ENR}/ --no-progress;"
else
    echo "      (scope=${SCOPE}: enrichment skipped — it needs the full deck)"
fi

SCORE_ID=$(sbatch \
    --partition="$QUEUE" \
    --job-name="drugclip-validate" \
    --nodes=1 \
    --cpus-per-task=8 \
    --time=4:00:00 \
    --dependency=afterok:"${ENCODE_IDS}" \
    --output=/shared/logs/drugclip-validate-%j.out \
    --error=/shared/logs/drugclip-validate-%j.err \
    --wrap="set -e; export PYTHONDONTWRITEBYTECODE=1; \
        export OMP_NUM_THREADS=\${SLURM_CPUS_PER_TASK:-8}; \
        $PY ${SCRIPT_DIR}/score_validation.py --pockets-index ${INPUT_DIR}/pockets_index.csv \
            --targets-base ${TARGETS_BASE} --emb-dir ${EMB_DIR} --library ${LIBRARY} --input-dir ${INPUT_DIR} --out-dir ${VAL_DIR}; \
        $PY ${SCRIPT_DIR}/compare_validation.py --scores-dir ${VAL_DIR} \
            --out ${SUMMARY_CSV}; \
        ${ENRICH_STEP} \
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
if [ "$SCOPE" = "all" ]; then
echo "Enrich  : ${ENR_DIR}/enrichment_pockets.csv  (+ _targets, _controls, _summary)"
echo "          (also pushed to ${S3_ENR}/)"
fi
echo ""
echo "Iterate on the analysis without re-encoding:"
echo "  bash ${BASH_SOURCE[0]} enrich"
echo ""
echo "Then plot locally:"
echo "  aws s3 sync ${S3_VAL}/ ./validation_out/"
echo "  python scripts/drugclip_scripts/validation/plot_validation.py ./validation_out/"
if [ "$SCOPE" = "all" ]; then
echo "  aws s3 sync ${S3_ENR}/ ./enrichment_out/"
echo "  python scripts/drugclip_scripts/validation/plot_enrichment.py ./enrichment_out/"
fi
echo "=========================================="
