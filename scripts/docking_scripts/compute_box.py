#!/usr/bin/env python3
"""
Compute a Vina / Uni-Dock search box from a reference ligand.

Box definition (decision, 2026-10-01):
  centre   = midpoint of the reference ligand's heavy-atom bounding box
  size     = heavy-atom extent on that axis + 2 * padding   (padding on every side)
  padding  = 6 A, the same radius that defines a DrugCLIP pocket (residues with a heavy
             atom within 6 A of the ligand), so the Vina box and the DrugCLIP pocket
             cover the same region of the protein.

The box is fixed per pocket from the reference ligand, not per docked molecule, so a
leader larger than the reference ligand gets the same box.

Input is a PDB whose ligand is HETATM records with resname LIG (the targets_ligand
`_LIG.pdb` format: protein ATOM records + `HETATM ... LIG L 1`). Use --all-atoms for a
PDB that holds only the ligand under some other residue name.

Output on stdout is one line of Uni-Dock flags, ready for command substitution:
    --center_x 1.234 --center_y 5.678 --center_z 9.012 --size_x 22.1 --size_y 19.4 --size_z 18.0
A one-line summary (extent, volume) goes to stderr.

Usage:
    python compute_box.py AF-...-complex-refined_LIG.pdb
    python compute_box.py ligand.pdb --all-atoms --padding 6
"""

import argparse
import sys

DEFAULT_PADDING = 6.0


def ligand_heavy_coords(path, all_atoms=False):
    """Heavy-atom coordinates of the LIG residue (or every ATOM/HETATM with all_atoms)."""
    coords = []
    with open(path) as f:
        for line in f:
            if not line.startswith(("ATOM", "HETATM")):
                continue
            if not all_atoms and not (line.startswith("HETATM") and line[17:20].strip() == "LIG"):
                continue
            element = line[76:78].strip() or line[12:16].strip().lstrip("0123456789")[:1]
            if element.upper() in ("H", "D"):
                continue
            coords.append((float(line[30:38]), float(line[38:46]), float(line[46:54])))
    return coords


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pdb", help="_LIG.pdb (or a ligand-only PDB with --all-atoms)")
    ap.add_argument("--padding", type=float, default=DEFAULT_PADDING,
                    help=f"A added on every side of the ligand extent (default {DEFAULT_PADDING})")
    ap.add_argument("--all-atoms", action="store_true",
                    help="use every ATOM/HETATM record, not just resname LIG")
    args = ap.parse_args()

    coords = ligand_heavy_coords(args.pdb, args.all_atoms)
    if not coords:
        sys.exit(f"ERROR: no ligand heavy atoms found in {args.pdb}")

    center, size = [], []
    for axis in range(3):
        values = [c[axis] for c in coords]
        lo, hi = min(values), max(values)
        center.append((lo + hi) / 2)
        size.append((hi - lo) + 2 * args.padding)

    print(" ".join(
        [f"--center_{a} {c:.3f}" for a, c in zip("xyz", center)]
        + [f"--size_{a} {s:.3f}" for a, s in zip("xyz", size)]
    ))
    extent = [s - 2 * args.padding for s in size]
    volume = size[0] * size[1] * size[2]
    print(f"box: {len(coords)} heavy atoms, extent {extent[0]:.1f} x {extent[1]:.1f} x {extent[2]:.1f} A, "
          f"padding {args.padding:g} A, size {size[0]:.1f} x {size[1]:.1f} x {size[2]:.1f} A, "
          f"volume {volume:,.0f} A^3", file=sys.stderr)


if __name__ == "__main__":
    main()
