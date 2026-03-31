#!/bin/bash
# Merge binary search sub-results into the final standard output file.
#
# Run this after all bisect jobs for a chunk have completed.
#
# Usage:
#   merge-bisect-results.sh <model_id> <library_name> <chunk_num>
#
# Output:
#   /fsx/output/<library>/<model_id>/<model_id>_results_<chunk_num>.csv
#   (same name and format as normal batch output — compatible with check-results.sh)

set -euo pipefail

MODEL_ID=${1:-}
LIBRARY_NAME=${2:-}
CHUNK_NUM=${3:-}

if [ -z "$MODEL_ID" ] || [ -z "$LIBRARY_NAME" ] || [ -z "$CHUNK_NUM" ]; then
    echo "Usage: $0 <model_id> <library_name> <chunk_num>"
    exit 1
fi

INPUT_DIR="/fsx/input/${LIBRARY_NAME}"
OUTPUT_DIR="/fsx/output/${LIBRARY_NAME}/${MODEL_ID}"
BISECT_DIR="${OUTPUT_DIR}/bisect/${CHUNK_NUM}"
FINAL_OUTPUT="${OUTPUT_DIR}/${MODEL_ID}_results_${CHUNK_NUM}.csv"

# Find input chunk
CHUNK_FILE=$(ls "${INPUT_DIR}/"*"_chunk_${CHUNK_NUM}.csv" 2>/dev/null | head -1)
if [ -z "$CHUNK_FILE" ]; then
    echo "ERROR: Could not find chunk ${CHUNK_NUM} in ${INPUT_DIR}"
    exit 1
fi

if [ ! -d "$BISECT_DIR" ]; then
    echo "ERROR: Bisect workspace not found: $BISECT_DIR"
    echo "Run bisect-ersilia-chunk.sh first."
    exit 1
fi

echo "=========================================="
echo "Merge Bisect Results"
echo "=========================================="
echo "Model:    $MODEL_ID"
echo "Library:  $LIBRARY_NAME"
echo "Chunk:    $CHUNK_NUM"
echo "Bisect:   $BISECT_DIR"
echo "Output:   $FINAL_OUTPUT"
echo "=========================================="

python3 - <<EOF
import csv, glob, os, re, sys

bisect_dir   = "$BISECT_DIR"
chunk_file   = "$CHUNK_FILE"
final_output = "$FINAL_OUTPUT"

# ── Load original chunk to know total molecules and order ─────────────────────
with open(chunk_file, newline="") as f:
    reader = csv.reader(f)
    next(reader)  # skip header
    original_smiles = [row[0] for row in reader]

num_mols = len(original_smiles)
print(f"Original chunk has {num_mols} molecules")

# ── Collect all result sub-files ──────────────────────────────────────────────
result_files = glob.glob(os.path.join(bisect_dir, "result_*.csv"))
if not result_files:
    print("ERROR: No result files found in bisect dir. Are all jobs done?", file=sys.stderr)
    sys.exit(1)

print(f"Found {len(result_files)} result file(s)")

# ── Map each result row back to its original index ───────────────────────────
results = {}   # index -> csv row list
header = None

for path in result_files:
    m = re.match(r"result_(\d+)_(\d+)\.csv$", os.path.basename(path))
    if not m:
        continue
    start, end = int(m.group(1)), int(m.group(2))

    with open(path, newline="") as f:
        reader = csv.reader(f)
        file_header = next(reader)
        if header is None:
            header = file_header
        rows = list(reader)

    for i, row in enumerate(rows):
        results[start + i] = row

# ── Check coverage ────────────────────────────────────────────────────────────
missing = [i for i in range(num_mols) if i not in results]
if missing:
    print(f"WARNING: {len(missing)} molecule(s) have no result yet.", file=sys.stderr)
    print(f"  Missing indices: {missing[:20]}" + (" ..." if len(missing) > 20 else ""), file=sys.stderr)
    print("Wait for remaining jobs to finish, then re-run this script.", file=sys.stderr)
    sys.exit(1)

# ── Write merged output in original order ─────────────────────────────────────
tmp_output = final_output + ".tmp"
with open(tmp_output, "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(header)
    for i in range(num_mols):
        writer.writerow(results[i])

os.replace(tmp_output, final_output)

# ── Summary ───────────────────────────────────────────────────────────────────
empty_count = sum(
    1 for i in range(num_mols)
    if all(v == "" for v in results[i][2:])   # cols after key and input
)

print(f"✓ Merged output written: {final_output}")
print(f"  Total rows:  {num_mols}")
print(f"  Empty rows:  {empty_count} (bad molecules, expected)")
print(f"  Valid rows:  {num_mols - empty_count}")
EOF
