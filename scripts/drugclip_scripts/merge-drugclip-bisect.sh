#!/bin/bash
# Merge bisect result CSVs into the final chunk CSV.
#
# Usage:
#   bash /shared/scripts/drugclip_scripts/merge-drugclip-bisect.sh <library_name> <chunk_num>
#
# Example:
#   bash /shared/scripts/drugclip_scripts/merge-drugclip-bisect.sh Molport_Screening_Compounds_5.3M 423
#
# Reads : /fsx/output/<library>/drugclip/bisect_<chunk_num>/result_*.csv
# Writes: /fsx/output/<library>/drugclip/<library>_drugclip_<chunk_num>.csv

LIBRARY_NAME=$1
CHUNK_NUM=$2

if [ -z "$LIBRARY_NAME" ] || [ -z "$CHUNK_NUM" ]; then
    echo "Usage: $0 <library_name> <chunk_num>"
    exit 1
fi

INPUT_FILE="/fsx/input/${LIBRARY_NAME}/${LIBRARY_NAME}_chunk_${CHUNK_NUM}.csv"
BISECT_DIR="/fsx/output/${LIBRARY_NAME}/drugclip/bisect_${CHUNK_NUM}"
OUTPUT_CSV="/fsx/output/${LIBRARY_NAME}/drugclip/${LIBRARY_NAME}_drugclip_${CHUNK_NUM}.csv"

if [ ! -d "$BISECT_DIR" ]; then
    echo "ERROR: Bisect directory not found: $BISECT_DIR"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: Original input chunk not found: $INPUT_FILE"
    exit 1
fi

echo "=========================================="
echo "DrugCLIP Bisect Merge"
echo "=========================================="
echo "Library   : $LIBRARY_NAME"
echo "Chunk     : $CHUNK_NUM"
echo "Bisect dir: $BISECT_DIR"
echo "Output    : $OUTPUT_CSV"
echo "=========================================="

/shared/python39/bin/python3.9 - "$INPUT_FILE" "$BISECT_DIR" "$OUTPUT_CSV" << 'PYEOF'
import csv, hashlib, sys, os
from pathlib import Path

input_file  = Path(sys.argv[1])
bisect_dir  = Path(sys.argv[2])
output_csv  = Path(sys.argv[3])

SMILES_COLS = {"smiles", "canonical_smiles", "input"}
HEADERS = (["key", "input"]
           + [f"fold-{f}-dim-{d:03d}" for f in range(6) for d in range(128)])
EMPTY = [""] * 768

# ── Read all input SMILES in order ────────────────────────────────────────────
csv.field_size_limit(10 * 1024 * 1024)
with open(input_file, newline="") as f:
    reader = csv.DictReader(f)
    lower = [c.strip().lower() for c in (reader.fieldnames or [])]
    col = next((o for o, l in zip(reader.fieldnames, lower) if l in SMILES_COLS), None)
    if col is None:
        print(f"ERROR: No SMILES column found in {input_file}")
        sys.exit(1)
    all_smiles = [row[col].strip() for row in reader]

print(f"Input molecules : {len(all_smiles):,}")

# ── Load all result CSVs from bisect dir into a lookup {smiles: row} ─────────
result_files = sorted(bisect_dir.glob("result_*.csv"))
if not result_files:
    print(f"ERROR: No result_*.csv files found in {bisect_dir}")
    sys.exit(1)

print(f"Result files    : {len(result_files)}")

embedding_map = {}  # smiles → list of values (770 cols including key+input)
for rf in result_files:
    with open(rf, newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        for row in reader:
            if len(row) < 2:
                continue
            smi = row[1]  # input column
            embedding_map[smi] = row

print(f"Embeddings loaded: {len(embedding_map):,}")

# ── Write final CSV in original molecule order ────────────────────────────────
n_found = 0
n_empty = 0

with open(output_csv, "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(HEADERS)
    for smi in all_smiles:
        if smi in embedding_map:
            writer.writerow(embedding_map[smi])
            # check if this row has embeddings or is empty
            if any(v != "" for v in embedding_map[smi][2:]):
                n_found += 1
            else:
                n_empty += 1
        else:
            # molecule not present in any result file — write empty row
            key = hashlib.md5(smi.encode("utf-8")).hexdigest()
            writer.writerow([key, smi] + EMPTY)
            n_empty += 1

print(f"Written         : {n_found + n_empty:,} rows")
print(f"  With embeddings : {n_found:,}")
print(f"  Empty (failed)  : {n_empty:,}")
print(f"Output: {output_csv}")
PYEOF

MERGE_EXIT=$?
if [ $MERGE_EXIT -ne 0 ]; then
    echo "ERROR: Merge failed"
    exit 1
fi

echo ""
echo "SUCCESS: $OUTPUT_CSV ($(du -h "$OUTPUT_CSV" | cut -f1))"
echo "=========================================="
