#!/bin/bash
# Check batch output completeness and empty rows
#
# Usage: check-batch-results.sh [model_id ...]
#
# Without arguments: reports on ALL model IDs found in /fsx/batch_outputs/
# With arguments:    reports only on the specified model IDs
#
# Output format:
#   Model ID   | Total chunks | Missing | Mismatched | Empty rows | Done
#
# Example:
#   bash check-batch-results.sh
#   bash check-batch-results.sh eos1af5 eos1pu1

INPUT_DIR="/fsx/input/batch_inputs"
OUTPUT_DIR="/fsx/output/batch_outputs"

if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory not found: $INPUT_DIR"
    exit 1
fi

if [ ! -d "$OUTPUT_DIR" ]; then
    echo "ERROR: Output directory not found: $OUTPUT_DIR"
    exit 1
fi

# Build model list: either from args or by scanning output files
if [ $# -gt 0 ]; then
    MODELS=("$@")
else
    # Discover model IDs from files named <model_id>_NNN.csv
    # Model IDs match: eosXXXX (letters+digits), followed by _NNN.csv
    mapfile -t MODELS < <(
        ls "$OUTPUT_DIR"/*.csv 2>/dev/null \
        | xargs -I{} basename {} .csv \
        | grep -oP '^eos[a-z0-9]+(?=_\d{3}$)' \
        | sort -u
    )
fi

if [ ${#MODELS[@]} -eq 0 ]; then
    echo "No model output files found in $OUTPUT_DIR"
    echo "Expected filenames: <model_id>_NNN.csv  (e.g. eos1af5_002.csv)"
    exit 0
fi

/shared/python39/bin/python3.9 << EOF
import csv
from pathlib import Path

csv.field_size_limit(10 * 1024 * 1024)

INPUT_COLS = {"key", "input", "smiles", "canonical_smiles"}

input_dir  = Path("${INPUT_DIR}")
output_dir = Path("${OUTPUT_DIR}")
models     = [$(printf '"%s",' "${MODELS[@]}")]


def count_empty_rows(output_file, input_cols):
    """Return count of rows where ALL result columns are empty."""
    empty = 0
    try:
        with open(output_file, newline="") as fh:
            reader = csv.DictReader(fh)
            result_cols = [
                c for c in (reader.fieldnames or [])
                if c.strip().lower() not in input_cols
            ]
            for row in reader:
                if result_cols and all(row.get(c, "").strip() == "" for c in result_cols):
                    empty += 1
    except Exception as e:
        print(f"    WARNING: could not read {output_file.name}: {e}")
    return empty


input_chunks = sorted(input_dir.glob("smiles_*.csv"))
total_input  = len(input_chunks)

print()
print(f"Input dir : {input_dir}")
print(f"Output dir: {output_dir}")
print(f"Input chunks: {total_input}")
print("=" * 75)
print(f"{'Model':<20} {'Total':>7} {'Missing':>8} {'Mismatch':>9} {'Empty rows':>11} {'Done':>7}")
print("-" * 75)

for model_id in models:
    missing   = []
    mismatch  = []
    empty_agg = []  # (chunk_num, count)
    done      = 0

    for inp in input_chunks:
        chunk_num   = inp.stem.split("_")[-1]          # "000", "001", ...
        out         = output_dir / f"{model_id}_{chunk_num}.csv"

        if not out.exists():
            missing.append(chunk_num)
            continue

        in_rows  = sum(1 for _ in inp.open()) - 1
        out_rows = sum(1 for _ in out.open()) - 1

        if in_rows != out_rows:
            mismatch.append(chunk_num)
        else:
            done += 1

        n_empty = count_empty_rows(out, INPUT_COLS)
        if n_empty > 0:
            empty_agg.append((chunk_num, n_empty))

    n_missing  = len(missing)
    n_mismatch = len(mismatch)
    n_empty    = sum(c for _, c in empty_agg)
    status     = f"{done}/{total_input}"

    print(f"{model_id:<20} {total_input:>7,} {n_missing:>8,} {n_mismatch:>9,} {n_empty:>11,} {status:>7}")

    if missing:
        s = ", ".join(missing[:20])
        suf = f" ... (+{len(missing)-20} more)" if len(missing) > 20 else ""
        print(f"  MISSING  : {s}{suf}")

    if mismatch:
        s = ", ".join(mismatch[:20])
        suf = f" ... (+{len(mismatch)-20} more)" if len(mismatch) > 20 else ""
        print(f"  MISMATCH : {s}{suf}")

    if empty_agg:
        top = empty_agg[:10]
        s   = ", ".join(f"{c}({n})" for c, n in top)
        suf = f" ... (+{len(empty_agg)-10} more)" if len(empty_agg) > 10 else ""
        print(f"  EMPTY rows: {s}{suf}")

print("=" * 75)
print()
EOF
