#!/usr/bin/env python3
"""
Verify that standardized input chunks exist in S3 for each library.
=================================================================
After running 02_prepare_standardized_inputs.py, use this script to confirm
all expected input chunks are present in S3 without re-running the preparation.

What it does:
  - For each library, counts result chunks in /fsx/output/<library>/<model_id>/
  - Lists corresponding input chunks in s3://<bucket>/input/<library>/
  - Reports which chunks are missing and overall completion status

Usage
-----
  python 03_check_standardized_inputs.py --model-id eos4k4f_v1
  python 03_check_standardized_inputs.py --model-id eos42ez --s3-bucket ai2050-ersilia-cluster

Libraries are predefined in the script. If a model has not run for a library, that row shows NOT RUN.
"""

import argparse
import csv
import logging
import re
import subprocess
import sys
from pathlib import Path

LIBRARIES = [
    "Enamine_Hit_Locator_460K",
    "Coconut_715K",
    "Enamine_Liquid_Stock_2.5M",
    "Molport_Screening_Compounds_5.3M",
    "Enamine_Real_Sample_10.4M",
]

csv.field_size_limit(10 * 1024 * 1024)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)


def s3_list_chunks(s3_bucket: str, library_name: str) -> set[str]:
    """Return set of chunk numbers present in s3://<bucket>/input/<library>/."""
    prefix = f"s3://{s3_bucket}/input/{library_name}/"
    result = subprocess.run(
        ["aws", "s3", "ls", prefix],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return set()

    chunk_nums = set()
    for line in result.stdout.splitlines():
        # Lines look like: 2024-01-01 00:00:00   12345 LibraryName_chunk_001.csv
        parts = line.split()
        if not parts:
            continue
        filename = parts[-1]
        m = re.search(r"_chunk_(\d+)\.csv$", filename)
        if m:
            chunk_nums.add(m.group(1))
    return chunk_nums


def count_s3_rows(s3_bucket: str, library_name: str, chunk_num: str) -> int:
    """Download a chunk from S3 and count rows (minus header). Returns -1 on error."""
    s3_uri = f"s3://{s3_bucket}/input/{library_name}/{library_name}_chunk_{chunk_num}.csv"
    result = subprocess.run(
        ["aws", "s3", "cp", s3_uri, "-"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return -1
    lines = result.stdout.strip().splitlines()
    return max(0, len(lines) - 1)  # subtract header


def count_empty_in_results(result_files: list, input_cols: set) -> tuple[int, int]:
    """
    Read result CSVs and count molecules where ALL result columns are empty.
    Result columns = all columns except those in input_cols.
    Returns (total_molecules, molecules_with_all_results_empty).
    """
    total = 0
    empty = 0
    result_cols = None  # discovered from first file

    for f in result_files:
        try:
            with open(f, newline="") as fh:
                reader = csv.DictReader(fh)
                if result_cols is None and reader.fieldnames:
                    result_cols = [c for c in reader.fieldnames
                                   if c.strip().lower() not in input_cols]
                for row in reader:
                    total += 1
                    if result_cols and all(
                        row.get(c, "").strip() == "" for c in result_cols
                    ):
                        empty += 1
        except Exception as e:
            log.warning(f"  Could not read {f.name}: {e}")

    return total, empty


def check_library(library_name: str, model_id: str, s3_bucket: str,
                  output_base: Path, input_cols: set) -> dict:
    output_dir = output_base / library_name / model_id

    if not output_dir.exists():
        log.warning(f"  Output dir not found: {output_dir}")
        return {"library": library_name, "status": "NO_OUTPUT_DIR"}

    result_files = sorted(
        output_dir.glob(f"{model_id}_results_*.csv"),
        key=lambda p: int(re.search(r"(\d+)$", p.stem).group(1))
    )

    if not result_files:
        log.warning(f"  No result files in {output_dir}")
        return {"library": library_name, "status": "NO_RESULTS"}

    expected_chunks = {
        re.search(r"(\d+)$", p.stem).group(1) for p in result_files
    }

    s3_chunks = s3_list_chunks(s3_bucket, library_name)
    missing = sorted(expected_chunks - s3_chunks, key=lambda x: int(x))
    extra   = sorted(s3_chunks - expected_chunks, key=lambda x: int(x))
    present = sorted(expected_chunks & s3_chunks, key=lambda x: int(x))

    if missing:
        log.warning(f"  Missing {len(missing)} chunk(s): {missing[:10]}"
                    + (" ..." if len(missing) > 10 else ""))
    if extra:
        log.info(f"  Extra chunks in S3 (not in output): {extra[:5]}")

    total_mols, empty_mols = count_empty_in_results(result_files, input_cols)
    empty_pct = (empty_mols / total_mols * 100) if total_mols else 0
    log.info(f"  Molecules: {total_mols:,}  |  All results empty: {empty_mols:,} ({empty_pct:.1f}%)")

    return {
        "library":        library_name,
        "expected":       len(expected_chunks),
        "present":        len(present),
        "missing":        len(missing),
        "missing_chunks": missing,
        "extra":          len(extra),
        "total_mols":     total_mols,
        "empty_mols":     empty_mols,
        "empty_pct":      empty_pct,
        "status":         "COMPLETE" if not missing else "INCOMPLETE",
    }


def main():
    parser = argparse.ArgumentParser(
        description="Check standardized input chunks exist in S3."
    )
    parser.add_argument("--model-id",    required=True,
                        help="Model ID used for standardization (e.g. eos4k4f_v1)")
    parser.add_argument("--s3-bucket",   default="ai2050-ersilia-cluster",
                        help="S3 bucket name (default: ai2050-ersilia-cluster)")
    parser.add_argument("--output-base", default="/fsx/output",
                        help="Base directory where model results are (default: /fsx/output)")
    parser.add_argument("--input-cols",  nargs="*",
                        default=["key", "input", "smiles", "canonical_smiles"],
                        help="Columns to treat as key/input (excluded from empty check). "
                             "Default: key input smiles canonical_smiles")
    args = parser.parse_args()

    output_base = Path(args.output_base)
    input_cols = {c.strip().lower() for c in args.input_cols}
    libraries = LIBRARIES

    log.info(f"\n{'='*65}")
    log.info("Standardized Input Chunk Verification")
    log.info(f"Model      : {args.model_id}")
    log.info(f"S3 source  : s3://{args.s3_bucket}/input/<library>/")
    log.info(f"Output base: {output_base}")
    log.info(f"Input cols (excluded from empty check): {sorted(input_cols)}")
    log.info(f"{'='*65}")

    all_stats = []
    for library in libraries:
        log.info(f"\nLibrary: {library}")
        stats = check_library(
            library_name=library,
            model_id=args.model_id,
            s3_bucket=args.s3_bucket,
            output_base=output_base,
            input_cols=input_cols,
        )
        all_stats.append(stats)
        if "expected" in stats:
            log.info(f"  Expected: {stats['expected']}  Present: {stats['present']}  "
                     f"Missing: {stats['missing']}  Status: {stats['status']}")

    # Summary table
    log.info(f"\n{'='*90}")
    log.info("SUMMARY")
    log.info(f"{'='*90}")
    log.info(f"{'Library':<45} {'Chunks':>7} {'Missing':>8} {'Molecules':>11} {'Empty':>9} {'Empty%':>7} {'Status':>10}")
    log.info(f"{'-'*90}")
    for s in all_stats:
        if "expected" not in s:
            log.info(f"{s['library']:<45} {'—':>7} {'—':>8} {'—':>11} {'—':>9} {'—':>7} {'NOT RUN':>10}")
            continue
        log.info(f"{s['library']:<45} {s['expected']:>7,} {s['missing']:>8,} "
                 f"{s['total_mols']:>11,} {s['empty_mols']:>9,} {s['empty_pct']:>6.1f}% {s['status']:>10}")
    log.info(f"{'='*90}")

    incomplete = [s["library"] for s in all_stats
                  if s.get("missing", 0) > 0]
    if incomplete:
        log.warning(f"Incomplete libraries: {incomplete}")
        sys.exit(1)
    else:
        ran = [s for s in all_stats if "expected" in s]
        log.info(f"{len(ran)}/{len(libraries)} libraries complete.")


if __name__ == "__main__":
    main()
