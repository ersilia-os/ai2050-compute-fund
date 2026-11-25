#!/bin/bash
#SBATCH --job-name=unidock-test
#SBATCH --partition=gpu-queue
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=01:00:00
#SBATCH --output=/shared/logs/unidock-test-%j.out
#SBATCH --error=/shared/logs/unidock-test-%j.err

# Smoke test for unidock.sif on the AL2023 gpu-queue. RUN CHECK ONLY: nothing here
# feeds an analysis.
#
# Re-docks one targets_ligand pocket's recovered ligand into its own receptor through
# the full prep chain, twice with the same seed, and reports:
#   1. which GPU the node got (gpu-queue mixes T4 / L4 / L40S behind one label)
#   2. whether every prep step and Uni-Dock run on it
#   3. whether a fixed --seed gives identical results across the two runs
#   4. wall-clock per docking run
#   5. each pose's RMSD to the reference ligand pose (reported only; no pass/fail cutoff
#      has been set)
#
# Prep chain (the same one the real runs will use):
#   receptor  refined PDB (has H) -> unidocktools proteinprep -> receptor.pdbqt
#   ligand    SMILES -> prepare_ligands.py (neutralised, no pH model; RDKit
#             ETKDGv3 + MMFF94) -> unidocktools ligandprep -> torsion-tree SDF
#   box       compute_box.py: reference-ligand extent + 6 A per side
#
# For this test the SMILES comes from the reference ligand itself: openbabel perceives
# bond orders from the HETATM coordinates. Leaders will arrive as SMILES directly.
#
# Caveat on (5): the reference pose is a crystal ligand transposed onto the AlphaFold
# conformer by cealign (see that pocket's align_rmsd in manifest.csv), not a native
# pose in this receptor. The RMSD therefore mixes docking error with transposition error.
#
# Usage:
#   sbatch test-unidock.sh <pocket _LIG.pdb> <receptor *_complex_refined.pdb>
#
#   <pocket _LIG.pdb>         targets_ligand pocket: protein ATOM + HETATM ... LIG L 1
#   <receptor refined .pdb>   the same conformer's *_complex_refined.pdb (full protein
#                             with hydrogens), named in that pocket's manifest.csv
#                             column source_refined_pdb
#
# Settings: scoring vina, search_mode balance. SEED (default 42) drives both the ETKDG
# embedding and Uni-Dock; override with `sbatch --export=ALL,SEED=7 ...`.
#
# Output: /fsx/output/docking/unidock_test/<job id>/

set -euo pipefail

LIG_PDB=${1:-}
RECEPTOR_PDB=${2:-}

if [ -z "$LIG_PDB" ] || [ -z "$RECEPTOR_PDB" ]; then
    echo "ERROR: Usage: sbatch test-unidock.sh <pocket _LIG.pdb> <receptor *_complex_refined.pdb>"
    exit 1
fi

SIF_FILE="/shared/sif-files/unidock.sif"
SCRIPTS_DIR="/shared/scripts/docking_scripts"
SEED=${SEED:-42}
SCORING="vina"
SEARCH_MODE="balance"
LIG_NAME="native"
OUT_DIR="/fsx/output/docking/unidock_test/${SLURM_JOB_ID}"

echo "=========================================="
echo "Uni-Dock smoke test"
echo "=========================================="
echo "Job ID     : $SLURM_JOB_ID"
echo "Node       : $(hostname)"
echo "Date       : $(date)"
echo "Pocket     : $LIG_PDB"
echo "Receptor   : $RECEPTOR_PDB"
echo "Scoring    : $SCORING   search_mode: $SEARCH_MODE   seed: $SEED"
echo "Output     : $OUT_DIR"
echo "=========================================="

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if [ ! -f "$SIF_FILE" ]; then
    echo "ERROR: SIF not found: $SIF_FILE"
    echo "  Run: aws s3 cp s3://ai2050-ersilia-cluster/sif-files/unidock.sif $SIF_FILE"
    exit 1
fi
for f in "$LIG_PDB" "$RECEPTOR_PDB" \
         "$SCRIPTS_DIR/prepare_ligands.py" "$SCRIPTS_DIR/compute_box.py" "$SCRIPTS_DIR/pose_rmsd.py"; do
    [ -f "$f" ] || { echo "ERROR: not found: $f"; exit 1; }
done

# ── GPU (docking is GPU-only; no CPU fallback) ────────────────────────────────
if ! nvidia-smi &>/dev/null; then
    echo "ERROR: no GPU visible on $(hostname)"
    exit 1
fi
echo ""
echo "GPU: $(nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader | head -1)"

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

run() {
    apptainer -q exec --nv \
        --bind /fsx:/fsx \
        --bind /shared:/shared \
        "$SIF_FILE" "$@"
}

echo "Uni-Dock: $(run unidock --version 2>&1 | head -1)"

