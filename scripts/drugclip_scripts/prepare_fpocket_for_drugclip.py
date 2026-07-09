#!/usr/bin/env python3
"""
Convert fpocket output into the co-crystallized PDB format expected by encode_pockets.py.

encode_pockets.py requires files named {anything}_{LIGAND}.pdb and uses the ligand
coordinates to define the binding pocket (residues within 6 Å).  fpocket output has
no ligand, so this script:

  1. Reads the full clean protein PDB (all atoms, no STP noise).
  2. Computes the centroid of each pocket from the pocket{N}_atm.pdb contact atoms.
  3. Appends a single dummy HETATM (resname LIG) at that centroid to the full protein.
  4. Writes {prefix}_pocket{N}_LIG.pdb — one file per pocket.

encode_pockets.py then extracts COMPLETE residues (all backbone + sidechain atoms)
within 6 Å of the centroid, matching the training data format.

Usage:
    python prepare_fpocket_for_drugclip.py \
        --protein     /path/to/protein.pdb          \
        --fpocket-dir /path/to/fpocket_out/pockets  \
        --output-dir  /path/to/pocket_inputs        \
        --prefix      qcrB                          \
        [--top N]     # only prepare the N best-scoring pockets (default: all)
"""

import argparse
import os
import re
import glob
import numpy as np


def parse_atom_coords(lines):
    coords = []
    for line in lines:
        if line.startswith("ATOM") or line.startswith("HETATM"):
            try:
                x = float(line[30:38])
                y = float(line[38:46])
                z = float(line[46:54])
                coords.append([x, y, z])
            except ValueError:
                pass
    return np.array(coords) if coords else None


def pocket_centroid(atm_pdb_path):
    with open(atm_pdb_path) as f:
        lines = f.readlines()
    coords = parse_atom_coords(lines)
    if coords is None:
        return None
    return coords.mean(axis=0)


def last_serial(protein_lines):
    for line in reversed(protein_lines):
        if line.startswith("ATOM") or line.startswith("HETATM"):
            try:
                return int(line[6:11]) + 1
            except ValueError:
                pass
    return 1


def make_hetatm_line(serial, x, y, z, resname="LIG", chain="L", resnum=1):
    return (
        f"HETATM{serial:5d}  C1  {resname:3s} {chain}{resnum:4d}    "
        f"{x:8.3f}{y:8.3f}{z:8.3f}  1.00  0.00           C  \n"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--protein", required=True,
                        help="Clean full-protein PDB (no STP/HETATM noise)")
    parser.add_argument("--fpocket-dir", required=True,
                        help="Directory containing pocket{N}_atm.pdb files")
    parser.add_argument("--output-dir", required=True,
                        help="Directory to write {prefix}_pocket{N}_LIG.pdb files")
    parser.add_argument("--prefix", default="protein",
                        help="Protein name prefix for output filenames")
    parser.add_argument("--top", type=int, default=None,
                        help="Only prepare the top N pockets (fpocket ranks by score)")
    args = parser.parse_args()

    with open(args.protein) as f:
        protein_lines = [l for l in f if l.startswith("ATOM")]

    if not protein_lines:
        print(f"ERROR: no ATOM records in {args.protein}")
        return

    serial = last_serial(protein_lines)

    pattern = os.path.join(args.fpocket_dir, "pocket*_atm.pdb")
    atm_files = sorted(glob.glob(pattern),
                       key=lambda p: int(re.search(r"pocket(\d+)_atm", p).group(1)))

    if not atm_files:
        print(f"ERROR: no pocket*_atm.pdb files found in {args.fpocket_dir}")
        return

    if args.top:
        atm_files = atm_files[:args.top]

    os.makedirs(args.output_dir, exist_ok=True)
    print(f"Protein : {args.protein} ({len(protein_lines)} ATOM records)")
    print(f"Pockets : {len(atm_files)} → {args.output_dir}")

    ok = 0
    for atm_path in atm_files:
        num = int(re.search(r"pocket(\d+)_atm", atm_path).group(1))
        centroid = pocket_centroid(atm_path)
        if centroid is None:
            print(f"  SKIP pocket {num}: no coordinates")
            continue

        out_name = f"{args.prefix}-pocket{num:02d}_LIG.pdb"
        out_path = os.path.join(args.output_dir, out_name)

        with open(out_path, "w") as f:
            f.writelines(protein_lines)
            f.write(make_hetatm_line(serial, *centroid))

        print(f"  pocket {num:2d} → {out_name}  centroid ({centroid[0]:.1f}, {centroid[1]:.1f}, {centroid[2]:.1f})")
        ok += 1

    print(f"\nDone: {ok}/{len(atm_files)} pockets written to {args.output_dir}")
    print(f"\nNext step — encode with DrugCLIP:")
    print(f"  apptainer exec --nv \\")
    print(f"    --bind <weights_dir>:/drugclip/data/model_weights \\")
    print(f"    --bind {args.output_dir}:{args.output_dir} \\")
    print(f"    drugclip_pocket.sif \\")
    print(f"    python /drugclip/unimol/encode_pockets.py \\")
    print(f"      --user-dir /drugclip/unimol \\")
    print(f"      /drugclip/dict \\")
    print(f"      --task drugclip --loss in_batch_softmax --arch drugclip \\")
    print(f"      --max-pocket-atoms 256 --seed 1 \\")
    print(f"      --num-workers 0 --ddp-backend=c10d \\")
    print(f"      --pocket-dir {args.output_dir} \\")
    print(f"      --path <checkpoint.pt> \\")
    print(f"      --fp16")


if __name__ == "__main__":
    main()
