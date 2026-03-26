#!/bin/bash
# Check DrugCLIP embedding results for one or more libraries.
# Reports missing chunks and embedding count mismatches.
#
# Usage:
#   bash /shared/scripts/drugclip/check-drugclip-results.sh [library1 library2 ...]
#
# If no libraries are given, checks all 5 main libraries.
#
# Examples:
#   bash /shared/scripts/drugclip/check-drugclip-results.sh
#   bash /shared/scripts/drugclip/check-drugclip-results.sh Enamine_Hit_Locator_460K
#   bash /shared/scripts/drugclip/check-drugclip-results.sh Molport_Screening_Compounds_5.3M Coconut_715K

ALL_LIBRARIES=(
    "Enamine_Hit_Locator_460K"
    "Coconut_715K"
    "Enamine_Liquid_Stock_2.5M"
    "Molport_Screening_Compounds_5.3M"
    "Enamine_Real_Sample_10.4M"
)

if [ $# -gt 0 ]; then
    LIBRARIES=("$@")
else
    LIBRARIES=("${ALL_LIBRARIES[@]}")
fi

/shared/python39/bin/python3.9 << EOF
import pickle
import sys
from pathlib import Path

try:
    import h5py
except ImportError:
    import subprocess
    subprocess.check_call(["/shared/python39/bin/pip", "install", "h5py", "-q"])
    import h5py

libraries = [$(printf '"%s",' "${LIBRARIES[@]}")]

def count_lmdb_molecules(input_file):
    """Count molecules in a SMILES CSV (rows minus header)."""
    try:
        with open(input_file) as f:
            return sum(1 for _ in f) - 1
    except Exception:
        return -1

def count_h5_embeddings(h5_file):
    """Count embeddings stored in an HDF5 file."""
    try:
        with h5py.File(h5_file, "r") as f:
            if "embeddings" in f:
                return f["embeddings"].shape[0]
            # Fallback: check attrs
            if "n_molecules" in f.attrs:
                return int(f.attrs["n_molecules"])
        return -1
    except Exception as e:
        return -1

print()
print(f"{'Library':<45} {'Chunks':>7} {'Missing':>8} {'Mismatch':>9} {'Done':>7}")
print("-" * 80)

total_chunks   = 0
total_missing  = 0
total_mismatch = 0
total_done     = 0

for library in libraries:
    input_dir  = Path(f"/fsx/input/{library}")
    output_dir = Path(f"/fsx/output/{library}/drugclip")

    if not input_dir.exists():
        print(f"{library:<45} {'—':>7} {'—':>8} {'—':>9} {'NO INPUT':>7}")
        continue

    if not output_dir.exists():
        input_chunks = sorted(input_dir.glob("*_chunk_*.csv"))
        n = len(input_chunks)
        print(f"{library:<45} {n:>7,} {n:>8,} {'—':>9} {'0/' + str(n):>7}")
        if n > 0:
            all_nums = [f.stem.split('_')[-1] for f in input_chunks]
            print(f"  Output dir not found: {output_dir}")
        total_chunks  += n
        total_missing += n
        continue

    input_chunks = sorted(input_dir.glob("*_chunk_*.csv"))
    if not input_chunks:
        print(f"{library:<45} {'—':>7} {'—':>8} {'—':>9} {'NO INPUT':>7}")
        continue

    missing_chunks  = []
    mismatch_chunks = []
    done = 0

    for input_file in input_chunks:
        chunk_num   = input_file.stem.split("_")[-1]
        output_file = output_dir / f"{library}_drugclip_{chunk_num}.h5"

        if not output_file.exists():
            missing_chunks.append(chunk_num)
            continue

        in_rows  = count_lmdb_molecules(input_file)
        out_rows = count_h5_embeddings(output_file)

        if in_rows < 0 or out_rows < 0:
            mismatch_chunks.append(chunk_num)
        elif in_rows != out_rows:
            mismatch_chunks.append(chunk_num)
        else:
            done += 1

    n          = len(input_chunks)
    n_missing  = len(missing_chunks)
    n_mismatch = len(mismatch_chunks)
    status     = f"{done}/{n}"

    print(f"{library:<45} {n:>7,} {n_missing:>8,} {n_mismatch:>9,} {status:>7}")

    if missing_chunks:
        chunks_str = ", ".join(missing_chunks[:20])
        suffix = f" ... (+{len(missing_chunks)-20} more)" if len(missing_chunks) > 20 else ""
        print(f"  MISSING  : {chunks_str}{suffix}")

    if mismatch_chunks:
        chunks_str = ", ".join(mismatch_chunks[:20])
        suffix = f" ... (+{len(mismatch_chunks)-20} more)" if len(mismatch_chunks) > 20 else ""
        print(f"  MISMATCH : {chunks_str}{suffix}")

    total_chunks   += n
    total_missing  += n_missing
    total_mismatch += n_mismatch
    total_done     += done

print("-" * 80)
print(f"{'TOTAL':<45} {total_chunks:>7,} {total_missing:>8,} {total_mismatch:>9,} {str(total_done)+'/'+str(total_chunks):>7}")
print()
EOF
