#!/bin/bash
# Merge divide-and-conquer sub-results into the final singularity library output file.
#
# Run this after all bisect jobs for a chunk have completed.
#
# Usage:
#   merge-singularity-library-bisect.sh <model_id> <library_name> <chunk_num>
#
# Example:
#   merge-singularity-library-bisect.sh mtb-public-models Coconut_715K 042
#
# Output:
#   /fsx/output/<library_name>/<model_id>/<model_id>_<chunk_num>.csv

set -euo pipefail

MODEL_ID=${1:-}
LIBRARY_NAME=${2:-}
CHUNK_NUM=${3:-}

if [ -z "$MODEL_ID" ] || [ -z "$LIBRARY_NAME" ] || [ -z "$CHUNK_NUM" ]; then
    echo "Usage: $0 <model_id> <library_name> <chunk_num>"
    echo "Example: $0 mtb-public-models Coconut_715K 042"
    exit 1
fi

INPUT_FILE="/fsx/input/${LIBRARY_NAME}/${LIBRARY_NAME}_chunk_${CHUNK_NUM}.csv"
OUTPUT_DIR="/fsx/output/${LIBRARY_NAME}/${MODEL_ID}"
BISECT_DIR="${OUTPUT_DIR}/bisect/${CHUNK_NUM}"
FINAL_OUTPUT="${OUTPUT_DIR}/${MODEL_ID}_${CHUNK_NUM}.csv"

if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: Input file not found: $INPUT_FILE"
    exit 1
fi

if [ ! -d "$BISECT_DIR" ]; then
    echo "ERROR: Bisect workspace not found: $BISECT_DIR"
    echo "Run bisect-singularity-library-chunk.sh first."
    exit 1
fi

echo "=========================================="
echo "Merge Singularity Library Bisect Results"
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
input_file   = "$INPUT_FILE"
final_output = "$FINAL_OUTPUT"

with open(input_file, newline="") as f:
    reader = csv.reader(f)
    next(reader)
    original_smiles = [row[0] for row in reader]

num_mols = len(original_smiles)
print(f"Original chunk has {num_mols} molecules")

result_files = glob.glob(os.path.join(bisect_dir, "result_*.csv"))
if not result_files:
    print("ERROR: No result files found in bisect dir. Are all jobs done?", file=sys.stderr)
    sys.exit(1)

print(f"Found {len(result_files)} result file(s)")

results = {}
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

missing = [i for i in range(num_mols) if i not in results]
if missing:
    print(f"WARNING: {len(missing)} molecule(s) have no result yet.", file=sys.stderr)
    print(f"  Missing indices: {missing[:20]}" + (" ..." if len(missing) > 20 else ""), file=sys.stderr)
    print("Wait for remaining jobs to finish, then re-run this script.", file=sys.stderr)
    sys.exit(1)

tmp_output = final_output + ".tmp"
with open(tmp_output, "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(header)
    for i in range(num_mols):
        writer.writerow(results[i])

os.replace(tmp_output, final_output)

empty_count = sum(
    1 for i in range(num_mols)
    if all(v == "" for v in results[i][2:])
)

print(f"✓ Merged output written: {final_output}")
print(f"  Total rows:  {num_mols}")
print(f"  Empty rows:  {empty_count} (bad molecules, expected)")
print(f"  Valid rows:  {num_mols - empty_count}")
EOF
