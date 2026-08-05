#!/usr/bin/env python3
"""
Cavity-shaped pseudo-ligand pocket prep for DrugCLIP (fpocket-based).

Improves on prepare_centers_for_drugclip.py (single dummy atom at the pocket center).
Instead of one point, we reconstruct a *cavity-shaped* pseudo-ligand by running fpocket
on the apo structure and taking its alpha-sphere points near our known pocket center.
`encode_pockets.py` then keeps residues within 6 A of that pseudo-ligand — following the
pocket lining, much closer to the paper's "residues within 6 A of the generated ligand"
than a point or a symmetric ball.

Per target:
  1. For each apo PDB `AF-<ID>-F1-model_v4_<N>.pdb`, run fpocket → gather all alpha-sphere
     coordinates (every pocket*_vert.pqr) for that domain N.
  2. For each `<prefix>_<pocket>_center.txt`, take the alpha spheres within --cavity-radius
     of the center → the pseudo-ligand (fallback: a single dummy atom at the center if none).
  3. Append those as dummy HETATM LIG atoms (chain L, resnum 1) to every heavy-atom refined
     conformation of that pocket → `<refined-stem-with-dashes>_LIG.pdb`.

Filenames and pocket_keys are IDENTICAL to prepare_centers_for_drugclip.py, so a
pockets_index.csv built earlier still applies — only the pocket geometry changes.

Requires the `fpocket` binary on PATH (e.g. `conda run -n pymol`).

Usage:
    python prepare_fpocket_cavity_for_drugclip.py \
        --target-dir /path/to/targets/P00519 \
        --out-dir    /path/to/staging/P00519/pockets \
        --cavity-radius 8.0
"""

import argparse
import csv
import glob
import os
import re
import shutil
import subprocess
import tempfile

CENTER_RE = re.compile(r"^(AF-(.+?)-F1-model_v4_(\d+))_(.+)_center\.txt$")
APO_RE = re.compile(r"^AF-.+-F1-model_v4_\d+\.pdb$")


def read_center(path):
    with open(path) as f:
        parts = [p.strip() for p in f.readline().strip().split(",")]
    if len(parts) != 3:
        return None
    try:
        return [float(p) for p in parts]
    except ValueError:
        return None


def is_hydrogen(line):
    element = line[76:78].strip()
    if element:
        return element == "H"
    return line[12:16].strip().lstrip("0123456789").startswith("H")


def heavy_atom_lines(pdb_path):
    out = []
    with open(pdb_path) as f:
        for line in f:
            if line.startswith("ATOM") and not is_hydrogen(line):
                out.append(line)
    return out


def parse_coords(pdb_path):
    coords = []
    with open(pdb_path) as f:
        for l in f:
            if l.startswith(("ATOM", "HETATM")):
                try:
                    coords.append((float(l[30:38]), float(l[38:46]), float(l[46:54])))
                except ValueError:
                    pass
    return coords


def last_serial(atom_lines):
    for line in reversed(atom_lines):
        try:
            return int(line[6:11]) + 1
        except ValueError:
            pass
    return 1


def hetatm(serial, x, y, z, resname="LIG", chain="L", resnum=1):
    return (
        f"HETATM{serial:5d}  C1  {resname:>3s} {chain}{resnum:4d}    "
        f"{x:8.3f}{y:8.3f}{z:8.3f}  1.00  0.00           C  \n"
    )


