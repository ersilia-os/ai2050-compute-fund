#!/bin/bash
#SBATCH --job-name=unidock-timing
#SBATCH --partition=gpu-queue
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=/shared/logs/unidock-timing-%j.out
#SBATCH --error=/shared/logs/unidock-timing-%j.err
#
# Measure Uni-Dock throughput on one pocket. MEASUREMENT ONLY -- nothing here feeds an
# analysis, and the poses are discarded with the node.
#
# Why: the whole docking schedule rests on one number, ~1,000 ligands / ~450 s per T4
# (~8k/h/GPU), measured once in October at NUM_MODES=9. Production will run at 5 poses,
# and gpu-queue hands out T4 / L4 / L40S behind a single `gpu:l40s:1` label, so the figure
# may be wrong in either direction. This re-measures it before the December pilot.
#
# It reports BOTH pose counts so the October number stays comparable:
#   chunk 1 at NUM_MODES=9  -> like-for-like with the October measurement
#   chunks 2-3 at NUM_MODES=5 -> the production setting
#
# Poses are written to NODE-LOCAL disk, not FSx. That keeps the inode cost at zero (FSx has
# ~3.0M free against a 39M requirement for full-library docking) and incidentally tests the
# node-local write path that milestone 4a depends on. Only the timing summary reaches FSx.
#
# Usage:
#   sbatch time-docking.sh [pocket_tag] [n_chunks] [chunk_size]
# Defaults: P00533_d1_1 (EGFR; median box 7,898 A^3, H-bearing receptor), 3 chunks of 1000.

set -euo pipefail

TAG=${1:-P00533_d1_1}
N_CHUNKS=${2:-3}
CHUNK=${3:-1000}
D=${DOCK_DIR:-/fsx/output/Enamine_Hit_Locator_460K/docking}
SIF_FILE=${SIF_FILE:-/shared/sif-files/unidock.sif}
SEED=${SEED:-42}
SUMMARY_DIR=/fsx/output/docking_timing
LOCAL=${SLURM_TMPDIR:-/tmp}/unidock_timing_${SLURM_JOB_ID:-$$}

MAN="$D/docking_manifest.csv"
LIGPREP="$D/prepared/$TAG/ligprep"
[ -f "$MAN" ] || { echo "ERROR: no $MAN"; exit 1; }
[ -d "$LIGPREP" ] || { echo "ERROR: no prepared ligands at $LIGPREP"; exit 1; }
[ -f "$SIF_FILE" ] || { echo "ERROR: no $SIF_FILE"; exit 1; }
nvidia-smi &>/dev/null || { echo "ERROR: no GPU on $(hostname)"; exit 1; }

GPU=$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader | head -1)
echo "=========================================="
echo "Uni-Dock throughput measurement"
echo "=========================================="
echo "Pocket   : $TAG"
echo "Node     : $(hostname)"
echo "GPU      : $GPU"
echo "Local    : $LOCAL"
echo "Chunks   : $N_CHUNKS x $CHUNK ligands"
echo "Seed     : $SEED"
echo "=========================================="
echo "NOTE gpu-queue mixes T4 / L4 / L40S behind one label. The October baseline"
echo "     (~1000 ligands / ~450 s) was a T4 -- compare only against the same GPU."
echo ""

