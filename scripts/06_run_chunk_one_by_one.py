#!/usr/bin/env python3
"""
Run an Ersilia SIF model on a chunk CSV one SMILES at a time.
=============================================================
For chunks that fail in batch mode (due to one or more problematic molecules),
this script processes each SMILES individually and produces a complete output
CSV — with real values for successes and empty result columns for failures.

The output file is a drop-in replacement for the normal batch result file
(same format, same row count as input), ready to upload to FSx/S3.

Progress is saved incrementally after every molecule, so the script can be
safely interrupted and restarted — it will skip already-processed rows.

Usage:
------
    python 06_run_chunk_one_by_one.py \
        --input  /path/to/Library_chunk_528.csv \
        --sif    /home/marina/models/models_sif/ai2050_sif/eos96f4_v1.sif \
        --model-id eos96f4_v1 \
        [--output    eos96f4_v1_results_528.csv]   # default: <model-id>_results_<chunk>.csv
        [--timeout   120]                           # seconds per SMILES (default: 120)
        [--ersilia-bin ersilia_apptainer]

Output columns:
---------------
    All input columns (key, smiles, ...) + model result columns.
    Rows where the model failed have empty strings in result columns.
"""

import argparse
import csv
import logging
import subprocess
import sys
import tempfile
from pathlib import Path

from tqdm import tqdm

csv.field_size_limit(10 * 1024 * 1024)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)

SMILES_COLS  = {"smiles", "canonical_smiles", "input"}
INPUT_COLS   = {"key", "input", "smiles", "canonical_smiles"}


