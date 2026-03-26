#!/usr/bin/env python3
"""
Convert a SMILES CSV to LMDB format expected by DrugCLIP.

Generates a single 3D conformer per molecule using RDKit ETKDGv3.
Invalid SMILES or molecules where 3D generation fails are skipped.

Usage:
    python smiles_to_lmdb.py --input chunk.csv --output mols.lmdb

LMDB format produced:
    key:   b"0", b"1", ...  (sequential, only for successful molecules)
    value: pickle({ "smi": str, "atoms": list[str], "coordinates": ndarray(1, N, 3) })
    b"__len__": number of molecules written
"""

import argparse
import csv
import logging
import pickle
import sys
from pathlib import Path

import lmdb
import numpy as np
from rdkit import Chem
from rdkit.Chem import AllChem

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)

SMILES_COLS = {"smiles", "canonical_smiles", "input"}


def smiles_to_atoms_coords(smi: str):
    """
    Generate a single 3D conformer from a SMILES string.

    Returns:
        atoms        : list[str]  — heavy-atom symbols (hydrogens removed)
        coordinates  : ndarray    — shape (1, N, 3), single conformer

    Raises ValueError if SMILES is invalid or 3D generation fails.
    """
    mol = Chem.MolFromSmiles(smi)
    if mol is None:
        raise ValueError(f"Invalid SMILES: {smi[:80]}")

    mol = Chem.AddHs(mol)

    params = AllChem.ETKDGv3()
    params.randomSeed = 42
    result = AllChem.EmbedMolecule(mol, params)

    if result == -1:
        # Fallback: classic distance-geometry without ETKDG
        result = AllChem.EmbedMolecule(mol, AllChem.ETDG())

    if result == -1:
        raise ValueError(f"3D conformer generation failed: {smi[:80]}")

    AllChem.MMFFOptimizeMolecule(mol)
    mol = Chem.RemoveHs(mol)

    conf = mol.GetConformer()
    atoms = [atom.GetSymbol() for atom in mol.GetAtoms()]
    coords = conf.GetPositions()  # (N, 3)

    return atoms, coords[np.newaxis, :, :]  # (1, N, 3)


def main():
    parser = argparse.ArgumentParser(
        description="Convert SMILES CSV → LMDB for DrugCLIP"
    )
    parser.add_argument("--input",      required=True,
                        help="Input CSV file (must have a SMILES column)")
    parser.add_argument("--output",     required=True,
                        help="Output LMDB directory path")
    parser.add_argument("--smiles-col", default=None,
                        help="SMILES column name (auto-detected if omitted)")
    args = parser.parse_args()

    input_path  = Path(args.input)
    output_path = Path(args.output)

    # ── Read CSV ─────────────────────────────────────────────────────────────
    csv.field_size_limit(10 * 1024 * 1024)
    with open(input_path, newline="", encoding="utf-8") as f:
        reader    = csv.DictReader(f)
        fieldnames_lower = [c.strip().lower() for c in (reader.fieldnames or [])]

        if args.smiles_col:
            smiles_col = args.smiles_col
        else:
            smiles_col = next(
                (orig for orig, lower in zip(reader.fieldnames, fieldnames_lower)
                 if lower in SMILES_COLS),
                None,
            )

        if smiles_col is None:
            log.error(f"No SMILES column found. Columns: {reader.fieldnames}")
            sys.exit(1)

        rows = list(reader)

    log.info(f"Input      : {input_path}  ({len(rows):,} rows, SMILES col: '{smiles_col}')")
    log.info(f"Output     : {output_path}")

    # ── Write LMDB ───────────────────────────────────────────────────────────
    env = lmdb.open(
        str(output_path),
        map_size=1099511627776,  # 1 TB virtual — actual disk use is much smaller
        readonly=False,
        lock=False,
        readahead=False,
        meminit=False,
    )

    n_ok   = 0
    n_fail = 0

    with env.begin(write=True) as txn:
        for row in rows:
            smi = row[smiles_col].strip()
            if not smi:
                n_fail += 1
                continue

            try:
                atoms, coordinates = smiles_to_atoms_coords(smi)
            except Exception as e:
                log.warning(f"  SKIP [{n_ok + n_fail}]: {e}")
                n_fail += 1
                continue

            data = {
                "smi":         smi,
                "atoms":       atoms,
                "coordinates": coordinates,
            }
            txn.put(str(n_ok).encode("ascii"), pickle.dumps(data))
            n_ok += 1

        # Store molecule count — used by some LMDB dataset loaders
        txn.put(b"__len__", str(n_ok).encode("ascii"))

    env.close()

    log.info(f"Done — {n_ok:,} written, {n_fail:,} skipped")
    if n_fail > 0:
        log.warning(f"  {n_fail} molecules skipped (invalid SMILES or 3D gen failure)")

    # Exit non-zero if everything failed
    if n_ok == 0:
        log.error("No molecules were written to LMDB — aborting")
        sys.exit(1)


if __name__ == "__main__":
    main()
