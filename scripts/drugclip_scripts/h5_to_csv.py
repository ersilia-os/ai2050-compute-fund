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


def loader_row_order(all_smiles, success_smiles):
    """Map h5 row index → SMILES, accounting for the encoder's lexicographic ordering.

    unimol's load_mols_dataset_dtwg (Drug-The-Whole-Genome/unimol/tasks/drugclip.py:498)
    does `sorted(list(set(keys)))` on the LMDB "success" keys, which are STRINGS. The
    dataset is therefore ordered LEXICOGRAPHICALLY — "0", "1", "10", "100", "1000", ... —
    whereas the companion .smiles.txt is written in input order. mol_reps row r holds the
    molecule at lexicographic position r, NOT input position r.

    The keys are written as `str(n_ok)` (smiles_to_lmdb.py:155), a counter over SUCCESSFUL
    molecules — not the input row index — so key i belongs to line i of .smiles.txt and the
    permutation follows from the success count alone.

    `all_smiles` is accepted for call-site compatibility and deliberately unused: deriving
    the keys from input row indices is wrong for any chunk where RDKit dropped a molecule,
    because the missing index shifts every lexicographic position after it.

    Returns the SMILES in h5 row order.
    """
    order = sorted(range(len(success_smiles)), key=str)
    return [success_smiles[o] for o in order]


def main():
    parser = argparse.ArgumentParser(
        description="DrugCLIP HDF5 + SMILES index → ersilia CSV"
    )
    parser.add_argument("--input",        required=True, help="Original chunk CSV (all molecules)")
    parser.add_argument("--h5",           required=True, help="mol_reps.h5 from encode_mols.py")
    parser.add_argument("--smiles-index", required=True, help="Companion .smiles.txt (successful molecules only)")
    parser.add_argument("--output",       required=True, help="Output CSV path")
    parser.add_argument("--row-order", choices=["lexicographic", "input"], default="lexicographic",
                        help="How h5 rows map to .smiles.txt. 'lexicographic' (default) undoes the "
                             "string sort in drugclip.py:498. Switch to 'input' ONLY if the sif is "
                             "ever rebuilt with that sort fixed — otherwise you double-correct.")
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

    # ── Reject incomplete encodes ─────────────────────────────────────────────
    # require_dataset() pre-allocates zeros and the encode loop fills fold-major, so a job
    # that died part-way leaves a correctly-shaped h5 whose later folds are all zero. A row
    # with only fold 0 written is not all-zero, so nothing but a per-fold norm check spots it.
    if len(embeddings):
        fold_norms = np.linalg.norm(embeddings.reshape(len(embeddings), 6, 128), axis=2)
        if float(fold_norms.min()) < 0.9:
            complete = int((fold_norms > 0.9).all(axis=1).sum())
            log.error(f"Incomplete encode: only {complete}/{len(embeddings)} rows have all 6 folds")
            sys.exit(1)

    # ── Pair rows with molecules ──────────────────────────────────────────────
    if args.row_order == "lexicographic":
        row_smiles = loader_row_order(all_smiles, success_smiles)
        if row_smiles is None:
            log.error("Cannot recover encoder row order: a success SMILES is not in the input CSV")
            sys.exit(1)
    else:
        row_smiles = success_smiles
    emb_of = {smi: embeddings[r] for r, smi in enumerate(row_smiles)}
    log.info(f"Row order  : {args.row_order}")

    # ── Write CSV ─────────────────────────────────────────────────────────────
    n_success = 0
    n_failed  = 0

    with open(output_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(HEADERS)

        for smi in all_smiles:
            key = hashlib.md5(smi.encode("utf-8")).hexdigest()
            emb = emb_of.get(smi)
            if emb is not None:
                writer.writerow([key, smi] + emb.tolist())
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
