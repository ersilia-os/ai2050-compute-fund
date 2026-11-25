#!/bin/bash
#SBATCH --job-name=unidock-dock
#SBATCH --partition=gpu-queue
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=24:00:00
#SBATCH --output=/shared/logs/unidock-dock-%A_%a.out
#SBATCH --error=/shared/logs/unidock-dock-%A_%a.err
#
# Production docking, one array task per pocket. Expects prep-ligands-array.sh to have run.
#
# --exclusive is not optional. gpu-queue mixes g6e (L40S 48 GB), g6 (L4 24 GB) and g4dn
# (T4 16 GB) behind a single `gpu:l40s:1` label, and AWS picks by capacity, so the label
# tells you nothing about what you got. Without --exclusive, co-scheduled tasks share one
# GPU: on 2026-10-06 ten pocket-encoders landed on one T4 and all twelve jobs died.
#
# Settings (decisions 2026-10-01/02, see README):
#   --scoring vina          --search_mode balance (exhaustiveness 384, max_step 40)
#   box = reference-ligand extent + 6 A per side, taken from docking_manifest.csv so it
#         matches the DrugCLIP pocket radius; both methods then look at the same region
#   --seed passed explicitly; Uni-Dock's search is stochastic
#
# Ligands are submitted in chunks: Uni-Dock prefers >=1000 per batch, and a glob of every
# SDF would blow past ARG_MAX on the larger pockets (O75469 has 18,423).
#
# Usage:
#   sbatch --array=1-<N>%<concurrent> run-docking-array.sh <docking_dir>
#
# Resumable: a pocket whose output directory already holds *_out.sdf is skipped.

set -euo pipefail

DOCK_DIR=${1:-}
SIF_FILE=${SIF_FILE:-/shared/sif-files/unidock.sif}
SCRIPTS_DIR=${SCRIPTS_DIR:-/shared/scripts/docking_scripts}
PY=${PY:-/shared/python39/bin/python3.9}
SEED=${SEED:-42}
SCORING=${SCORING:-vina}
SEARCH_MODE=${SEARCH_MODE:-balance}
NUM_MODES=${NUM_MODES:-9}
CHUNK=${CHUNK:-1000}

if [ -z "$DOCK_DIR" ]; then
    echo "ERROR: usage: sbatch --array=1-N $0 <docking_dir>"
    exit 1
fi
MANIFEST="${DOCK_DIR}/docking_manifest.csv"
[ -f "$MANIFEST" ] || { echo "ERROR: no $MANIFEST"; exit 1; }
[ -f "$SIF_FILE" ] || { echo "ERROR: no $SIF_FILE"; exit 1; }

IDX=${SLURM_ARRAY_TASK_ID:-1}

read -r UNIPROT SETNAME DOMAIN POCKET NLIG RECEPTOR HAS_H CX CY CZ SX SY SZ < <(
    "$PY" - "$MANIFEST" "$IDX" <<'PYEOF'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
i = int(sys.argv[2]) - 1
if i < 0 or i >= len(rows):
    sys.exit(f"ERROR: array index {i+1} out of range (1..{len(rows)})")
r = rows[i]
print(r["uniprot"], r["set_name"], r["domain"], r["pocket"], r["n_ligands"],
      r["receptor"], r["receptor_has_h"],
      r["center_x"], r["center_y"], r["center_z"],
      r["size_x"], r["size_y"], r["size_z"])
PYEOF
)

TAG="${UNIPROT}_d${DOMAIN}_${POCKET}"
PREP="${DOCK_DIR}/prepared/${TAG}"
LIGPREP="${PREP}/ligprep"
OUT="${DOCK_DIR}/poses/${TAG}"

echo "=========================================="
echo "Uni-Dock  task ${IDX}  ${TAG}"
echo "  set        : $SETNAME    ligands: $NLIG"
echo "  receptor   : $RECEPTOR"
echo "  has H      : $HAS_H"
echo "  box centre : $CX $CY $CZ"
echo "  box size   : $SX $SY $SZ"
echo "  scoring    : $SCORING   search_mode: $SEARCH_MODE   seed: $SEED"
echo "  node       : $(hostname)"
echo "=========================================="

