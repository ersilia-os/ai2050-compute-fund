#!/usr/bin/env python3
"""
P2Rank pocket points as a DrugCLIP pseudo-ligand.

For targets whose reference ligand is wrong or missing, take every SAS point P2Rank assigned
to one predicted pocket and write them as a single LIG residue appended to protein.pdb.
`encode_pockets.py` keeps residues with any atom within 6 A of the ligand's non-H atoms and
discards the ligand, so the points act purely as a selection device.

P2Rank writes its points with element H.  The encoder drops H from the ligand coordinates
(`encode_pockets.py:105`), so the points are rewritten as C -- with H they would select
nothing.

Inputs, under --target-dir:
  protein.pdb
  p2rank/visualizations/data/protein.pdb_points.pdb.gz   (residue number = pocket rank)
  manifest.csv                                           (existing pocket; naming source --
                                                          if absent, pass --stem and --af-source)

Outputs, under --target-dir, one set per requested rank:
  ligands/p2rank<rank>_PTS.pdb          the points alone, for PyMOL
  pockets/<stem>-p2rank<rank>_LIG.pdb   protein + points; exactly one underscore
  pockets/manifest.csv                  one row per requested rank, as stage-ligand-pockets.sh
                                        needs.  REWRITTEN each run: pass every pocket the
                                        target should have in a single call.

--split RANK:K divides a pocket too large for the encoder (over 511 pocket atoms, or well past
the 256 DrugCLIP was trained on) into K k-means clusters of its points, written as
p2rank<rank>a, b, ... largest first.  Initialisation is farthest-point, so the split is
deterministic.  The cut follows point geometry, not any structural boundary.

--merge R1+R2 pools the points of adjacent pockets into one pseudo-ligand, p2rank<R1>-<R2>.
Ranks listed only in --merge are not also written on their own.

Prints the PLAN.md checks (ligand atoms, residues at 6 A, clash < 2.6 A, solvent > 5 A).
Reference from the 573 validated conformations: 29 atoms / 27 residues median, solvent max 0.19.

Usage:
    /home/marina/anaconda3/bin/python p2rank_pseudoligand.py \
        --target-dir data/mtb/P9WGK7 --pocket-rank 1
    /home/marina/anaconda3/bin/python p2rank_pseudoligand.py \
        --target-dir data/mtb/I6X5C9 --pocket-rank 1 2 3
    /home/marina/anaconda3/bin/python p2rank_pseudoligand.py \
        --target-dir data/mtb/O50442 --pocket-rank 1 2 3 \
        --stem AF-O50442-F1-model-Rv1186c --af-source AFDB-v6
    /home/marina/anaconda3/bin/python p2rank_pseudoligand.py \
        --target-dir data/mtb/P9WNF9 --pocket-rank 1 2 --split 1:2
    /home/marina/anaconda3/bin/python p2rank_pseudoligand.py \
        --target-dir data/mtb/P9WP37 --pocket-rank 1 2 3 --merge 5+6
"""

import argparse
import csv
import glob
import gzip
import os

import numpy as np

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--target-dir", required=True)
parser.add_argument("--pocket-rank", type=int, nargs="+", default=[])
parser.add_argument("--stem", help="file stem, e.g. AF-O50442-F1-model-Rv1186c; only when there is no manifest.csv")
parser.add_argument("--af-source", help="AlphaFold model version, e.g. AFDB-v6; only when there is no manifest.csv")
parser.add_argument("--split", nargs="+", default=[], metavar="RANK:K",
                    help="split pocket RANK into K spatial clusters, e.g. 1:2 -> p2rank1a, p2rank1b")
parser.add_argument("--merge", nargs="+", default=[], metavar="R1+R2",
                    help="merge the points of several pockets into one, e.g. 5+6 -> p2rank5-6")
args = parser.parse_args()
if not (args.pocket_rank or args.merge):
    parser.error("give --pocket-rank and/or --merge")

MANIFEST_FIELDS = [
    "pocket_file", "pocket_key", "uniprot", "domain", "pocket", "conf", "center_x", "center_y",
    "center_z", "n_lig_atoms", "het_code", "source", "route", "af_source", "align_rmsd",
    "n_ligands_in_site", "clash_frac", "solvent_frac",
]

tdir = args.target_dir
points_file = os.path.join(tdir, "p2rank", "visualizations", "data", "protein.pdb_points.pdb.gz")
ligands_dir = os.path.join(tdir, "ligands")
pockets_dir = os.path.join(tdir, "pockets")
os.makedirs(ligands_dir, exist_ok=True)
os.makedirs(pockets_dir, exist_ok=True)


def coords(line):
    return float(line[30:38]), float(line[38:46]), float(line[46:54])


with open(os.path.join(tdir, "protein.pdb")) as f:
    atom_lines = [l.rstrip("\n") for l in f if l.startswith("ATOM")]
prot_xyz = np.array([coords(l) for l in atom_lines])
prot_res = np.array([int(l[22:26]) for l in atom_lines])
last_serial = int(atom_lines[-1][6:11])

with gzip.open(points_file, "rt") as f:
    point_lines = [l for l in f if l.startswith("HETATM")]

# Existing manifest gives the file stem (e.g. AF-P9WGK7-F1-model-PrrB) and the shared columns.
# Targets never built before have none, so the stem and AFDB version come from the command line.
manifest_in = os.path.join(tdir, "manifest.csv")
if os.path.exists(manifest_in):
    with open(manifest_in) as f:
        reader = csv.DictReader(f)
        fields = reader.fieldnames
        old = next(reader)
    stem = old["pocket_file"].rsplit("-", 1)[0]
