#!/usr/bin/env python3
"""
Buried cavity volume at each pocket's grid centre, GenPack route vs template route.

Why
---
A pocket definition can only help if the site can physically hold a drug-sized molecule.
This measures, per pocket, how much enclosed free space sits at the authors' Glide grid
centre, in both the apo AlphaFold model and the refined conformations, so GenPack pockets
can be compared against template-route pockets -- where a real PDBbind ligand binds and the
true-ligand rebuild scores AUC 0.944.

Method (LIGSITE-style burial)
-----------------------------
Grid a cube around the centre. A grid point is protein if it lies within --occ of a heavy
atom, free otherwise. For each free point, scan 7 axes (3 cartesian + 4 body diagonals);
an axis is enclosed if protein is hit on BOTH sides within --scan (a protein-solvent-protein
event). Free points with >= --psp-min enclosed axes are pocket points. Report the volume,
centroid offset and elongation of the connected pocket component nearest the centre.

Burial rather than connectivity is deliberate: every druggable site is solvent-connected,
so a "does the free space reach bulk" test calls every site open and its volume is mostly
bulk solvent. That was tried first and is useless.

The grid parameters are LIGSITE-like defaults, not tuned. Absolute volumes depend on them;
compare routes measured with the same settings, never against an outside number.

This script REPORTS volumes only. It applies no cutoff and drops no pocket -- whether to
filter on volume, and where, is a decision for the user, and it is not yet validated against
per-pocket AUC (see docs/claude_sessions/2026-10-01_drugclip_genpack_molcraft.md).

Run on the laptop with any Python 3 + numpy + scipy:

    python3 pocket_burial.py --targets-dir <Targets>/targets --out-csv burial.csv
    python3 pocket_burial.py --targets-dir <Targets>/targets P00533 O00329
"""

import argparse
import csv
import glob
import os
import re
import sys

import numpy as np
from scipy.ndimage import label
from scipy.spatial import cKDTree

AXES = [(1, 0, 0), (0, 1, 0), (0, 0, 1),
        (1, 1, 1), (1, 1, -1), (1, -1, 1), (-1, 1, 1)]


def parse_heavy_xyz(path):
    """Heavy-atom coordinates. Schrodinger writes element as 'N1+', so strip the charge."""
    xyz = []
    with open(path) as f:
        for line in f:
            if not line.startswith(("ATOM", "HETATM")):
                continue
            m = re.match(r"[A-Za-z]+", line[76:78].strip())
            elem = m.group(0) if m else line[12:16].strip()[0]
            if elem.upper() == "H":
                continue
            xyz.append((float(line[30:38]), float(line[38:46]), float(line[46:54])))
    return np.asarray(xyz)


def read_center(path):
    with open(path) as f:
        return np.array([float(v) for v in f.read().strip().split(",")])


def shift(a, v):
    """Shift a boolean grid by one voxel along v, zero-filling the vacated face."""
    out = np.zeros_like(a)
    src, dst = [], []
    for k in v:
        if k > 0:
            src.append(slice(0, -1)); dst.append(slice(1, None))
        elif k < 0:
            src.append(slice(1, None)); dst.append(slice(0, -1))
        else:
            src.append(slice(None)); dst.append(slice(None))
    out[tuple(dst)] = a[tuple(src)]
    return out