def run_single_smiles(smi: str, sif: Path, ersilia_bin: str, timeout: int):
    """
    Run ersilia_apptainer on a single SMILES.

    Returns:
        (result_row: dict | None, error: str | None)
        result_row contains only the MODEL OUTPUT columns (not input columns).
        On failure, result_row is None and error contains the reason.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        input_csv  = Path(tmpdir) / "input.csv"
        output_csv = Path(tmpdir) / "output.csv"

        with open(input_csv, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["smiles"])
            writer.writerow([smi])

        try:
            result = subprocess.run(
                [ersilia_bin, "run", "--sif", str(sif),
                 "--input", str(input_csv), "--output", str(output_csv)],
                capture_output=True, text=True, timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            return None, f"TIMEOUT after {timeout}s"

        if result.returncode != 0:
            stderr = result.stderr.strip().replace("\n", " | ")
            return None, f"EXIT {result.returncode}: {stderr[:300]}"

        if not output_csv.exists():
            return None, "No output file produced"

        with open(output_csv, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            rows = list(reader)

        if not rows:
            return None, "Output file is empty"

        # Return only the result (non-input) columns
        row = rows[0]
        result_cols = {k: v for k, v in row.items()
                       if k.strip().lower() not in INPUT_COLS}
        return result_cols, None


def load_checkpoint(checkpoint_path: Path) -> dict[int, dict]:
    """Load previously processed rows from checkpoint CSV. Returns {row_idx: row_dict}."""
    done = {}
    if not checkpoint_path.exists():
        return done
    with open(checkpoint_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                idx = int(row["__idx__"])
                done[idx] = {k: v for k, v in row.items() if k != "__idx__"}
            except (KeyError, ValueError):
                pass
    log.info(f"Checkpoint: {len(done)} rows already processed — resuming")
    return done


def main():
    parser = argparse.ArgumentParser(
        description="Run Ersilia SIF on a chunk CSV one SMILES at a time"
    )
    parser.add_argument("--input",       required=True,
                        help="Input chunk CSV")
    parser.add_argument("--sif",         required=True, type=Path,
                        help="Path to model SIF file")
    parser.add_argument("--model-id",    required=True,
                        help="Model ID (e.g. eos96f4_v1) — used for output naming")
    parser.add_argument("--output",      default=None,
                        help="Output CSV path (default: <model-id>_results_<chunk>.csv)")
    parser.add_argument("--timeout",     type=int, default=120,
                        help="Seconds before a single SMILES run is abandoned (default: 120)")
    parser.add_argument("--ersilia-bin", default="ersilia_apptainer",
                        help="ersilia_apptainer binary (default: ersilia_apptainer)")
    args = parser.parse_args()

    input_path = Path(args.input)
    sif_path   = Path(args.sif)

    if not input_path.exists():
        log.error(f"Input file not found: {input_path}")
        sys.exit(1)
    if not sif_path.exists():
        log.error(f"SIF file not found: {sif_path}")
        sys.exit(1)

    # ── Derive output path ────────────────────────────────────────────────────
    if args.output:
        output_path = Path(args.output)
    else:
        chunk_num   = input_path.stem.split("_")[-1]
        output_path = Path(f"{args.model_id}_results_{chunk_num}.csv")

    checkpoint_path = output_path.with_suffix(".checkpoint.csv")

    log.info("=" * 65)
    log.info("Run Chunk One-by-One")
    log.info(f"  Input      : {input_path}")
    log.info(f"  SIF        : {sif_path}")
    log.info(f"  Model      : {args.model_id}")
    log.info(f"  Output     : {output_path}")
    log.info(f"  Timeout    : {args.timeout}s per SMILES")
    log.info("=" * 65)

    # ── Read input chunk ──────────────────────────────────────────────────────
    with open(input_path, newline="", encoding="utf-8") as f:
        reader     = csv.DictReader(f)
        fieldnames = reader.fieldnames or []
        rows       = list(reader)

    smiles_col = next(
        (col for col in fieldnames if col.strip().lower() in SMILES_COLS), None
    )
    if smiles_col is None:
        log.error(f"No SMILES column found. Columns: {fieldnames}")
        sys.exit(1)

    log.info(f"Input rows : {len(rows):,}  (SMILES col: '{smiles_col}')")

    # ── Load checkpoint ───────────────────────────────────────────────────────
    done = load_checkpoint(checkpoint_path)

    # ── Process ───────────────────────────────────────────────────────────────
    # Discover result columns from first successful run (or checkpoint)
    result_cols = None
    if done:
        first = next(iter(done.values()))
        result_cols = [k for k in first.keys() if k not in fieldnames]

    n_ok   = 0
    n_fail = 0
    all_output_rows = {}  # idx → full output row

    # Pre-fill from checkpoint
    for idx, row in done.items():
        all_output_rows[idx] = row
        if all(row.get(c, "") == "" for c in [k for k in row if k not in fieldnames]):
            n_fail += 1
        else:
            n_ok += 1

    pending = [i for i in range(len(rows)) if i not in done]

    with tqdm(total=len(rows), initial=len(done), unit="mol",
              desc=args.model_id, dynamic_ncols=True) as pbar:

        for idx in pending:
            row = rows[idx]
            smi = row.get(smiles_col, "").strip()

            if not smi:
                pbar.write(f"  [{idx}] Empty SMILES — skipping")
                result_row = {}
                n_fail += 1
            else:
                result_row, error = run_single_smiles(
                    smi, sif_path, args.ersilia_bin, args.timeout
                )
                if result_row is None:
                    pbar.write(f"  FAIL [{idx}] {smi[:60]} — {error}")
                    result_row = {}
                    n_fail += 1
                else:
                    n_ok += 1
                    if result_cols is None:
                        result_cols = list(result_row.keys())

            pbar.set_postfix(ok=n_ok, fail=n_fail)
            pbar.update(1)

            # Build full output row (input cols + result cols)
            if result_cols is None:
                out_row = {**row}
            else:
                out_row = {**row, **{c: result_row.get(c, "") for c in result_cols}}
            all_output_rows[idx] = out_row

            # ── Save checkpoint ───────────────────────────────────────────────
            current_fieldnames = list(fieldnames) + (result_cols or [])
            with open(checkpoint_path, "w", newline="", encoding="utf-8") as f:
                writer = csv.DictWriter(f, fieldnames=["__idx__"] + current_fieldnames,
                                        extrasaction="ignore")
                writer.writeheader()
                for i in sorted(all_output_rows):
                    writer.writerow({"__idx__": i, **all_output_rows[i]})

    # ── Write final output ────────────────────────────────────────────────────
    if result_cols is None:
        result_cols = []

    final_fieldnames = list(fieldnames) + result_cols
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with open(output_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=final_fieldnames, extrasaction="ignore")
        writer.writeheader()
        for idx in sorted(all_output_rows):
            writer.writerow(all_output_rows[idx])

    # Clean up checkpoint on success
    if checkpoint_path.exists():
        checkpoint_path.unlink()

    log.info("=" * 65)
    log.info(f"Done — {n_ok:,} succeeded, {n_fail:,} failed")
    log.info(f"Output : {output_path}  ({len(rows):,} rows)")
    log.info("=" * 65)

    if n_ok == 0:
        log.error("No molecules succeeded — output file may be unusable")
        sys.exit(1)


if __name__ == "__main__":
    main()
