#!/usr/bin/env python3
"""
Convert DrugCLIP HDF5 embeddings + SMILES index → ersilia-format CSV.

Every molecule from the original input CSV appears in the output:
  - Successfully encoded molecules get their 768-dim embedding (6 folds × 128 dims).
  - Molecules that failed SMILES parsing or 3D conformer generation get empty result columns.

Output columns:
    key, input, fold-0-dim-000, ..., fold-0-dim-127, fold-1-dim-000, ..., fold-5-dim-127

Usage:
    python h5_to_csv.py \
        --input   chunk.csv          \
        --h5      mol_reps.h5        \
        --smiles-index mols.smiles.txt \
        --output  chunk_embeddings.csv
"""

import argparse
import csv
import hashlib
import logging
import sys
from pathlib import Path

import h5py
import numpy as np

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)

SMILES_COLS = {"smiles", "canonical_smiles", "input"}

HEADERS = (
    ["key", "input"]
    + [f"fold-{fold}-dim-{dim:03d}" for fold in range(6) for dim in range(128)]
)
EMPTY_RESULT = [""] * 768


def detect_smiles_col(fieldnames):
    lower = [c.strip().lower() for c in fieldnames]
    for orig, low in zip(fieldnames, lower):
        if low in SMILES_COLS:
            return orig
    return None


def main():
    parser = argparse.ArgumentParser(
        description="DrugCLIP HDF5 + SMILES index → ersilia CSV"
    )
    parser.add_argument("--input",        required=True, help="Original chunk CSV (all molecules)")
    parser.add_argument("--h5",           required=True, help="mol_reps.h5 from encode_mols.py")
    parser.add_argument("--smiles-index", required=True, help="Companion .smiles.txt (successful molecules only)")
    parser.add_argument("--output",       required=True, help="Output CSV path")
    args = parser.parse_args()

    input_path  = Path(args.input)
    h5_path     = Path(args.h5)
    index_path  = Path(args.smiles_index)
    output_path = Path(args.output)

    # ── Read all input SMILES ─────────────────────────────────────────────────
    csv.field_size_limit(10 * 1024 * 1024)
    with open(input_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        smiles_col = detect_smiles_col(reader.fieldnames or [])
        if smiles_col is None:
            log.error(f"No SMILES column found. Columns: {reader.fieldnames}")
            sys.exit(1)
        all_smiles = [row[smiles_col].strip() for row in reader]

    log.info(f"Input      : {input_path}  ({len(all_smiles):,} molecules, col='{smiles_col}')")

    # ── Read success SMILES index ─────────────────────────────────────────────
    with open(index_path, encoding="utf-8") as f:
        success_smiles = [line.strip() for line in f if line.strip()]

    log.info(f"SMILES index: {index_path}  ({len(success_smiles):,} successful)")

    # ── Load h5 embeddings ────────────────────────────────────────────────────
    with h5py.File(h5_path, "r") as f:
        embeddings = f["mol_reps"][:]   # (N_success, 768), float32

    log.info(f"HDF5       : {h5_path}  shape={embeddings.shape}")

    if len(success_smiles) != len(embeddings):
        log.error(
            f"SMILES index has {len(success_smiles)} entries but h5 has {len(embeddings)} rows"
        )
        sys.exit(1)

    # ── Write CSV ─────────────────────────────────────────────────────────────
    n_success = 0
    n_failed  = 0

    success_iter = iter(zip(success_smiles, embeddings))
    next_smi, next_emb = next(success_iter, (None, None))

    with open(output_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(HEADERS)

        for smi in all_smiles:
            key = hashlib.md5(smi.encode("utf-8")).hexdigest()
            if smi == next_smi:
                writer.writerow([key, smi] + next_emb.tolist())
                next_smi, next_emb = next(success_iter, (None, None))
                n_success += 1
            else:
                writer.writerow([key, smi] + EMPTY_RESULT)
                n_failed += 1

    log.info(f"Output     : {output_path}")
    log.info(f"Done — {n_success:,} with embeddings, {n_failed:,} with empty results")

    if n_failed > 0:
        log.warning(f"  {n_failed} molecules had no embedding (failed SMILES/3D generation)")


if __name__ == "__main__":
    main()
