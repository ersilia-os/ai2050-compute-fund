#!/bin/bash
#SBATCH --job-name=unidock-batches
#SBATCH --partition=gpu-queue
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=24:00:00
#SBATCH --output=/shared/logs/unidock-batches-%A_%a.out
#SBATCH --error=/shared/logs/unidock-batches-%A_%a.err
#
# Batched production docking (milestone 4a). Array task T docks batch ids
# (T-1)*K+1 .. T*K of <dock_dir>/batches.csv, with prep, ligandprep and Uni-Dock on
# node-local disk. Each finished batch is 3 files in <dock_dir>/batches/; see
# dock_batches.py for the layout and why.
#
# --exclusive is not optional: gpu-queue mixes g6e (L40S 48 GB), g6 (L4 24 GB) and g4dn
# (T4 16 GB) behind one `gpu:l40s:1` label, and co-scheduled tasks would share one GPU
# (2026-10-06: twelve jobs died that way). It also gives the 3D prep every CPU.
#
# Usage (AL2023 head node):
#   N=$(( ( $(tail -n +2 <dock_dir>/batches.csv | wc -l) + K - 1 ) / K ))
#   sbatch --array=1-${N}%4 run-docking-batches.sh <dock_dir> <K>
#
# Resumable: finished batches (scores.csv present) are skipped, so resubmitting the same
# array, or only the task ids check-docking.sh lists, redoes only the missing batches.
# K must stay the same for a given <dock_dir>; dock_batches.py refuses a different value.
#
# Environment overrides: SIF_FILE, SCRIPTS_DIR, SEED, NUM_MODES, LIGAND_INPUT
# (index | gpu_batch), LOCAL_DIR.

set -euo pipefail

DOCK_DIR=${1:-}
K=${2:-}
SIF_FILE=${SIF_FILE:-/shared/sif-files/unidock.sif}
SCRIPTS_DIR=${SCRIPTS_DIR:-/shared/scripts/docking_scripts}
SEED=${SEED:-42}
NUM_MODES=${NUM_MODES:-5}
LIGAND_INPUT=${LIGAND_INPUT:-index}
LOCAL_DIR=${LOCAL_DIR:-${SLURM_TMPDIR:-/tmp}}

if [ -z "$DOCK_DIR" ] || [ -z "$K" ]; then
    echo "ERROR: usage: sbatch --array=1-N%4 $0 <dock_dir> <batches_per_task>"
    exit 1
fi
for f in "$DOCK_DIR/docking_manifest.csv" "$DOCK_DIR/batches.csv" "$SIF_FILE" \
         "$SCRIPTS_DIR/dock_batches.py"; do
    [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done
if ! nvidia-smi &>/dev/null; then
    echo "ERROR: no GPU on $(hostname) - docking is GPU-only"
    exit 1
fi

TASK=${SLURM_ARRAY_TASK_ID:-1}
echo "=========================================="
echo "Uni-Dock batches  task ${TASK}  (K=${K})"
echo "  dock dir : $DOCK_DIR"
echo "  node     : $(hostname)   CPUs: $(nproc)"
echo "  GPU      : $(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | head -1)"
echo "  local    : $LOCAL_DIR   free: $(df -h "$LOCAL_DIR" | awk 'NR==2{print $4}')"
echo "  image    : $SIF_FILE"
echo "  started  : $(date -Is)"
echo "=========================================="

rc=0
apptainer -q exec --nv \
    --bind /fsx:/fsx --bind /shared:/shared --bind "$LOCAL_DIR:$LOCAL_DIR" \
    "$SIF_FILE" python "$SCRIPTS_DIR/dock_batches.py" \
        --dock-dir "$DOCK_DIR" --task-id "$TASK" --per-task "$K" \
        --local-dir "$LOCAL_DIR" --seed "$SEED" --num-modes "$NUM_MODES" \
        --ligand-input "$LIGAND_INPUT" || rc=$?
echo "finished : $(date -Is)  exit $rc"
exit $rc
