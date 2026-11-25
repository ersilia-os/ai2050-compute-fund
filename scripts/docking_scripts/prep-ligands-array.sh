#!/bin/bash
#SBATCH --job-name=unidock-prep
#SBATCH --partition=cpu-queue
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=12:00:00
#SBATCH --output=/shared/logs/unidock-prep-%A_%a.out
#SBATCH --error=/shared/logs/unidock-prep-%A_%a.err
#
# Ligand preparation for the production screen, one array task per pocket.
#
# CPU, not GPU, and that is the point: RDKit ETKDGv3 embedding + MMFF94 for ~460k
# molecules is hours of cheminformatics. Doing it inside the docking job would hold a GPU
# idle for most of that. Prep once here, dock on gpu-queue afterwards.
#
# --exclusive because cpu-queue is CR_CPU: Slurm does no memory accounting there, so
# co-scheduled tasks overpack the node until one is OOM-killed.
#
# Chain (settings fixed 2026-10-01/02, see README):
#   SMILES -> prepare_ligands.py  neutralise (RDKit Uncharger, NO pH model), AddHs,
#                                 ETKDGv3 (seeded), MMFF94            -> one SDF
#          -> unidocktools ligandprep  torsion tree, atom types, charges -> per-mol SDFs
#
# Multi-fragment SMILES (salts, mixtures) are NOT stripped; they land in
# <out>.failed.csv and are simply absent downstream. Check those counts.
#
# Usage:
#   sbatch --array=1-<N> prep-ligands-array.sh <docking_dir>
#     where <N> = data rows in <docking_dir>/docking_manifest.csv
#
# Resumable: a pocket whose ligprep directory already holds SDFs is skipped, so a
# requeued or extended array does not redo work.

set -euo pipefail

DOCK_DIR=${1:-}
SIF_FILE=${SIF_FILE:-/shared/sif-files/unidock.sif}
SCRIPTS_DIR=${SCRIPTS_DIR:-/shared/scripts/docking_scripts}
PY=${PY:-/shared/python39/bin/python3.9}
SEED=${SEED:-42}

if [ -z "$DOCK_DIR" ]; then
    echo "ERROR: usage: sbatch --array=1-N $0 <docking_dir>"
    exit 1
fi
MANIFEST="${DOCK_DIR}/docking_manifest.csv"
[ -f "$MANIFEST" ] || { echo "ERROR: no $MANIFEST"; exit 1; }
[ -f "$SIF_FILE" ] || { echo "ERROR: no $SIF_FILE"; exit 1; }

IDX=${SLURM_ARRAY_TASK_ID:-1}

# Pull this task's row by header name, not column number, so a manifest change does not
# silently shift fields.
read -r UNIPROT SETNAME DOMAIN POCKET NLIG LIGFILE < <(
    "$PY" - "$MANIFEST" "$IDX" <<'PYEOF'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
i = int(sys.argv[2]) - 1
if i < 0 or i >= len(rows):
    sys.exit(f"ERROR: array index {i+1} out of range (1..{len(rows)})")
r = rows[i]
print(r["uniprot"], r["set_name"], r["domain"], r["pocket"],
      r["n_ligands"], r["ligand_file"])
PYEOF
)

TAG="${UNIPROT}_d${DOMAIN}_${POCKET}"
OUT="${DOCK_DIR}/prepared/${TAG}"
LIGPREP="${OUT}/ligprep"

echo "=========================================="
echo "Ligand prep  task ${IDX}  ${TAG}"
echo "  set        : $SETNAME"
echo "  ligands    : $NLIG"
echo "  input      : $LIGFILE"
echo "  out        : $OUT"
echo "  seed       : $SEED   (drives ETKDG; record it)"
echo "  node       : $(hostname)  CPUs: $(nproc)"
echo "=========================================="

if [ -d "$LIGPREP" ] && [ "$(ls -1 "$LIGPREP"/*.sdf 2>/dev/null | wc -l)" -gt 0 ]; then
    echo "Already prepared ($(ls -1 "$LIGPREP"/*.sdf | wc -l) SDFs) - skipping"
    exit 0
fi

[ -f "$LIGFILE" ] || { echo "ERROR: ligand file missing: $LIGFILE"; exit 1; }
mkdir -p "$OUT"

run() {
    apptainer -q exec --bind /fsx:/fsx --bind /shared:/shared "$SIF_FILE" "$@"
}

echo ""
echo "prepare_ligands.py ..."
t0=$(date +%s)
run python "${SCRIPTS_DIR}/prepare_ligands.py" \
    --input "$LIGFILE" --out "${OUT}/ligands_3d.sdf" --seed "$SEED"
t1=$(date +%s)
echo "  $((t1 - t0)) s"

if [ ! -s "${OUT}/ligands_3d.sdf" ]; then
    echo "ERROR: prepare_ligands.py produced nothing - see ${OUT}/ligands_3d.sdf.failed.csv"
    exit 1
fi
N_OK=$(grep -c '^\$\$\$\$' "${OUT}/ligands_3d.sdf" || true)
N_FAIL=0
[ -f "${OUT}/ligands_3d.sdf.failed.csv" ] && \
    N_FAIL=$(( $(wc -l < "${OUT}/ligands_3d.sdf.failed.csv") - 1 ))
echo "  embedded $N_OK of $NLIG   (failed: $N_FAIL)"

echo ""
echo "unidocktools ligandprep ..."
mkdir -p "$LIGPREP"
t0=$(date +%s)
run unidocktools ligandprep -l "${OUT}/ligands_3d.sdf" -sd "$LIGPREP" -sf sdf
t1=$(date +%s)
N_SDF=$(ls -1 "$LIGPREP"/*.sdf 2>/dev/null | wc -l)
echo "  $((t1 - t0)) s   ->  $N_SDF prepared SDFs"

if [ "$N_SDF" -eq 0 ]; then
    echo "ERROR: ligandprep wrote no SDFs"
    exit 1
fi

echo ""
echo "Done ${TAG}: $N_SDF ligands ready for docking"
