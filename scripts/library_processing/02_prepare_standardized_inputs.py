#!/usr/bin/env python3
"""
Prepare standardized SMILES inputs for subsequent Ersilia models.
=================================================================
After running the SMILES standardization model (eos4k4f_v1), use this script to
write new input chunks using the standardized_smiles column from the model output.

What it does:
  - Reads result CSVs from /fsx/output/<library>/<model_id>/
  - Skips rows where standardized_smiles is empty (failed standardization)
  - Writes new chunk CSVs to a temp dir, uploads to S3 input prefix
  - FSx Lustre auto-imports from S3 (AutoImportPolicy: NEW_CHANGED)
  - Reports molecule retention per library (input vs standardized count)

Note: Move original input chunks to s3://bucket/input/raw/ manually before running.

Usage
-----
  python 02_prepare_standardized_inputs.py \
      --model-id eos4k4f_v1 \
      --s3-bucket ai2050-ersilia-cluster \
      [--libraries Enamine_Hit_Locator_460K Coconut_715K ...] \
      [--output-base /fsx/output] \
      [--smiles-col  standardized_smiles] \
      [--dry-run]

  --libraries   Space-separated list of library names. Defaults to all found under output-base.
  --dry-run     Show what would happen without writing anything.
"""

import argparse
import csv
import logging
import re
import subprocess
import sys
import tempfile
from pathlib import Path

csv.field_size_limit(10 * 1024 * 1024)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)


