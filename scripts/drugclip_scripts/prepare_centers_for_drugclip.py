#!/usr/bin/env python3
"""
Convert AI2050 target pocket data (apo PDB + pocket-center files + refined ensemble)
into the co-crystallized PDB format expected by encode_pockets.py.

Unlike prepare_fpocket_for_drugclip.py (which reads fpocket pocket*_atm.pdb and
computes centroids), the AI2050 targets ship the pocket center directly as a
`*_center.txt` file (one line: "x, y, z" in Angstroms).  This adapter reproduces the
original DrugCLIP screen by encoding EVERY refined conformation of each pocket:

  1. For each `<prefix>_<pocket>_center.txt`, read the 3 center coordinates.
     - <prefix> = AF-<UniProt>-F1-model_v4_<domain>   (the receptor / domain)
     - <pocket> = raw token, either "pocket3" or a bare number like "2"
       (both conventions coexist and "2" != "pocket2" — never normalise).
  2. Glob that pocket's refined conformations:
       refined/<prefix>_<pocket>_*_complex_refined.pdb
     The glob is anchored on the literal "_<domain>_<pocket>_" so a bare "2"
     never matches conformation-index 2 of another pocket, and the optional
     trailing "_<pdbid>" is absorbed by "*".
  3. For each matched refined PDB: keep heavy-atom ATOM records only (drop
     hydrogens, CONECT/TER/TITLE), and append one dummy HETATM (resname LIG) at
     the pocket center — encode_pockets.py then extracts complete residues within
     6 A of that atom.
  4. Write one <refined-stem-with-dashes>_LIG.pdb per conformation.  Underscores in
     the stem are replaced with dashes so the filename has exactly ONE underscore
     (right before _LIG), which is what encode_pockets.py's ligand-name regex
     (substring between first "_" and last ".") requires.

Also emits manifest.csv mapping each output file back to its pocket, so downstream
screening can max-pool similarity scores across the conformations of each pocket.
(encode_pockets.py keeps every conformation's embedding separately.)

Usage:
    python prepare_centers_for_drugclip.py \
        --target-dir /path/to/targets/P00519 \
        --out-dir    /path/to/staging/P00519/pockets
"""

import argparse
import csv
import glob
import os
import re

CENTER_RE = re.compile(r"^(AF-(.+?)-F1-model_v4_(\d+))_(.+)_center\.txt$")


def read_center(path):
    """Return [x, y, z] floats from a one-line '<x>, <y>, <z>' center file."""
    with open(path) as f:
        line = f.readline().strip()
    parts = [p.strip() for p in line.split(",")]
    if len(parts) != 3:
        return None
    try:
        return [float(p) for p in parts]
    except ValueError:
        return None


def is_hydrogen(line):
    """True if an ATOM line is a hydrogen (element col 77-78, else atom-name heuristic)."""
    element = line[76:78].strip()
    if element:
        return element == "H"
    name = line[12:16].strip().lstrip("0123456789")
    return name.startswith("H")


def heavy_atom_lines(pdb_path):
    """Read a PDB, return its heavy-atom ATOM records only (drop H / non-ATOM)."""
    out = []
    with open(pdb_path) as f:
        for line in f:
            if line.startswith("ATOM") and not is_hydrogen(line):
                out.append(line)
    return out


def last_serial(atom_lines):
    for line in reversed(atom_lines):
        try:
            return int(line[6:11]) + 1
        except ValueError:
            pass
    return 1


def make_hetatm_line(serial, x, y, z, resname="LIG", chain="L", resnum=1):
    # Matches prepare_fpocket_for_drugclip.py's dummy-ligand format exactly.
    return (
        f"HETATM{serial:5d}  C1  {resname:3s} {chain}{resnum:4d}    "
        f"{x:8.3f}{y:8.3f}{z:8.3f}  1.00  0.00           C  \n"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target-dir", required=True,
                    help="One UniProt target folder (contains *_center.txt, apo PDBs, refined/)")
    ap.add_argument("--out-dir", required=True,
                    help="Output pockets dir; writes <stem>_LIG.pdb + manifest.csv here")
    ap.add_argument("--dry-run", action="store_true",
                    help="Report what would be written without writing PDBs")
    args = ap.parse_args()

    target_dir = os.path.abspath(args.target_dir)
    refined_dir = os.path.join(target_dir, "refined")
    center_files = sorted(glob.glob(os.path.join(target_dir, "*_center.txt")))

    if not center_files:
        print(f"  {os.path.basename(target_dir)}: no *_center.txt files — skipping")
        return 0

    if not args.dry_run:
        os.makedirs(args.out_dir, exist_ok=True)

    manifest = []
    n_written = 0
    n_pockets = 0
    n_no_refined = 0

    for cpath in center_files:
        fn = os.path.basename(cpath)
        m = CENTER_RE.match(fn)
        if not m:
            print(f"  WARN unparseable center file: {fn}")
            continue
        prefix, uniprot, domain, pocket = m.group(1), m.group(2), m.group(3), m.group(4)

        center = read_center(cpath)
        if center is None:
            print(f"  WARN bad center coords in: {fn}")
            continue

        # Glob refined confs, anchored on the literal "_<domain>_<pocket>_".
        pattern = os.path.join(refined_dir, f"{prefix}_{pocket}_*_complex_refined.pdb")
        confs = sorted(glob.glob(pattern))
        n_pockets += 1
        if not confs:
            print(f"  WARN no refined confs for {uniprot} domain {domain} pocket '{pocket}'")
            n_no_refined += 1
            continue

        for conf_path in confs:
            conf_base = os.path.basename(conf_path)
            stem = conf_base[:-4] if conf_base.endswith(".pdb") else conf_base
            # conf label = piece between "_<domain>_<pocket>_" and "_complex_refined"
            conf_label = stem
            inner = re.match(rf"^{re.escape(prefix)}_{re.escape(pocket)}_(.+)_complex_refined$", stem)
            if inner:
                conf_label = inner.group(1)
            out_stem = stem.replace("_", "-")
            out_name = f"{out_stem}_LIG.pdb"
            pocket_key = f"{out_stem}_LIG_L_1"

            atoms = heavy_atom_lines(conf_path)
            if not atoms:
                print(f"  WARN no heavy atoms in {conf_base} — skipping")
                continue

            if not args.dry_run:
                out_path = os.path.join(args.out_dir, out_name)
                with open(out_path, "w") as f:
                    f.writelines(atoms)
                    f.write(make_hetatm_line(last_serial(atoms), *center))
            n_written += 1

            manifest.append({
                "pocket_file": out_name,
                "pocket_key": pocket_key,
                "uniprot": uniprot,
                "domain": domain,
                "pocket": pocket,
                "conf": conf_label,
                "center_x": center[0],
                "center_y": center[1],
                "center_z": center[2],
                "source_refined_pdb": conf_base,
            })

    if not args.dry_run and manifest:
        man_path = os.path.join(args.out_dir, "manifest.csv")
        with open(man_path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(manifest[0].keys()))
            w.writeheader()
            w.writerows(manifest)

    tag = "[dry-run] " if args.dry_run else ""
    print(f"  {tag}{os.path.basename(target_dir)}: {n_pockets} pockets, "
          f"{n_written} conformation PDBs"
          + (f", {n_no_refined} pockets with NO refined confs" if n_no_refined else ""))
    return n_written


if __name__ == "__main__":
    main()