if [ "$HAS_H" != "yes" ]; then
    # targets_mtb pockets are built from raw AlphaFold models. proteinprep types and
    # charges existing hydrogens; it does NOT add them. Decision 2026-10-06 was to run
    # these as-is and inspect, so this warns rather than stops.
    echo ""
    echo "WARN: receptor protonation is '$HAS_H'. proteinprep does not add hydrogens;"
    echo "      scores for this pocket are provisional until the output is inspected."
fi

if ls "${OUT}"/*_out.sdf >/dev/null 2>&1; then
    echo "Already docked ($(ls -1 "${OUT}"/*_out.sdf | wc -l) pose files) - skipping"
    exit 0
fi

N_SDF=$(ls -1 "$LIGPREP"/*.sdf 2>/dev/null | wc -l)
if [ "$N_SDF" -eq 0 ]; then
    echo "ERROR: no prepared ligands in $LIGPREP - run prep-ligands-array.sh first"
    exit 1
fi
[ -f "$RECEPTOR" ] || { echo "ERROR: receptor not found: $RECEPTOR"; exit 1; }

if ! nvidia-smi &>/dev/null; then
    echo "ERROR: no GPU on $(hostname) - docking is GPU-only here"
    exit 1
fi
echo ""
echo "GPU: $(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | head -1)"

mkdir -p "$OUT"
cd "$OUT"

run() {
    apptainer -q exec --nv --bind /fsx:/fsx --bind /shared:/shared "$SIF_FILE" "$@"
}

echo ""
echo "Receptor: unidocktools proteinprep ..."
grep -E '^(ATOM|TER|END)' "$RECEPTOR" > receptor.pdb
N_H=$(awk '/^ATOM/ && substr($0,77,2) ~ /H/' receptor.pdb | wc -l)
echo "  $(grep -c '^ATOM' receptor.pdb) atoms, $N_H hydrogens"
if [ "$N_H" -eq 0 ]; then
    echo "  NOTE zero hydrogens in the receptor - see the WARN above"
fi
run unidocktools proteinprep -r receptor.pdb -o receptor.pdbqt
[ -s receptor.pdbqt ] || { echo "ERROR: proteinprep wrote no receptor.pdbqt"; exit 1; }

echo ""
echo "Docking $N_SDF ligands in chunks of $CHUNK ..."
ls -1 "$LIGPREP"/*.sdf | sort > all_ligands.txt
split -l "$CHUNK" -d -a 4 all_ligands.txt chunk_

N_CHUNK=$(ls -1 chunk_* | wc -l)
t_all0=$(date +%s)
n=0
for CF in chunk_*; do
    n=$((n + 1))
    mkdir -p "batch_${CF}"
    t0=$(date +%s)
    # shellcheck disable=SC2046,SC2086
    run unidock \
        --receptor receptor.pdbqt \
        --gpu_batch $(cat "$CF" | tr '\n' ' ') \
        --scoring "$SCORING" \
        --search_mode "$SEARCH_MODE" \
        --seed "$SEED" \
        --center_x "$CX" --center_y "$CY" --center_z "$CZ" \
        --size_x "$SX" --size_y "$SY" --size_z "$SZ" \
        --num_modes "$NUM_MODES" \
        --dir "batch_${CF}" > "batch_${CF}/unidock.log" 2>&1
    t1=$(date +%s)
    N_POSE=$(ls -1 "batch_${CF}"/*_out.sdf 2>/dev/null | wc -l)
    echo "  chunk ${n}/${N_CHUNK}: $(wc -l < "$CF") ligands -> $N_POSE poses in $((t1 - t0)) s"
done
t_all1=$(date +%s)

# Flatten so downstream sees one directory of poses per pocket.
mv batch_chunk_*/*_out.sdf . 2>/dev/null || true
N_OUT=$(ls -1 ./*_out.sdf 2>/dev/null | wc -l)

echo ""
echo "=========================================="
echo "${TAG}: $N_OUT of $N_SDF ligands docked in $((t_all1 - t_all0)) s"
if [ "$N_OUT" -lt "$N_SDF" ]; then
    echo "WARN: $(( N_SDF - N_OUT )) ligand(s) produced no pose - check batch_*/unidock.log"
fi
echo "Output: $OUT"
echo "=========================================="