def buried_volume(xyz, centre, args):
    """(volume A^3, centroid offset A, aniso b, aniso c) of the pocket component at centre."""
    ax = np.arange(-args.half, args.half + 1e-9, args.spacing)
    n = len(ax)
    gx, gy, gz = np.meshgrid(ax, ax, ax, indexing="ij")
    pts = np.stack([gx.ravel(), gy.ravel(), gz.ravel()], axis=1) + centre
    d, _ = cKDTree(xyz).query(pts, k=1)
    occ = (d < args.occ).reshape(n, n, n)

    steps = int(args.scan / args.spacing)
    psp = np.zeros((n, n, n), dtype=np.int8)
    for v in AXES:
        fwd = np.zeros_like(occ)
        bwd = np.zeros_like(occ)
        cur_f, cur_b = occ.copy(), occ.copy()
        for _ in range(steps):
            cur_f = shift(cur_f, v)
            cur_b = shift(cur_b, tuple(-k for k in v))
            fwd |= cur_f
            bwd |= cur_b
        psp += (fwd & bwd).astype(np.int8)

    pocket = ~occ & (psp >= args.psp_min)
    if not pocket.any():
        return 0.0, float("nan"), 0.0, 0.0

    lab, _ = label(pocket)
    ci = n // 2
    cid = lab[ci, ci, ci]
    if cid == 0:
        idx = np.argwhere(pocket)
        cid = lab[tuple(idx[np.argmin(np.linalg.norm(idx - ci, axis=1))])]
    mask = lab == cid
    pos = np.argwhere(mask) * args.spacing - args.half + centre
    off = float(np.linalg.norm(pos.mean(axis=0) - centre))
    b = c = 0.0
    if len(pos) >= 4:
        ev = np.clip(np.linalg.eigvalsh(np.cov((pos - pos.mean(axis=0)).T))[::-1], 1e-9, None)
        b, c = float(np.sqrt(ev[1] / ev[0])), float(np.sqrt(ev[2] / ev[0]))
    return float(mask.sum() * args.spacing ** 3), off, b, c


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("targets", nargs="*", help="UniProt IDs (default: every target)")
    ap.add_argument("--targets-dir", required=True,
                    help="Targets tree: <dir>/<UNIPROT>/{AF-*.pdb, *_center.txt, refined/}")
    ap.add_argument("--out-csv", default="", help="Also write one row per pocket here")
    ap.add_argument("--max-confs", type=int, default=4,
                    help="Refined conformations per pocket to measure (median reported)")
    ap.add_argument("--spacing", type=float, default=0.8, help="Grid spacing, A")
    ap.add_argument("--half", type=float, default=12.0, help="Half-width of the grid cube, A")
    ap.add_argument("--occ", type=float, default=2.7,
                    help="A grid point within this of a heavy atom is protein, A")
    ap.add_argument("--psp-min", type=int, default=5,
                    help="Enclosed axes (of 7) for a free point to count as pocket")
    ap.add_argument("--scan", type=float, default=14.0,
                    help="How far to look for the far wall along each axis, A")
    args = ap.parse_args()

    tdirs = sorted(d for d in glob.glob(os.path.join(args.targets_dir, "*"))
                   if os.path.isdir(d)
                   and (not args.targets or os.path.basename(d) in args.targets))
    if not tdirs:
        sys.exit(f"no target folders under {args.targets_dir}")

    rows = []
    print(f"{'target':<9}{'route':<10}{'pocket':<10}{'apo vol':>9}{'refined':>9}"
          f"{'delta':>8}{'offset':>8}{'aniso b/c':>12}{'n_conf':>8}")
    for tdir in tdirs:
        uni = os.path.basename(tdir)
        for cpath in sorted(glob.glob(os.path.join(tdir, "*_center.txt"))):
            m = re.match(r"^(.*)_([^_]+)$", os.path.basename(cpath)[:-len("_center.txt")])
            if not m:
                continue
            prefix, pocket = m.group(1), m.group(2)
            apo_path = os.path.join(tdir, prefix + ".pdb")
            confs = sorted(glob.glob(os.path.join(
                tdir, "refined", f"{prefix}_{pocket}_*_complex_refined.pdb")))
            if not (os.path.exists(apo_path) and confs):
                continue
            centre = read_center(cpath)
            apo_vol = buried_volume(parse_heavy_xyz(apo_path), centre, args)[0]
            meas = [buried_volume(parse_heavy_xyz(c), centre, args)
                    for c in confs[:args.max_confs]]
            row = {
                "uniprot": uni, "domain_prefix": prefix, "pocket": pocket,
                "route": "genpack" if pocket.startswith("pocket") else "template",
                "apo_vol": round(apo_vol, 1),
                "refined_vol": round(float(np.median([x[0] for x in meas])), 1),
                "offset": round(float(np.nanmedian([x[1] for x in meas])), 2),
                "aniso_b": round(float(np.median([x[2] for x in meas])), 3),
                "aniso_c": round(float(np.median([x[3] for x in meas])), 3),
                "n_conf": len(confs), "n_conf_measured": len(meas),
            }
            rows.append(row)
            print(f"{uni:<9}{row['route']:<10}{pocket:<10}{row['apo_vol']:>9.0f}"
                  f"{row['refined_vol']:>9.0f}{row['refined_vol'] - row['apo_vol']:>+8.0f}"
                  f"{row['offset']:>8.1f}"
                  f"{'  %.2f/%.2f' % (row['aniso_b'], row['aniso_c']):>12}"
                  f"{row['n_conf']:>8}")

    if args.out_csv and rows:
        with open(args.out_csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
        print(f"\nwrote {len(rows)} pockets -> {args.out_csv}")


if __name__ == "__main__":
    main()
