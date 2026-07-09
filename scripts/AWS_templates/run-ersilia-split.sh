#!/bin/bash
#SBATCH --job-name=ersilia-split
#SBATCH --nodes=1
#SBATCH --cpus-per-task=2
#SBATCH --time=2-00:00:00
#SBATCH --output=/shared/logs/split-%A_%a.out
#SBATCH --error=/shared/logs/split-%A_%a.err

# Run one sub-chunk of a proactive split on a slow Ersilia model.
#
# Self-healing pipeline:
#   1. Try the full range up to MAX_RETRIES times
#   2. On failure → bisect into 10 pieces and recurse
#   3. Single bad molecule → write empty row and continue
#
# The merge job always receives a complete, valid result file.
# Submitted by split-ersilia-chunk.sh — never call directly.
#
# Args: MODEL_ID SPLIT_DIR LIBRARY_NAME CHUNK_NUM TASKS_FILE

set -uo pipefail

MODEL_ID=$1
SPLIT_DIR=$2
LIBRARY_NAME=$3
CHUNK_NUM=$4
TASKS_FILE=$5

TASK_ID=${SLURM_ARRAY_TASK_ID:-0}
SIF_FILE="/shared/sif-files/${MODEL_ID}.sif"

TASK_LINE=$(sed -n "$((TASK_ID+1))p" "$TASKS_FILE")
START=$(echo "$TASK_LINE" | awk '{print $1}')
END=$(echo "$TASK_LINE" | awk '{print $2}')

SUB_CHUNK="${SPLIT_DIR}/sub_${START}_${END}.csv"
SUB_RESULT="${SPLIT_DIR}/result_${START}_${END}.csv"
NUM_MOLS=$(( END - START + 1 ))

echo "=========================================="
echo "Ersilia Split Job (retries + bisect)"
echo "=========================================="
echo "Job ID:  ${SLURM_JOB_ID:-local}  Task: ${TASK_ID}"
echo "Node:    $(hostname)"
echo "Date:    $(date)"
echo "Model:   $MODEL_ID"
echo "Library: $LIBRARY_NAME"
echo "Chunk:   $CHUNK_NUM"
echo "Range:   [${START}..${END}] (${NUM_MOLS} molecules)"
echo "=========================================="

[ ! -f "$SIF_FILE" ]  && { echo "ERROR: SIF not found: $SIF_FILE";    exit 1; }
[ ! -f "$SUB_CHUNK" ] && { echo "ERROR: Input not found: $SUB_CHUNK"; exit 1; }

MAX_RETRIES=2
_ATTEMPT=0   # global counter — gives each run_once call a unique scratch dir

# ── run_once: single ersilia run with fully isolated /tmp per invocation ───────
run_once() {
    local input=$1 output=$2
    _ATTEMPT=$(( _ATTEMPT + 1 ))
    local job_tmp="/tmp/ersilia_${SLURM_JOB_ID:-$$}_${TASK_ID}_${_ATTEMPT}"
    mkdir -p "$job_tmp"
    # SINGULARITYENV_* / APPTAINERENV_* override env vars inside the container,
    # preventing conda activation scripts from hijacking TMPDIR
    export APPTAINERENV_TMPDIR="$job_tmp" SINGULARITYENV_TMPDIR="$job_tmp"
    export APPTAINER_TMPDIR="$job_tmp"    SINGULARITY_TMPDIR="$job_tmp"
    export TMPDIR="$job_tmp"
    echo "    Scratch: $job_tmp"
    local loc="${job_tmp}/input.csv"
    cp "$input" "$loc"
    /shared/python39/bin/ersilia_apptainer \
        --sif "$SIF_FILE" --input "$loc" --output "$output" --verbose
    local rc=$?
    rm -rf "$job_tmp"
    return $rc
}

# ── add_key_input: replicate ersilia_apptainer's _format_output ───────────────
add_key_input() {
    local input=$1 output=$2
    python3 - <<PYEOF
import csv, hashlib, os
with open("$input", "r") as f:
    r = csv.DictReader(f)
    inputs = [row[r.fieldnames[0]] for row in r]
keys = [hashlib.md5(s.encode()).hexdigest() for s in inputs]
tmp = "$output.tmp"
with open("$output", "r") as fi, open(tmp, "w", newline="") as fo:
    r = csv.reader(fi); w = csv.writer(fo)
    w.writerow(["key", "input"] + next(r))
    for k, s, row in zip(keys, inputs, r):
        w.writerow([k, s] + row)
os.replace(tmp, "$output")
print("key/input columns added: {} rows".format(len(inputs)))
PYEOF
}

# ── write_empty_row: placeholder for a molecule that crashes the model ─────────
write_empty_row() {
    local input=$1 output=$2
    python3 - <<PYEOF
import csv, hashlib, glob, os

with open("$input", newline="") as f:
    r = csv.DictReader(f)
    smiles = next(r)[r.fieldnames[0]]

key = hashlib.md5(smiles.encode()).hexdigest()

# Discover property columns from any existing result in this split or the library
prop_cols = []
candidates = (
    glob.glob(os.path.join("$SPLIT_DIR", ".piece_*.csv")) +
    glob.glob(os.path.join("$SPLIT_DIR", "result_*.csv")) +
    glob.glob("/fsx/output/$LIBRARY_NAME/$MODEL_ID/${MODEL_ID}_results_*.csv")
)
for path in candidates:
    try:
        with open(path, newline="") as f:
            h = next(csv.reader(f))
        prop_cols = [c for c in h if c not in ("key", "input")]
        if prop_cols:
            break
    except Exception:
        continue

with open("$output", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["key", "input"] + prop_cols)
    w.writerow([key, smiles] + [""] * len(prop_cols))

print("Empty row written for: {}...".format(smiles[:50]))
PYEOF
}