# Pull this pocket's box + receptor from the manifest by header name.
read -r RECEPTOR CX CY CZ SX SY SZ < <(
  /shared/python39/bin/python3.9 -c '
import csv, sys
tag = sys.argv[1]
for r in csv.DictReader(open(sys.argv[2])):
    if "%s_d%s_%s" % (r["uniprot"], r["domain"], r["pocket"]) == tag:
        print(r["receptor"], r["center_x"], r["center_y"], r["center_z"],
              r["size_x"], r["size_y"], r["size_z"])
        break
else:
    sys.exit("pocket %s not in manifest" % tag)' "$TAG" "$MAN")

echo "Receptor : $RECEPTOR"
echo "Box      : centre $CX $CY $CZ   size $SX $SY $SZ"
echo ""

mkdir -p "$LOCAL" "$SUMMARY_DIR"
cd "$LOCAL"
run() { apptainer -q exec --nv --bind /fsx:/fsx --bind /shared:/shared \
          --bind "$LOCAL:$LOCAL" "$SIF_FILE" "$@"; }

t0=$(date +%s)
grep -E '^(ATOM|TER|END)' "$RECEPTOR" > receptor.pdb
run unidocktools proteinprep -r receptor.pdb -o receptor.pdbqt
t1=$(date +%s)
[ -s receptor.pdbqt ] || { echo "ERROR: proteinprep produced nothing"; exit 1; }
echo "proteinprep: $((t1 - t0)) s  (per-pocket overhead, paid once)"
echo ""

# NOT `ls | sort | head`: head closes the pipe once it has enough lines, sort takes
# SIGPIPE, and `set -o pipefail` + `set -e` kill the script silently (job 1317).
ls -1 "$LIGPREP"/*.sdf | sort > all_ligands.txt
head -n $((N_CHUNKS * CHUNK)) all_ligands.txt > all.txt
split -l "$CHUNK" -d -a 3 all.txt chunk_

SUMMARY="$SUMMARY_DIR/timing_${SLURM_JOB_ID:-manual}_${TAG}.csv"
echo "chunk,num_modes,n_ligands,seconds,ligands_per_sec,n_poses" > "$SUMMARY"

i=0
for CF in chunk_*; do
    i=$((i + 1))
    [ "$i" -gt "$N_CHUNKS" ] && break
    # chunk 1 reproduces the October setting; the rest use the production value
    if [ "$i" -eq 1 ]; then NM=9; else NM=5; fi
    N=$(wc -l < "$CF")
    OUT="$LOCAL/out_${CF}"; mkdir -p "$OUT"
    s0=$(date +%s)
    run unidock --receptor receptor.pdbqt \
        --gpu_batch $(cat "$CF" | tr '\n' ' ') \
        --scoring vina --search_mode balance --seed "$SEED" \
        --center_x "$CX" --center_y "$CY" --center_z "$CZ" \
        --size_x "$SX" --size_y "$SY" --size_z "$SZ" \
        --num_modes "$NM" --dir "$OUT" > "$OUT/unidock.log" 2>&1 || true
    s1=$(date +%s)
    SEC=$((s1 - s0)); [ "$SEC" -eq 0 ] && SEC=1
    NP=$(ls -1 "$OUT"/*_out.sdf 2>/dev/null | wc -l)
    RATE=$(awk -v n="$N" -v s="$SEC" 'BEGIN{printf "%.2f", n/s}')
    printf "chunk %d: num_modes=%d  %5d ligands  %5d s  %6s lig/s  %5d poses\n" \
           "$i" "$NM" "$N" "$SEC" "$RATE" "$NP"
    echo "$i,$NM,$N,$SEC,$RATE,$NP" >> "$SUMMARY"
done

echo ""
echo "=========================================="
/shared/python39/bin/python3.9 -c '
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
p5 = [r for r in rows if r["num_modes"] == "5"]
p9 = [r for r in rows if r["num_modes"] == "9"]
def rate(rs):
    n = sum(int(r["n_ligands"]) for r in rs); s = sum(int(r["seconds"]) for r in rs)
    return (n / s) if s else 0.0
for label, rs in (("num_modes=9 (October setting)", p9), ("num_modes=5 (production)", p5)):
    if not rs: continue
    r = rate(rs)
    print("%-32s %6.2f lig/s = %7.0f /h/GPU = %8.0f /h on 4 GPUs" % (label, r, r*3600, r*3600*4))
if p5:
    r = rate(p5) * 3600 * 4
    tot = 19400000
    print("")
    print("All 5 libraries (~19.4M ligands) on 4 GPUs: %.1f days" % (tot / r / 24))
    print("October assumption was 32,000/h on 4 GPUs = 25 days")
' "$SUMMARY"
echo "=========================================="
echo "Summary: $SUMMARY"
echo "Poses were written to node-local disk and are discarded with the node (0 FSx inodes)."