def run_fpocket(apo_pdb, workdir, fpocket_bin):
    """Run fpocket on a copy of apo_pdb; return all alpha-sphere coords (list of xyz)."""
    stem = os.path.splitext(os.path.basename(apo_pdb))[0]
    local = os.path.join(workdir, stem + ".pdb")
    shutil.copy(apo_pdb, local)
    subprocess.run([fpocket_bin, "-f", local], cwd=workdir,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    pockets_dir = os.path.join(workdir, stem + "_out", "pockets")
    spheres = []
    for vp in glob.glob(os.path.join(pockets_dir, "pocket*_vert.pqr")):
        spheres.extend(parse_coords(vp))
    return spheres


def within(spheres, center, radius):
    r2 = radius * radius
    cx, cy, cz = center
    return [(x, y, z) for (x, y, z) in spheres
            if (x - cx) ** 2 + (y - cy) ** 2 + (z - cz) ** 2 <= r2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target-dir", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--cavity-radius", type=float, default=8.0,
                    help="Alpha spheres within this radius (A) of the center form the pseudo-ligand.")
    ap.add_argument("--fpocket-bin", default="fpocket")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    target_dir = os.path.abspath(args.target_dir)
    refined_dir = os.path.join(target_dir, "refined")
    center_files = sorted(glob.glob(os.path.join(target_dir, "*_center.txt")))
    if not center_files:
        print(f"  {os.path.basename(target_dir)}: no *_center.txt — skipping")
        return

    # Run fpocket once per apo PDB (domain) → alpha spheres by domain
    workdir = tempfile.mkdtemp(prefix="fpocket_")
    spheres_by_domain = {}
    try:
        for pdb in sorted(glob.glob(os.path.join(target_dir, "*.pdb"))):
            if not APO_RE.match(os.path.basename(pdb)):
                continue
            dom = re.search(r"model_v4_(\d+)\.pdb$", os.path.basename(pdb)).group(1)
            spheres_by_domain[dom] = run_fpocket(pdb, workdir, args.fpocket_bin)

        if not args.dry_run:
            os.makedirs(args.out_dir, exist_ok=True)

        manifest, n_written, n_pockets, n_no_refined, n_fallback = [], 0, 0, 0, 0

        for cpath in center_files:
            fn = os.path.basename(cpath)
            m = CENTER_RE.match(fn)
            if not m:
                print(f"  WARN unparseable center file: {fn}")
                continue
            prefix, uniprot, domain, pocket = m.group(1), m.group(2), m.group(3), m.group(4)
            center = read_center(cpath)
            if center is None:
                print(f"  WARN bad center coords: {fn}")
                continue

            spheres = spheres_by_domain.get(domain, [])
            lig_atoms = within(spheres, center, args.cavity_radius)
            if not lig_atoms:
                lig_atoms = [tuple(center)]   # fallback: single dummy atom
                n_fallback += 1

            confs = sorted(glob.glob(os.path.join(refined_dir, f"{prefix}_{pocket}_*_complex_refined.pdb")))
            n_pockets += 1
            if not confs:
                print(f"  WARN no refined confs for {uniprot} d{domain} pocket '{pocket}'")
                n_no_refined += 1
                continue

            for conf_path in confs:
                conf_base = os.path.basename(conf_path)
                stem = conf_base[:-4] if conf_base.endswith(".pdb") else conf_base
                inner = re.match(rf"^{re.escape(prefix)}_{re.escape(pocket)}_(.+)_complex_refined$", stem)
                conf_label = inner.group(1) if inner else stem
                out_stem = stem.replace("_", "-")
                out_name = f"{out_stem}_LIG.pdb"
                pocket_key = f"{out_stem}_LIG_L_1"

                atoms = heavy_atom_lines(conf_path)
                if not atoms:
                    print(f"  WARN no heavy atoms in {conf_base}")
                    continue

                if not args.dry_run:
                    with open(os.path.join(args.out_dir, out_name), "w") as f:
                        f.writelines(atoms)
                        s = last_serial(atoms)
                        for i, (x, y, z) in enumerate(lig_atoms):
                            f.write(hetatm(s + i, x, y, z))
                n_written += 1
                manifest.append({
                    "pocket_file": out_name, "pocket_key": pocket_key,
                    "uniprot": uniprot, "domain": domain, "pocket": pocket, "conf": conf_label,
                    "center_x": center[0], "center_y": center[1], "center_z": center[2],
                    "n_lig_atoms": len(lig_atoms), "source_refined_pdb": conf_base,
                })

        if not args.dry_run and manifest:
            with open(os.path.join(args.out_dir, "manifest.csv"), "w", newline="") as f:
                w = csv.DictWriter(f, fieldnames=list(manifest[0].keys()))
                w.writeheader()
                w.writerows(manifest)

        tag = "[dry-run] " if args.dry_run else ""
        print(f"  {tag}{os.path.basename(target_dir)}: {n_pockets} pockets, {n_written} conf PDBs"
              + (f", {n_fallback} pockets fell back to point (no alpha spheres near center)" if n_fallback else "")
              + (f", {n_no_refined} pockets w/o refined" if n_no_refined else ""))
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