def s3_upload(local_path: Path, s3_uri: str):
    result = subprocess.run(
        ["aws", "s3", "cp", str(local_path), s3_uri],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        raise RuntimeError(f"S3 upload failed: {result.stderr}")


def process_library(library_name: str, model_id: str, s3_bucket: str,
                    output_base: Path, smiles_col: str, dry_run: bool) -> dict:
    output_dir = output_base / library_name / model_id

    if not output_dir.exists():
        log.warning(f"  Output dir not found, skipping: {output_dir}")
        return {}

    result_files = sorted(
        output_dir.glob(f"{model_id}_results_*.csv"),
        key=lambda p: int(re.search(r"(\d+)$", p.stem).group(1))
    )

    if not result_files:
        log.warning(f"  No result files found in {output_dir}")
        return {}

    log.info(f"  Found {len(result_files)} result chunk(s)")

    total_input_rows = 0
    total_written = 0
    total_empty = 0
    failed_chunks = []

    with tempfile.TemporaryDirectory() as tmpdir:
        for result_file in result_files:
            chunk_num = re.search(r"(\d+)$", result_file.stem).group(1)
            out_filename = f"{library_name}_chunk_{chunk_num}.csv"
            out_path = Path(tmpdir) / out_filename
            s3_dest = f"s3://{s3_bucket}/input/{library_name}/{out_filename}"

            smiles_list = []
            empty_count = 0
            try:
                with open(result_file, newline="", encoding="utf-8") as f:
                    reader = csv.DictReader(f)
                    if smiles_col not in (reader.fieldnames or []):
                        log.error(f"  Column '{smiles_col}' not in {result_file.name}. "
                                  f"Available: {reader.fieldnames}")
                        failed_chunks.append(chunk_num)
                        continue
                    for row in reader:
                        smi = row[smiles_col].strip()
                        if smi:
                            smiles_list.append(smi)
                        else:
                            empty_count += 1
            except Exception as e:
                log.error(f"  Failed to read {result_file.name}: {e}")
                failed_chunks.append(chunk_num)
                continue

            chunk_input = len(smiles_list) + empty_count
            total_input_rows += chunk_input
            total_written += len(smiles_list)
            total_empty += empty_count

            if dry_run:
                log.info(f"  [dry-run] chunk_{chunk_num}: {chunk_input:,} in → "
                         f"{len(smiles_list):,} valid ({empty_count:,} empty) → {s3_dest}")
            else:
                with open(out_path, "w", newline="", encoding="utf-8") as f:
                    writer = csv.writer(f)
                    writer.writerow(["smiles"])
                    writer.writerows([[s] for s in smiles_list])
                s3_upload(out_path, s3_dest)
                log.info(f"  chunk_{chunk_num}: {chunk_input:,} → {len(smiles_list):,} valid "
                         f"({empty_count:,} empty) → uploaded to S3")

    retention = (total_written / total_input_rows * 100) if total_input_rows else 0
    stats = {
        "library":       library_name,
        "input_total":   total_input_rows,
        "standardized":  total_written,
        "empty":         total_empty,
        "retention_pct": retention,
        "failed_chunks": failed_chunks,
    }

    if failed_chunks:
        log.warning(f"  Failed chunks: {failed_chunks}")
        log.warning(f"  Run resubmit-missing.sh for these, then re-run this script.")

    return stats


def main():
    parser = argparse.ArgumentParser(
        description="Prepare standardized SMILES input chunks for subsequent models."
    )
    parser.add_argument("--model-id",    required=True,
                        help="Model ID used for standardization (e.g. eos4k4f_v1)")
    parser.add_argument("--s3-bucket",   default="ai2050-ersilia-cluster",
                        help="S3 bucket name (default: ai2050-ersilia-cluster)")
    parser.add_argument("--libraries",   nargs="*",
                        help="Library names to process. Defaults to all found under output-base.")
    parser.add_argument("--output-base", default="/fsx/output",
                        help="Base output directory where model results are (default: /fsx/output)")
    parser.add_argument("--smiles-col",  default="standardized_smiles",
                        help="Column to use as new SMILES input (default: standardized_smiles)")
    parser.add_argument("--dry-run",     action="store_true",
                        help="Show what would happen without writing or uploading anything")
    args = parser.parse_args()

    output_base = Path(args.output_base)

    if args.libraries:
        libraries = args.libraries
    else:
        libraries = sorted([
            d.name for d in output_base.iterdir()
            if d.is_dir() and (d / args.model_id).exists()
        ])
        if not libraries:
            log.error(f"No libraries found under {output_base} with model {args.model_id}")
            sys.exit(1)
        log.info(f"Auto-discovered libraries: {libraries}")

    log.info(f"\n{'='*65}")
    log.info(f"Standardized SMILES Input Preparation")
    log.info(f"Model      : {args.model_id}")
    log.info(f"SMILES col : {args.smiles_col}")
    log.info(f"S3 dest    : s3://{args.s3_bucket}/input/<library>/")
    log.info(f"Output base: {output_base}")
    if args.dry_run:
        log.info("DRY RUN — no files will be written or uploaded")
    log.info(f"{'='*65}")

    all_stats = []
    for library in libraries:
        log.info(f"\nLibrary: {library}")
        stats = process_library(
            library_name=library,
            model_id=args.model_id,
            s3_bucket=args.s3_bucket,
            output_base=output_base,
            smiles_col=args.smiles_col,
            dry_run=args.dry_run,
        )
        if stats:
            all_stats.append(stats)

    # Summary table
    log.info(f"\n{'='*65}")
    log.info("RETENTION SUMMARY")
    log.info(f"{'='*65}")
    log.info(f"{'Library':<45} {'Input':>10} {'Valid':>10} {'Empty':>8} {'Retained':>9}")
    log.info(f"{'-'*65}")
    for s in all_stats:
        log.info(f"{s['library']:<45} {s['input_total']:>10,} {s['standardized']:>10,} "
                 f"{s['empty']:>8,} {s['retention_pct']:>8.1f}%")
    if all_stats:
        grand_in  = sum(s['input_total']  for s in all_stats)
        grand_out = sum(s['standardized'] for s in all_stats)
        grand_pct = grand_out / grand_in * 100 if grand_in else 0
        grand_empty = sum(s['empty'] for s in all_stats)
        log.info(f"{'-'*65}")
        log.info(f"{'TOTAL':<45} {grand_in:>10,} {grand_out:>10,} "
                 f"{grand_empty:>8,} {grand_pct:>8.1f}%")
    log.info(f"{'='*65}")
    log.info("FSx Lustre will auto-import new files from S3 (AutoImportPolicy: NEW_CHANGED)")
    log.info(f"{'='*65}")


if __name__ == "__main__":
    main()
