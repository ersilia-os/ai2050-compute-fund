#!/usr/bin/env python3
"""
Heavy-atom RMSD of docked poses to a reference pose: symmetry-aware, no superposition.

The reference (a `_LIG.pdb` HETATM block, heavy atoms only, no bond orders) and the
docked molecule (built from SMILES, protonated, with hydrogens) can disagree on bond
orders, charges and aromaticity even when they are the same compound. Both are therefore
reduced to a bare graph (heavy atoms + connectivity + element) before atoms are
matched. RMSD is the minimum over all graph automorphisms, so symmetric groups (phenyl
flips, carboxylate oxygens) are not penalised.

Reports only. No pose-recovery cutoff is applied here.

Usage:
    python pose_rmsd.py <reference .pdb | .sdf> <poses .sdf>
"""

import argparse
import sys

import numpy as np
from rdkit import Chem, RDLogger

MAX_MATCHES = 100000


def read_reference(path):
    if path.endswith(".pdb"):
        return Chem.MolFromPDBFile(path, removeHs=True, sanitize=False, proximityBonding=True)
    return next(iter(Chem.SDMolSupplier(path, removeHs=False, sanitize=False)), None)


def bare_graph(mol):
    """Heavy atoms, single bonds, no charges/aromaticity; coordinates preserved."""
    rw = Chem.RWMol(mol)
    for idx in sorted((a.GetIdx() for a in rw.GetAtoms() if a.GetAtomicNum() == 1), reverse=True):
        rw.RemoveAtom(idx)
    for atom in rw.GetAtoms():
        atom.SetFormalCharge(0)
        atom.SetIsAromatic(False)
        atom.SetNoImplicit(True)
        atom.SetNumExplicitHs(0)
    for bond in rw.GetBonds():
        bond.SetBondType(Chem.BondType.SINGLE)
        bond.SetIsAromatic(False)
    mol = rw.GetMol()
    mol.UpdatePropertyCache(strict=False)
    Chem.FastFindRings(mol)  # substructure matching needs ring info on an unsanitised mol
    return mol


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reference")
    ap.add_argument("poses")
    args = ap.parse_args()
    RDLogger.DisableLog("rdApp.*")

    ref = read_reference(args.reference)
    if ref is None:
        sys.exit(f"ERROR: could not read reference {args.reference}")
    ref = bare_graph(ref)
    ref_xyz = ref.GetConformer().GetPositions()

    for i, pose in enumerate(Chem.SDMolSupplier(args.poses, removeHs=False, sanitize=False), 1):
        if pose is None:
            print(f"pose {i}: unreadable")
            continue
        probe = bare_graph(pose)
        if probe.GetNumAtoms() != ref.GetNumAtoms():
            print(f"pose {i}: heavy-atom count differs ({probe.GetNumAtoms()} vs reference {ref.GetNumAtoms()})")
            continue
        matches = ref.GetSubstructMatches(probe, uniquify=False, useChirality=False, maxMatches=MAX_MATCHES)
        if not matches:
            print(f"pose {i}: no graph match to the reference (different compound?)")
            continue
        probe_xyz = probe.GetConformer().GetPositions()
        best = min(np.sqrt(np.mean(np.sum((ref_xyz[list(m)] - probe_xyz) ** 2, axis=1))) for m in matches)
        print(f"pose {i}: RMSD {best:.2f} A  ({probe.GetNumAtoms()} heavy atoms, {len(matches)} mappings)")


if __name__ == "__main__":
    main()
