#!/usr/bin/env python3
"""
One PyMOL session per (target, domain) with ALL of that domain's pockets overlaid.

Answers the question a per-pocket view cannot: where do a target's pockets sit relative
to each other on one structure? Do its 11 pockets represent 11 sites, or one site found
repeatedly? Which overlap?

Sessions are keyed on (uniprot, DOMAIN), not uniprot alone. A target's domains are
separate AlphaFold superdomain models in different coordinate frames -- P00533 has domains
1 and 2 -- so overlaying them would scatter pockets across unrelated space.

Within a domain the conformations DO share a frame: every refined conformer is the
AlphaFold model with local repacking, so the ligands can be overlaid directly with no
superposition. (Verified: leading coordinates identical to 3 dp between apo and refined.)

Per session:
  protein     cartoon, from the first conformation of the first pocket
  <pocket>    each pocket's reference ligand, its own colour, sticks
  shell_<p>   that pocket's 6 A residue shell, as a transparent surface

Pockets with several conformations show the representative used for docking (first by
conf order, matching make_docking_manifest.py) unless --all-conformations is given.

Needs PyMOL:  /home/marina/anaconda3/bin/python
"""

import argparse
import collections
import csv
import glob
import os
import sys

# Distinguishable in both cartoon and stick representation; cycles if a domain has more.
PALETTE = [
    "orange", "marine", "forest", "magenta", "yellow", "cyan", "salmon", "purple",
    "limon", "deepteal", "hotpink", "wheat", "slate", "olive", "firebrick", "lightblue",
    "chocolate", "palegreen", "violet", "sand",
]


def read_manifest(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def collect(bases):
    """{(set, uniprot, domain): {pocket: [rows sorted by conf]}}"""
    out = collections.defaultdict(lambda: collections.defaultdict(list))
    for base in bases:
        set_name = os.path.basename(base.rstrip("/"))
        for man in sorted(glob.glob(os.path.join(base, "*", "pockets", "manifest.csv"))):
            pdir = os.path.dirname(man)
            for r in read_manifest(man):
                r["_dir"] = pdir
                key = (set_name, r["uniprot"], r.get("domain", "0"))
                out[key][r.get("pocket", "?")].append(r)
    for key in out:
        for pk in out[key]:
            out[key][pk].sort(key=lambda r: str(r.get("conf", "")))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--targets-base", action="append", required=True, metavar="DIR")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--all-conformations", action="store_true",
                    help="show every conformation of each pocket, not just the "
                         "representative used for docking")
    ap.add_argument("--png", action="store_true", help="also render a PNG per session")
    ap.add_argument("--only", default="", help="comma-separated UniProt IDs")
    a = ap.parse_args()

    try:
        import pymol2
    except ImportError:
        sys.exit("pymol2 not importable - run with /home/marina/anaconda3/bin/python")

    groups = collect(a.targets_base)
    only = {x.strip() for x in a.only.split(",") if x.strip()}
    if only:
        groups = {k: v for k, v in groups.items() if k[1] in only}
    if not groups:
        sys.exit("no pockets found")
    os.makedirs(a.out_dir, exist_ok=True)

    print(f"{len(groups)} (target, domain) session(s), "
          f"{sum(len(v) for v in groups.values())} pockets\n")

    with pymol2.PyMOL() as p:
        cmd = p.cmd
        cmd.set("retain_order", 1)
        for (set_name, uni, domain), pockets in sorted(groups.items()):
            cmd.reinitialize()
            cmd.set("cartoon_transparency", 0.75)
            cmd.set("transparency", 0.75)
            cmd.bg_color("white")

            # Protein from the first pocket's first conformation; within a domain every
            # conformation shares the frame, so one is enough to hold the view.
            first = pockets[sorted(pockets)[0]][0]
            prot_pdb = os.path.join(first["_dir"], first["pocket_file"])
            if not os.path.isfile(prot_pdb):
                print(f"  SKIP {uni} d{domain}: missing {prot_pdb}")
                continue
            cmd.load(prot_pdb, "protein")
            cmd.remove("protein and not polymer")
            cmd.hide("everything", "protein")
            cmd.show("cartoon", "protein")
            cmd.color("grey80", "protein")

            n_obj = 0
            for i, pk in enumerate(sorted(pockets)):
                rows = pockets[pk] if a.all_conformations else pockets[pk][:1]
                colour = PALETTE[i % len(PALETTE)]
                for j, r in enumerate(rows):
                    path = os.path.join(r["_dir"], r["pocket_file"])
                    if not os.path.isfile(path):
                        continue
                    obj = f"p_{pk}" if len(rows) == 1 else f"p_{pk}_{j}"
                    cmd.load(path, "_tmp")
                    cmd.create(obj, "_tmp and not polymer")
                    cmd.delete("_tmp")
                    if cmd.count_atoms(obj) == 0:
                        cmd.delete(obj); continue
                    cmd.show("sticks", obj)
                    cmd.color(colour, obj)
                    n_obj += 1
                    if j == 0:
                        sel = f"shell_{pk}"
                        cmd.select(sel, f"byres (protein within 6 of {obj})")
                        cmd.show("surface", sel)
                        cmd.color(colour, sel)
                        cmd.disable(sel)

            cmd.deselect()
            cmd.orient("protein")
            stem = f"{set_name}_{uni}_d{domain}"
            pse = os.path.join(a.out_dir, f"{stem}.pse")
            cmd.save(pse)
            if a.png:
                cmd.ray(1200, 900)
                cmd.png(os.path.join(a.out_dir, f"{stem}.png"), dpi=150)
            print(f"  {stem:<34}{len(pockets):>3} pockets, {n_obj:>3} ligand objects")

    print(f"\nsessions in {a.out_dir}")
    print("Open one with:  pymol <file>.pse")
    print("Surfaces are loaded but hidden; enable a pocket's shell with  enable shell_<pocket>")


if __name__ == "__main__":
    main()
