#!/usr/bin/env python3
"""
Download and merge standardized library chunks from S3.
========================================================
Downloads the standardized SMILES input chunks (produced by
02_prepare_standardized_inputs.py) from S3 and merges them into a single
CSV file per library, keeping the header row only once.

S3 source layout:
  s3://<bucket>/input/<library>/<library>_chunk_<N>.csv

Output:
  <output-dir>/<library>.csv

Usage
-----
  python 04_download_and_merge_standardized_library.py \
      --s3-bucket ai2050-ersilia-cluster \
      [--libraries Enamine_Hit_Locator_460K Coconut_715K ...] \
      [--output-dir ./merged] \
      [--dry-run]

  --libraries   Space-separated library names. Defaults to all found under
                s3://<bucket>/input/.
  --dry-run     List chunks that would be merged without writing anything.
"""

import argparse
import csv
import logging
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


def s3_ls(s3_uri: str) -> list[str]:
    """Return a list of full S3 URIs under the given prefix."""
    result = subprocess.run(
        ["aws", "s3", "ls", s3_uri],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"aws s3 ls failed for {s3_uri}: {result.stderr.strip()}")
    lines = []
    for line in result.stdout.splitlines():
        parts = line.split()
        if parts:
            lines.append(parts[-1])
    return lines


def s3_download(s3_uri: str, local_path: Path):
    result = subprocess.run(
        ["aws", "s3", "cp", s3_uri, str(local_path)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"S3 download failed for {s3_uri}: {result.stderr.strip()}")


def discover_libraries(s3_bucket: str) -> list[str]:
    """Return library names found under s3://<bucket>/input/."""
    prefix = f"s3://{s3_bucket}/input/"
    result = subprocess.run(
        ["aws", "s3", "ls", prefix],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"aws s3 ls failed for {prefix}: {result.stderr.strip()}")
    libraries = []
    for line in result.stdout.splitlines():
        # Directory entries end with '/'
        parts = line.split()
        if parts and parts[-1].endswith("/"):
            libraries.append(parts[-1].rstrip("/"))
    return sorted(libraries)


def merge_library(library_name: str, s3_bucket: str, output_dir: Path, dry_run: bool) -> dict:
    prefix = f"s3://{s3_bucket}/input/{library_name}/"
    log.info(f"  Listing chunks at {prefix}")

    try:
        entries = s3_ls(prefix)
    except RuntimeError as e:
        log.error(f"  {e}")
        return {}

    chunk_keys = sorted(
        e for e in entries if e.endswith(".csv") and "_chunk_" in e
    )

    if not chunk_keys:
        log.warning(f"  No chunk CSVs found under {prefix}")
        return {}

    log.info(f"  Found {len(chunk_keys)} chunk(s)")

    if dry_run:
        for key in chunk_keys:
            log.info(f"  [dry-run] would merge: {prefix}{key}")
        return {"library": library_name, "chunks": len(chunk_keys), "rows": None}

    out_path = output_dir / f"{library_name}.csv"
    total_rows = 0

    with tempfile.TemporaryDirectory() as tmpdir:
        with open(out_path, "w", newline="", encoding="utf-8") as out_f:
            writer = None
            for i, key in enumerate(chunk_keys):
                s3_uri = f"{prefix}{key}"
                local_chunk = Path(tmpdir) / key
                log.info(f"  Downloading {key} ...")
                s3_download(s3_uri, local_chunk)

                with open(local_chunk, newline="", encoding="utf-8") as in_f:
                    reader = csv.DictReader(in_f)
                    if writer is None:
                        # Write header only for the first chunk
                        writer = csv.DictWriter(out_f, fieldnames=reader.fieldnames)
                        writer.writeheader()
                    for row in reader:
                        writer.writerow(row)
                        total_rows += 1

    log.info(f"  Merged {len(chunk_keys)} chunks → {total_rows:,} rows → {out_path}")
    return {"library": library_name, "chunks": len(chunk_keys), "rows": total_rows}


def main():
    parser = argparse.ArgumentParser(
        description="Download and merge standardized library chunks from S3 into a single CSV."
    )
    parser.add_argument("--s3-bucket",   default="ai2050-ersilia-cluster",
                        help="S3 bucket name (default: ai2050-ersilia-cluster)")
    parser.add_argument("--libraries",   nargs="*",
                        help="Library names to process. Defaults to all found under s3://<bucket>/input/.")
    parser.add_argument("--output-dir",  default="./merged",
                        help="Local directory for merged output files (default: ./merged)")
    parser.add_argument("--dry-run",     action="store_true",
                        help="List chunks that would be merged without downloading or writing")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)

    if args.libraries:
        libraries = args.libraries
    else:
        log.info(f"Auto-discovering libraries under s3://{args.s3_bucket}/input/ ...")
        try:
            libraries = discover_libraries(args.s3_bucket)
        except RuntimeError as e:
            log.error(str(e))
            sys.exit(1)
        if not libraries:
            log.error(f"No libraries found under s3://{args.s3_bucket}/input/")
            sys.exit(1)
        log.info(f"Auto-discovered libraries: {libraries}")

    if not args.dry_run:
        output_dir.mkdir(parents=True, exist_ok=True)

    log.info(f"\n{'='*65}")
    log.info("Download & Merge Standardized Library")
    log.info(f"S3 source  : s3://{args.s3_bucket}/input/<library>/")
    log.info(f"Output dir : {output_dir.resolve()}")
    if args.dry_run:
        log.info("DRY RUN — no files will be downloaded or written")
    log.info(f"{'='*65}")

    all_stats = []
    for library in libraries:
        log.info(f"\nLibrary: {library}")
        stats = merge_library(
            library_name=library,
            s3_bucket=args.s3_bucket,
            output_dir=output_dir,
            dry_run=args.dry_run,
        )
        if stats:
            all_stats.append(stats)

    log.info(f"\n{'='*65}")
    log.info("SUMMARY")
    log.info(f"{'='*65}")
    log.info(f"{'Library':<45} {'Chunks':>8} {'Rows':>12}")
    log.info(f"{'-'*65}")
    for s in all_stats:
        rows_str = f"{s['rows']:,}" if s["rows"] is not None else "n/a (dry-run)"
        log.info(f"{s['library']:<45} {s['chunks']:>8} {rows_str:>12}")
    log.info(f"{'='*65}")


if __name__ == "__main__":
    main()
