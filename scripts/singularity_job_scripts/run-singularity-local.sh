#!/bin/bash
# Run a singularity model locally and ensure key/input columns are present.
#
# Usage:
#   run-singularity-local.sh <sif_file> <input_csv> <output_csv>

set -euo pipefail

SIF=$1
INPUT=$2
OUTPUT=$3

if [ -z "$SIF" ] || [ -z "$INPUT" ] || [ -z "$OUTPUT" ]; then
    echo "Usage: $0 <sif_file> <input_csv> <output_csv>"
    exit 1
fi

echo "Running model..."
singularity run \
    --bind /home/marina:/home/marina \
    "$SIF" \
    "$INPUT" \
    "$OUTPUT"

echo "Checking key/input columns..."
python3 - <<PYEOF
import csv, hashlib, os

input_csv  = "$INPUT"
output_csv = "$OUTPUT"

header = open(output_csv).readline().strip()
if header.startswith("key,"):
    print("key/input columns already present")
else:
    with open(input_csv) as f:
        r = csv.DictReader(f)
        inputs = [row[r.fieldnames[0]] for row in r]
    keys = [hashlib.md5(s.encode()).hexdigest() for s in inputs]
    tmp = output_csv + ".tmp"
    with open(output_csv) as fi, open(tmp, "w", newline="") as fo:
        r = csv.reader(fi); w = csv.writer(fo)
        w.writerow(["key", "input"] + next(r))
        for k, s, row in zip(keys, inputs, r):
            w.writerow([k, s] + row)
    os.replace(tmp, output_csv)
    print("Done: {} rows".format(len(inputs)))
PYEOF

echo "Output: $OUTPUT"