else:
    if not (args.stem and args.af_source):
        raise SystemExit(f"No {manifest_in}: pass --stem and --af-source")
    fields = MANIFEST_FIELDS
    old = dict.fromkeys(fields, "")
    old.update({"uniprot": os.path.basename(os.path.normpath(tdir)), "domain": 0, "af_source": args.af_source})
    stem = args.stem

def kmeans(x, k, n_iter=100):
    """Lloyd's k-means with farthest-point initialisation: deterministic, so no seed."""
    centres = [x[np.argmax(np.linalg.norm(x - x.mean(axis=0), axis=1))]]
    while len(centres) < k:
        d = np.linalg.norm(x[:, None, :] - np.array(centres)[None, :, :], axis=2).min(axis=1)
        centres.append(x[np.argmax(d)])
    centres = np.array(centres)
    for _ in range(n_iter):
        labels = np.argmin(np.linalg.norm(x[:, None, :] - centres[None, :, :], axis=2), axis=1)
        new = np.array([x[labels == i].mean(axis=0) for i in range(k)])
        if np.allclose(new, centres):
            break
        centres = new
    return labels


# Each entry: (site name, points, route).  Split pockets become p2rank<rank>a, b, ... in
# descending order of point count.
splits = dict(tuple(int(v) for v in s.split(":")) for s in args.split)
sites = []
for rank in args.pocket_rank:
    pts = np.array([coords(l) for l in point_lines if int(l[22:26]) == rank])
    if len(pts) == 0:
        raise SystemExit(f"No P2Rank points for pocket rank {rank} in {points_file}")
    k = splits.get(rank, 1)
    if k == 1:
        sites.append((f"p2rank{rank}", pts, "p2rank_points"))
        continue
    labels = kmeans(pts, k)
    for letter, i in zip("abcdefgh", np.argsort(-np.bincount(labels, minlength=k), kind="stable")):
        sites.append((f"p2rank{rank}{letter}", pts[labels == i], f"p2rank_points_kmeans{k}"))
for spec in args.merge:
    ranks = [int(v) for v in spec.split("+")]
    pts = np.array([coords(l) for l in point_lines if int(l[22:26]) in ranks])
    if len(pts) == 0:
        raise SystemExit(f"No P2Rank points for pockets {spec} in {points_file}")
    sites.append((f"p2rank{'-'.join(map(str, ranks))}", pts, "p2rank_points_merged"))

# A pocket file left over from an earlier run would be staged without a manifest row.
wanted = {f"{stem}-{site}_LIG.pdb" for site, _, _ in sites}
stale = [p for p in glob.glob(os.path.join(pockets_dir, "*_LIG.pdb")) if os.path.basename(p) not in wanted]
if stale:
    raise SystemExit(f"pockets/ holds files this run would not list in manifest.csv: {stale}")

rows = []
for site, pts, route in sites:
    pocket_file = f"{stem}-{site}_LIG.pdb"
    assert pocket_file.count("_") == 1, pocket_file

    het = [
        f"HETATM{last_serial + i + 1:5d} {('C' + str(i + 1)):<4s} LIG L   1    "
        f"{x:8.3f}{y:8.3f}{z:8.3f}  1.00  0.00           C"
        for i, (x, y, z) in enumerate(pts)
    ]
    with open(os.path.join(ligands_dir, f"{site}_PTS.pdb"), "w") as f:
        f.write("\n".join(het) + "\nEND\n")
    with open(os.path.join(pockets_dir, pocket_file), "w") as f:
        f.write("\n".join(atom_lines + het) + "\nEND\n")

    d = np.linalg.norm(pts[:, None, :] - prot_xyz[None, :, :], axis=2)
    selected = sorted(set(prot_res[(d <= 6).any(axis=0)]))
    clash = float((d.min(axis=1) < 2.6).mean())
    solvent = float((d.min(axis=1) > 5).mean())
    centre = pts.mean(axis=0)

    row = dict(old)
    row.update({
        "pocket_file": pocket_file,
        "pocket_key": f"{pocket_file[:-4]}_L_1",
        "pocket": site,
        "conf": 0,
        "center_x": round(centre[0], 3),
        "center_y": round(centre[1], 3),
        "center_z": round(centre[2], 3),
        "n_lig_atoms": len(pts),
        "het_code": "PTS",
        "source": "p2rank",
        "route": route,
        "align_rmsd": "",
        "n_ligands_in_site": "",
        "clash_frac": round(clash, 3),
        "solvent_frac": round(solvent, 3),
    })
    rows.append(row)

    print(f"{pocket_file}")
    print(f"  ligand atoms      {len(pts):4d}   (reference median 29)")
    print(f"  residues at 6 A   {len(selected):4d}   (reference median 27)")
    print(f"  pocket atoms      {int((d <= 6).any(axis=0).sum()):4d}   (encode cap 511)")
    print(f"  clash < 2.6 A     {clash:.2f}   (p90 0.63; not a reject)")
    print(f"  solvent > 5 A     {solvent:.2f}   (reject above 0.19)")
    print(f"  residues          {' '.join(map(str, selected))}")

with open(os.path.join(pockets_dir, "manifest.csv"), "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)
