#!/usr/bin/env python3
"""
SMILES -> neutral, 3D, explicit-H SDF, ready for `unidocktools ligandprep`.

ligandprep builds the torsion tree, atom types and charges, but it does NOT add
hydrogens, set protonation or generate coordinates: it reads the molecule's existing 3D
conformer. This script produces that input.

Per molecule:
  1. Neutralise (decision, 2026-10-02: every molecule is docked NEUTRAL, no pH model).
     RDKit's Uncharger removes charges where a neutral form exists (carboxylate -> acid,
     ammonium -> amine). Charges with no neutral form (e.g. quaternary ammonium) are
     kept, and the molecule is flagged with residual_charge != 0. Dimorphite-dl at pH 7.4
     was tried first and dropped: it protonated aryl-NH-alkyl linkers (aniline-like N)
     as if they were aliphatic amines.
  2. RDKit AddHs + ETKDGv3 embedding with a fixed random seed.
  3. MMFF94 optimisation. Vina keeps rings rigid while docking, so the starting ring
     geometry has to be sensible.

Molecules are never dropped silently. A SMILES with more than one fragment (a salt or
mixture) is NOT stripped to its largest piece; it goes to <out>.failed.csv with the
other failures (step and reason), for a human to decide.

Input is either one molecule (--smiles, --name) or a file of `SMILES name` lines
(--input; whitespace- or comma-separated, `#` comments skipped). Output is one
multi-molecule SDF; each record's title is the molecule name, which ligandprep uses as
the output file name. Each record carries input_smiles, neutral_smiles and
residual_charge properties.

Usage:
    python prepare_ligands.py --smiles "CCO" --name ethanol --out ligands_3d.sdf --seed 42
    python prepare_ligands.py --input leaders.smi --out ligands_3d.sdf --seed 42
"""

import argparse
import csv
import re
import sys

from rdkit import Chem, RDLogger
from rdkit.Chem import AllChem
from rdkit.Chem.MolStandardize import rdMolStandardize

MMFF_MAX_ITERS = 2000


def read_input(path):
    """Yield (smiles, name) from a `SMILES name` file."""
    with open(path) as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = re.split(r"[,\s]+", line, maxsplit=1)
            yield parts[0], (parts[1].strip() if len(parts) > 1 else f"mol_{i}")


def prepare(smiles, seed, uncharger):
    """Return (mol, None) on success or (None, (step, reason)) on failure."""
    mol = Chem.MolFromSmiles(smiles)
    if mol is None:
        return None, ("parse", "RDKit could not parse the SMILES")
    if len(Chem.GetMolFrags(mol)) > 1:
        return None, ("fragments", f"{len(Chem.GetMolFrags(mol))} fragments (salt or mixture); not stripped")

    try:
        mol = uncharger.uncharge(mol)
    except Exception as e:
        return None, ("neutralise", str(e))
    neutral_smiles = Chem.MolToSmiles(mol)
    residual_charge = Chem.GetFormalCharge(mol)

    mol = Chem.AddHs(mol)
    params = AllChem.ETKDGv3()
    params.randomSeed = seed
    if AllChem.EmbedMolecule(mol, params) != 0:
        return None, ("embed", "ETKDGv3 embedding failed")

    if not AllChem.MMFFHasAllMoleculeParams(mol):
        return None, ("mmff", "no MMFF94 parameters for this molecule")
    if AllChem.MMFFOptimizeMolecule(mol, maxIters=MMFF_MAX_ITERS) == -1:
        return None, ("mmff", "MMFF94 setup failed")

    mol.SetProp("input_smiles", smiles)
    mol.SetProp("neutral_smiles", neutral_smiles)
    mol.SetIntProp("residual_charge", residual_charge)
    return mol, None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--smiles", help="a single SMILES")
    src.add_argument("--input", help="file of `SMILES name` lines")
    ap.add_argument("--name", default="mol_1", help="name for --smiles (default mol_1)")
    ap.add_argument("--out", required=True, help="output SDF")
    ap.add_argument("--seed", type=int, required=True, help="ETKDG random seed (record it)")
    args = ap.parse_args()

    RDLogger.DisableLog("rdApp.*")
    uncharger = rdMolStandardize.Uncharger()
    molecules = [(args.smiles, args.name)] if args.smiles else list(read_input(args.input))

    writer = Chem.SDWriter(args.out)
    failures, charged = [], []
    for smiles, name in molecules:
        mol, err = prepare(smiles, args.seed, uncharger)
        if mol is None:
            failures.append({"name": name, "smiles": smiles, "step": err[0], "reason": err[1]})
            continue
        if mol.GetIntProp("residual_charge") != 0:
            charged.append((name, mol.GetProp("neutral_smiles"), mol.GetIntProp("residual_charge")))
        mol.SetProp("_Name", name)
        writer.write(mol)
    writer.close()

    n_ok = len(molecules) - len(failures)
    print(f"prepare_ligands: {n_ok}/{len(molecules)} prepared (neutral, seed {args.seed}) -> {args.out}",
          file=sys.stderr)
    if charged:
        print(f"prepare_ligands: {len(charged)} kept a charge with no neutral form (residual_charge != 0):",
              file=sys.stderr)
        for name, smi, q in charged[:20]:
            print(f"  {name}  charge {q:+d}  {smi}", file=sys.stderr)
    if failures:
        fail_path = args.out + ".failed.csv"
        with open(fail_path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["name", "smiles", "step", "reason"])
            w.writeheader()
            w.writerows(failures)
        print(f"prepare_ligands: {len(failures)} FAILED -> {fail_path}", file=sys.stderr)
        for r in failures[:20]:
            print(f"  {r['name']}  [{r['step']}] {r['reason']}", file=sys.stderr)


if __name__ == "__main__":
    main()