# ── Receptor: refined protein (keeps its hydrogens) → PDBQT ───────────────────
# proteinprep does not add hydrogens; it types and charges the ones already there.
echo ""
echo "Receptor: unidocktools proteinprep ..."
grep -E '^(ATOM|TER|END)' "$RECEPTOR_PDB" > receptor.pdb
echo "  $(grep -c '^ATOM' receptor.pdb) atoms, $(awk '/^ATOM/ && substr($0,77,2) ~ /H/' receptor.pdb | wc -l) hydrogens"
run unidocktools proteinprep -r receptor.pdb -o receptor.pdbqt
[ -s receptor.pdbqt ] || { echo "ERROR: proteinprep wrote no receptor.pdbqt"; exit 1; }
echo "  receptor.pdbqt: $(wc -l < receptor.pdbqt) atoms"

# ── Ligand ────────────────────────────────────────────────────────────────────
echo ""
echo "Ligand ..."
grep -E '^HETATM.{11}LIG' "$LIG_PDB" > ligand_ref.pdb
SMILES=$(run obabel ligand_ref.pdb -osmi 2>/dev/null | awk 'NR==1{print $1}')
[ -n "$SMILES" ] || { echo "ERROR: obabel could not perceive a SMILES from $LIG_PDB"; exit 1; }
echo "  perceived SMILES: $SMILES"

run python "$SCRIPTS_DIR/prepare_ligands.py" \
    --smiles "$SMILES" --name "$LIG_NAME" --seed "$SEED" --out ligand_3d.sdf
[ -s ligand_3d.sdf ] || { echo "ERROR: prepare_ligands.py produced no molecule (see ligand_3d.sdf.failed.csv)"; exit 1; }

echo "  unidocktools ligandprep ..."
run unidocktools ligandprep -l ligand_3d.sdf -sd ligprep -sf sdf
LIGAND_SDF="ligprep/${LIG_NAME}.sdf"
[ -s "$LIGAND_SDF" ] || { echo "ERROR: ligandprep wrote no $LIGAND_SDF"; exit 1; }

# ── Box ───────────────────────────────────────────────────────────────────────
BOX=$(run python "$SCRIPTS_DIR/compute_box.py" "$LIG_PDB")
echo ""
echo "Box flags: $BOX"

# ── Dock twice with the same seed ─────────────────────────────────────────────
for rep in 1 2; do
    echo ""
    echo "Docking run $rep ..."
    mkdir -p "run${rep}"
    t0=$(date +%s.%N)
    # shellcheck disable=SC2086
    run unidock \
        --receptor receptor.pdbqt \
        --gpu_batch "$LIGAND_SDF" \
        --scoring "$SCORING" \
        --search_mode "$SEARCH_MODE" \
        --seed "$SEED" \
        $BOX \
        --num_modes 9 \
        --dir "run${rep}" > "run${rep}/unidock.log" 2>&1
    t1=$(date +%s.%N)
    echo "  wall-clock: $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f s", b-a}')"
done

POSES1=$(ls run1/*_out.sdf 2>/dev/null | head -1 || true)
POSES2=$(ls run2/*_out.sdf 2>/dev/null | head -1 || true)
if [ -z "$POSES1" ] || [ -z "$POSES2" ]; then
    echo "ERROR: Uni-Dock wrote no poses — see run1/unidock.log, run2/unidock.log"
    exit 1
fi

# ── Scores and seed reproducibility ───────────────────────────────────────────
echo ""
echo "Vina scores, run 1 (kcal/mol; RMSD lb/ub are to the top pose):"
run python - "$POSES1" << 'PYEOF'
import sys
from rdkit import Chem, RDLogger
RDLogger.DisableLog("rdApp.*")
for i, m in enumerate(Chem.SDMolSupplier(sys.argv[1], removeHs=False, sanitize=False), 1):
    if m is None or not m.HasProp("Uni-Dock RESULT"):
        print(f"  pose {i}: no Uni-Dock RESULT"); continue
    print(f"  pose {i}: {m.GetProp('Uni-Dock RESULT').splitlines()[0].strip()}")
PYEOF

if diff -q "$POSES1" "$POSES2" >/dev/null; then
    REPRO="IDENTICAL"
else
    REPRO="DIFFERENT (diff run1 vs run2 to see where)"
fi
echo "Seed reproducibility (run 1 vs run 2): $REPRO"

# ── RMSD of each pose to the reference pose ───────────────────────────────────
echo ""
echo "RMSD to reference pose (heavy atoms, symmetry-aware, no superposition):"
run python "$SCRIPTS_DIR/pose_rmsd.py" ligand_ref.pdb "$POSES1"

echo ""
echo "=========================================="
echo "Done: $(date)"
echo "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)  |  reproducibility: $REPRO"
echo "Files: $OUT_DIR"
echo "=========================================="
