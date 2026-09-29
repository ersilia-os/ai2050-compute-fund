#!/usr/bin/env python3
"""
Debug failing chunks by testing SMILES one by one locally.
===========================================================
Downloads missing chunk files from S3 and runs each SMILES individually
through a local SIF file to identify which molecule causes the failure.

Usage
-----
    python 05_debug_failing_chunks.py \
        --library Enamine_Hit_Locator_460K \
        --chunks 005 012 034 \
        --sif /home/marina/models/models_sif/ai2050_sif/eos3ujl_v1.sif \
        --model-id eos3ujl_v1 \
        [--s3-bucket ai2050-ersilia-cluster] \
        [--output-dir ./debug_output] \
        [--timeout 120] \
        [--ersilia-bin ersilia_apptainer]

Output
------
    CSV file per library with columns:
        library, chunk_file, smiles_position, smiles, status, details
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


def s3_download(s3_uri: str, local_path: Path):
    result = subprocess.run(
        ["aws", "s3", "cp", s3_uri, str(local_path)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"S3 download failed for {s3_uri}: {result.stderr.strip()}")


def run_smiles_batch(smiles_list: list[str], sif: Path, ersilia_bin: str, timeout: int) -> tuple[bool, str]:
    """
    Run ersilia_apptainer on a list of SMILES.
    Returns (success: bool, details: str).
    Success means exit 0 AND output rows == input rows.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        input_csv  = Path(tmpdir) / "input.csv"
        output_csv = Path(tmpdir) / "output.csv"

        with open(input_csv, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["smiles"])
            for s in smiles_list:
                writer.writerow([s])

        try:
            result = subprocess.run(
                [ersilia_bin, "run", "--sif", str(sif), "--input", str(input_csv), "--output", str(output_csv)],
                capture_output=True, text=True, timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            return False, f"TIMEOUT after {timeout}s"

        if result.returncode != 0:
            stderr = result.stderr.strip().replace("\n", " | ")
            return False, f"EXIT {result.returncode}: {stderr[:300]}"

        if not output_csv.exists():
            return False, "No output file produced"

        with open(output_csv, newline="") as f:
            out_rows = sum(1 for _ in f) - 1  # exclude header
        if out_rows != len(smiles_list):
            return False, f"Row mismatch: expected {len(smiles_list)}, got {out_rows}"

        return True, "OK"


def binary_search_failing(smiles_list: list[str], positions: list[int],
                          sif: Path, ersilia_bin: str, timeout: int,
                          depth: int = 0) -> list[tuple[int, str, str]]:
    """
    Recursively binary-search for failing SMILES.
    Returns list of (position, smiles, details) for each failing molecule.
    """
    if not smiles_list:
        return []

    indent = "  " + "  " * depth
    log.info(f"{indent}Testing {len(smiles_list)} SMILES "
             f"(positions {positions[0]}–{positions[-1]}) ...")

    batch_timeout = timeout * len(smiles_list)
    success, details = run_smiles_batch(smiles_list, sif, ersilia_bin, batch_timeout)

    if success:
        log.info(f"{indent}-> All OK")
        return []

    log.warning(f"{indent}-> FAIL ({details})")

    # Base case: single SMILES identified as the culprit
    if len(smiles_list) == 1:
        log.warning(f"{indent}!! Found failing SMILES at position {positions[0]}: {smiles_list[0][:60]}")
        return [(positions[0], smiles_list[0], details)]

    # Divide and search both halves (there may be multiple failing SMILES)
    mid = len(smiles_list) // 2
    left_results  = binary_search_failing(smiles_list[:mid], positions[:mid],
                                          sif, ersilia_bin, timeout, depth + 1)
    right_results = binary_search_failing(smiles_list[mid:], positions[mid:],
                                          sif, ersilia_bin, timeout, depth + 1)
    return left_results + right_results


def debug_chunk(chunk_file: Path, library: str, sif: Path,
                ersilia_bin: str, timeout: int) -> list[dict]:
    """Binary-search for failing SMILES in the chunk. Returns list of result dicts."""
    results = []
    log.info(f"  Reading {chunk_file.name} ...")

    with open(chunk_file, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        smiles_col = None
        for col in (reader.fieldnames or []):
            if col.strip().lower() in {"smiles", "canonical_smiles", "input"}:
                smiles_col = col
                break
        if not smiles_col:
            log.error(f"  No SMILES column found. Columns: {reader.fieldnames}")
            return results
        rows = list(reader)

    smiles_list = [r[smiles_col].strip() for r in rows]
    positions   = list(range(1, len(smiles_list) + 1))  # 1-based

    log.info(f"  {len(smiles_list)} SMILES — using binary search (timeout={timeout}s per SMILES)")

    failures = binary_search_failing(smiles_list, positions, sif, ersilia_bin, timeout)

    for pos, smiles, details in failures:
        results.append({
            "library":         library,
            "chunk_file":      chunk_file.name,
            "smiles_position": pos,
            "smiles":          smiles,
            "status":          "FAIL",
            "details":         details,
        })

    return results


def main():
    parser = argparse.ArgumentParser(
        description="Test each SMILES in a missing chunk individually to find the failing molecule."
    )
    parser.add_argument("--library",     required=True,
                        help="Library name (e.g. Enamine_Hit_Locator_460K)")
    parser.add_argument("--chunks",      required=True, nargs="+",
                        help="Chunk numbers to debug (e.g. 005 012 034)")
    parser.add_argument("--sif",         required=True, type=Path,
                        help="Path to local SIF file")
    parser.add_argument("--model-id",    required=True,
                        help="Model ID (e.g. eos3ujl_v1) — used for output naming only")
    parser.add_argument("--s3-bucket",   default="ai2050-ersilia-cluster")
    parser.add_argument("--output-dir",  default="./debug_output", type=Path)
    parser.add_argument("--timeout",     default=120, type=int,
                        help="Seconds before a single SMILES run is considered failed (default: 120)")
    parser.add_argument("--ersilia-bin", default="ersilia_apptainer",
                        help="Path to ersilia_apptainer binary (default: ersilia_apptainer)")
    args = parser.parse_args()

    if not args.sif.exists():
        log.error(f"SIF file not found: {args.sif}")
        sys.exit(1)

    args.output_dir.mkdir(parents=True, exist_ok=True)

    log.info(f"\n{'='*65}")
    log.info(f"Debug Failing Chunks")
    log.info(f"Library   : {args.library}")
    log.info(f"Chunks    : {args.chunks}")
    log.info(f"SIF       : {args.sif}")
    log.info(f"Model     : {args.model_id}")
    log.info(f"Timeout   : {args.timeout}s per SMILES")
    log.info(f"Output    : {args.output_dir}")
    log.info(f"{'='*65}\n")

    all_results = []

    with tempfile.TemporaryDirectory() as tmpdir:
        for chunk_num in args.chunks:
            chunk_num = chunk_num.zfill(3)
            chunk_filename = f"{args.library}_chunk_{chunk_num}.csv"
            s3_uri = f"s3://{args.s3_bucket}/input/{args.library}/{chunk_filename}"
            local_chunk = Path(tmpdir) / chunk_filename

            log.info(f"Chunk {chunk_num}: downloading from {s3_uri} ...")
            try:
                s3_download(s3_uri, local_chunk)
            except RuntimeError as e:
                log.error(f"  {e} — skipping")
                continue

            results = debug_chunk(
                chunk_file=local_chunk,
                library=args.library,
                sif=args.sif,
                ersilia_bin=args.ersilia_bin,
                timeout=args.timeout,
            )
            all_results.extend(results)

    # Write full results CSV
    out_csv = args.output_dir / f"{args.library}_{args.model_id}_debug.csv"
    fieldnames = ["library", "chunk_file", "smiles_position", "smiles", "status", "details"]
    with open(out_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(all_results)
    log.info(f"\nFull results written to: {out_csv}")

    # Summary
    failures = [r for r in all_results if r["status"] == "FAIL"]
    log.info(f"\n{'='*65}")
    log.info(f"SUMMARY — {args.library} / {args.model_id}")
    log.info(f"{'='*65}")
    log.info(f"Total tested : {len(all_results)}")
    log.info(f"Passed       : {sum(1 for r in all_results if r['status'] == 'OK')}")
    log.info(f"Failed       : {len(failures)}")
    log.info(f"Skipped      : {sum(1 for r in all_results if r['status'] == 'SKIP')}")

    if failures:
        log.info(f"\nFailing SMILES:")
        log.info(f"{'Chunk':<30} {'Position':>9}  {'Status':<12}  SMILES")
        log.info(f"{'-'*65}")
        for r in failures:
            log.info(f"{r['chunk_file']:<30} {r['smiles_position']:>9}  {r['details']:<12}  {r['smiles'][:50]}")
    log.info(f"{'='*65}")


if __name__ == "__main__":
    main()
