#!/bin/bash
# Run enrichment_validation.py against an ARBITRARY pockets index and pocket set.
#
# run-validation.sh hardcodes `--pockets-index ${INPUT_DIR}/pockets_index.csv` with no
# override, and the true-ligand set covers only 157 of 339 pockets.  Rather than swap the
# shared index file (which other runs read), this calls enrichment_validation.py directly
# with an explicit index.
#
# Why a restricted index is required, not just tidier: enrichment_validation.py resolves
# conformations from whatever is in pocket_reps.pkl, but takes each target's actives from
# the index. With the full index a target would get actives from all 339 pockets while being
# scored on only its template ones -- an inflated active set and target-level numbers that
# cannot be compared to the baseline.
#
# Run this TWICE with the SAME index -- once for the baseline pocket set and once for the
# rebuilt one -- and the comparison is exactly like-for-like: same pockets, same
# conformations, same actives, same deck. Only the pocket geometry differs.
#
# Usage:
#   run-enrich-restricted.sh <targets_base> <pockets_index> <tag> [queue]
#
# Examples:
#   run-enrich-restricted.sh /fsx/input/targets \
#       /fsx/input/validation_leaders/pockets_index_ligand.csv tpl_base cpu-queue
#   run-enrich-restricted.sh /fsx/input/targets_ligand \
#       /fsx/input/validation_leaders/pockets_index_ligand.csv tpl_lig  cpu-queue

set -euo pipefail

TARGETS_BASE=${1:-}
POCKETS_INDEX=${2:-}
TAG=${3:-}
QUEUE=${4:-cpu-queue}

if [ -z "$TARGETS_BASE" ] || [ -z "$POCKETS_INDEX" ] || [ -z "$TAG" ]; then
    echo "Usage: $0 <targets_base> <pockets_index> <tag> [queue]"
    exit 1
fi

PY=/shared/python39/bin/python3.9
LIBRARY=validation_leaders
S3_BUCKET=${S3_BUCKET:-ai2050-ersilia-cluster}
INPUT_DIR="/fsx/input/${LIBRARY}"
OUTPUT_DIR="/fsx/output/${LIBRARY}"
EMB_DIR="${OUTPUT_DIR}/drugclip"
ENR_DIR="${OUTPUT_DIR}/enrichment_${TAG}"
S3_ENR="s3://${S3_BUCKET}/output/${LIBRARY}/enrichment_${TAG}"

EF_FRACTIONS="${EF_FRACTIONS:-0.01,0.05,0.10}"
BEDROC_ALPHAS="${BEDROC_ALPHAS:-20,80.5}"
N_SHUFFLES="${N_SHUFFLES:-5}"
CENTER_FLAG=""
[ "${CENTER_MOLECULES:-0}" != "0" ] && CENTER_FLAG="--center-molecules"

# Never write over the untagged production results.
if [ "$TAG" = "" ] || [ "$ENR_DIR" = "${OUTPUT_DIR}/enrichment" ]; then
    echo "ERROR: refusing to write to the untagged enrichment dir"
    exit 1
fi

for f in "$POCKETS_INDEX" ; do
    [ -f "$f" ] || { echo "ERROR: not found: $f"; exit 1; }
done
[ -d "$TARGETS_BASE" ] || { echo "ERROR: targets base not found: $TARGETS_BASE"; exit 1; }
ls "${EMB_DIR}/${LIBRARY}_drugclip_"*.h5 >/dev/null 2>&1 || {
    echo "ERROR: no molecule embeddings in ${EMB_DIR}"; exit 1; }

N_ROWS=$(( $(wc -l < "$POCKETS_INDEX") - 1 ))
N_POCKETS=$(tail -n +2 "$POCKETS_INDEX" | cut -d, -f1 | sort -u | wc -l)
N_TARGETS=$(tail -n +2 "$POCKETS_INDEX" | cut -d, -f2 | sort -u | wc -l)

echo "=========================================="
echo "Enrichment on a restricted index"
echo "=========================================="
echo "Pocket set : $TARGETS_BASE"
echo "Index      : $POCKETS_INDEX"
echo "             ${N_ROWS} conformations, ${N_POCKETS} pockets, ${N_TARGETS} targets"
echo "Out        : $ENR_DIR"
echo "Queue      : $QUEUE"
echo "=========================================="

mkdir -p /shared/logs

# CPU-bound BLAS: give it threads or the GEMMs dominate.
JOB="enrich-${TAG}"
JOB_ID=$(sbatch \
    --partition="$QUEUE" --job-name="$JOB" --nodes=1 --cpus-per-task=8 --time=4:00:00 \
    --output=/shared/logs/${JOB}-%j.out --error=/shared/logs/${JOB}-%j.err \
    --wrap="set -e; export PYTHONDONTWRITEBYTECODE=1; \
        export OMP_NUM_THREADS=\${SLURM_CPUS_PER_TASK:-8}; \
        $PY /shared/scripts/drugclip_scripts/validation/enrichment_validation.py \
            --pockets-index ${POCKETS_INDEX} \
            --targets-base ${TARGETS_BASE} \
            --emb-dir ${EMB_DIR} --library ${LIBRARY} --input-dir ${INPUT_DIR} \
            --out-dir ${ENR_DIR} \
            --ef-fractions ${EF_FRACTIONS} --bedroc-alphas ${BEDROC_ALPHAS} \
            --n-shuffles ${N_SHUFFLES} --dump-npz ${CENTER_FLAG}; \
        aws s3 sync ${ENR_DIR} ${S3_ENR}/ --no-progress" \
    2>&1 | grep -oP 'Submitted batch job \K\d+')

[ -n "$JOB_ID" ] || { echo "ERROR: submission failed"; exit 1; }

echo ""
echo "Submitted job $JOB_ID"
echo "  Monitor : squeue -u \$USER | grep ${JOB}"
echo "  Log     : tail -f /shared/logs/${JOB}-${JOB_ID}.out"
echo "  Result  : ${ENR_DIR}/enrichment_pockets.csv"
echo "  S3      : ${S3_ENR}/"
echo "=========================================="