# ── try_run: attempt up to MAX_RETRIES times, return 0 on valid output ─────────
try_run() {
    local input=$1 output=$2 n_mols=$3
    local expected=$(( n_mols + 1 ))
    for attempt in $(seq 1 $MAX_RETRIES); do
        echo "  Attempt ${attempt}/${MAX_RETRIES}..."
        rm -f "$output"
        run_once "$input" "$output" || true
        local actual=0
        [ -f "$output" ] && actual=$(wc -l < "$output")
        if [ "$actual" -eq "$expected" ]; then
            [[ "$(head -1 "$output")" != key,* ]] && add_key_input "$input" "$output"
            return 0
        fi
        echo "  → failed (lines=${actual}, expected=${expected})"
        rm -f "$output"
    done
    return 1
}

# ── process: run a range, bisecting recursively on failure ─────────────────────
# Always produces ${SPLIT_DIR}/.piece_${s}_${e}.csv — even for bad molecules.
process() {
    local input=$1 s=$2 e=$3
    local n=$(( e - s + 1 ))
    local out="${SPLIT_DIR}/.piece_${s}_${e}.csv"

    echo ""
    echo "  ── [${s}..${e}] (${n} mol) ──"

    # Happy path
    if try_run "$input" "$out" "$n"; then
        echo "  ✓ [${s}..${e}]"
        return 0
    fi

    rm -f "$out"

    # Terminal case: single bad molecule → empty row, never blocks the pipeline
    if [ "$n" -eq 1 ]; then
        echo "  ✗ Bad molecule at index ${s} — writing empty row"
        write_empty_row "$input" "$out"
        return 0
    fi

    # Bisect: split into up to 10 pieces and recurse
    echo "  Bisecting [${s}..${e}] into pieces..."
    local wdir="${SPLIT_DIR}/.wdir_${s}_${e}_$$"
    mkdir -p "$wdir"

    python3 - <<PYEOF
import csv, math, os

with open("$input", newline="") as f:
    r = csv.reader(f); hdr = next(r); rows = list(r)

n = len(rows)
n_splits = min(10, n)
piece = math.ceil(n / n_splits)

with open(os.path.join("$wdir", "tasks.txt"), "w") as tf:
    for i in range(n_splits):
        ss = $s + i * piece
        se = min(ss + piece - 1, $e)
        if i * piece >= n:
            break
        sf = os.path.join("$wdir", "sub_{}_{}.csv".format(ss, se))
        with open(sf, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(hdr)
            w.writerows(rows[i * piece : i * piece + (se - ss + 1)])
        tf.write("{} {} {}\n".format(ss, se, sf))
        print("    [{} .. {}] ({} mol)".format(ss, se, se - ss + 1))
PYEOF

    # Recursively process each piece
    while IFS=' ' read -r ps pe pf; do
        process "$pf" "$ps" "$pe"
    done < "${wdir}/tasks.txt"

    # Assemble all piece results into $out (preserves original molecule order)
    python3 - <<PYEOF
import csv, os

wdir = "$wdir"
split_dir = "$SPLIT_DIR"
out = "$out"
s = $s; e = $e

with open(os.path.join(wdir, "tasks.txt")) as f:
    tasks = [(int(l.split()[0]), int(l.split()[1])) for l in f]

header = None
all_rows = {}

for (ps, pe) in tasks:
    piece_f = os.path.join(split_dir, ".piece_{}_{}.csv".format(ps, pe))
    with open(piece_f, newline="") as f:
        r = csv.reader(f)
        h = next(r)
        if header is None:
            header = h
        for i, row in enumerate(r):
            all_rows[ps + i] = row

with open(out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(header)
    for idx in range(s, e + 1):
        w.writerow(all_rows[idx])

print("Assembled {} rows for [{} - {}]".format(e - s + 1, s, e))

# Clean up consumed piece files
for (ps, pe) in tasks:
    pf = os.path.join(split_dir, ".piece_{}_{}.csv".format(ps, pe))
    try:
        os.remove(pf)
    except Exception:
        pass
PYEOF

    rm -rf "$wdir"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "Strategy: ${MAX_RETRIES} retries → bisect → empty row for bad molecules"
echo ""

process "$SUB_CHUNK" "$START" "$END"

FINAL="${SPLIT_DIR}/.piece_${START}_${END}.csv"
if [ -f "$FINAL" ]; then
    mv "$FINAL" "$SUB_RESULT"
    echo ""
    echo "✓ result_${START}_${END}.csv ($(wc -l < "$SUB_RESULT") lines)"
else
    echo "✗ Failed to produce output for [${START}..${END}]"
    exit 1
fi

echo "=========================================="
echo "Split task done: $(date)"
echo "=========================================="
