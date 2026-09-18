#!/usr/bin/env python3
"""
Phase 3: build a PyMOL view comparing our production pocket with the authors' real one.

The question this is here to settle, for the AUC outliers, is a binary one:

    is our pocket INSIDE the real orthosteric site but mis-shaped,
    or is it on the WRONG SITE entirely (surface / allosteric)?

Those need completely different fixes, and a sub-0.3 AUC -- an actively inverted
ranking, as seen for P06493 (0.232), Q9UBF8 (0.268) and P04049 (0.282) -- points at
the second.  A picture settles it in seconds where a table cannot.

What gets drawn
---------------
  af              the GenPack-refined AlphaFold conformation, grey cartoon
  lig_true        the transposed PDBbind ligand, green sticks
  pocket_true     residues within 6 A of it, green sticks        <- the paper's definition
  lig_cur         the fpocket alpha-sphere pseudo-ligand, orange dots (if available)
  pocket_cur      residues within 6 A of it, orange lines        <- what we actually encoded
  centre          the averaged Glide GRID_CENTER, a magenta sphere

Two modes:
  --mode emit     (default) print PyMOL commands on stdout, to paste into a live PyMOL
                  or feed through the PyMOL MCP one line at a time
  --mode session  run headless and save a .pse (+ optional .png)

Usage:
    python pymol_pocket_session.py --uniprot P04049 --pocket 2 \
        --true-base    /home/marina/Documents/AI2050/Targets/targets_ligand \
        --current-base /home/marina/fpocket_staging/targets_fpocket

    python pymol_pocket_session.py --uniprot P04049 --pocket 2 --mode session \
        --true-base ... --out P04049_p2.pse
"""

import argparse
import csv
import glob
import os
import sys

CUTOFF = 6.0          # upstream's hard-coded radius, encode_pockets.py:102


def find_conf(base, uniprot, pocket, domain=None, conf=None):
    """Locate one conformation's _LIG.pdb via the target's manifest.

    Returns (pdb_path, manifest_row) or (None, None).  Pocket tokens are matched
    literally: "2" and "pocket2" are different pockets and must never be normalised.
    """
    man = os.path.join(base, uniprot, "pockets", "manifest.csv")
    if not os.path.exists(man):
        return None, None
    rows = list(csv.DictReader(open(man)))
    cand = [r for r in rows if r["pocket"] == pocket
            and (domain is None or r["domain"] == str(domain))
            and (conf is None or r["conf"] == conf)]
    if not cand:
        return None, None
    row = cand[0]
    p = os.path.join(base, uniprot, "pockets", row["pocket_file"])
    return (p if os.path.exists(p) else None), row


def commands(af_true, row, cur_pdb, name):
    """PyMOL command list. af_true carries both receptor and the true ligand as LIG."""
    cx, cy, cz = row["center_x"], row["center_y"], row["center_z"]
    c = [
        "delete all",
        "set retain_order, 1",
        f'load {af_true}, {name}_true',
        f"create af, {name}_true and polymer",
        f"create lig_true, {name}_true and resn LIG",
        f"delete {name}_true",
        # The paper's pocket: complete residues with a heavy atom within 6 A of the ligand.
        f"select pocket_true, byres (af within {CUTOFF} of lig_true)",
        "hide everything",
        "show cartoon, af",
        "color grey80, af",
        "show sticks, lig_true",
        "color green, lig_true",
        "show sticks, pocket_true and not (name C+N+O)",
        "color palegreen, pocket_true",
        f"pseudoatom centre, pos=[{cx}, {cy}, {cz}]",
        "show spheres, centre",
        "set sphere_scale, 0.5, centre",
        "color magenta, centre",
    ]
    if cur_pdb:
        c += [
            f"load {cur_pdb}, {name}_cur",
            f"create lig_cur, {name}_cur and resn LIG",
            f"delete {name}_cur",
            f"select pocket_cur, byres (af within {CUTOFF} of lig_cur)",
            "show nb_spheres, lig_cur",
            "color orange, lig_cur",
            "set sphere_scale, 0.25, lig_cur",
            "show lines, pocket_cur",
            "color orange, pocket_cur",
            # The two residue sets we are actually comparing.
            "select only_true, pocket_true and not pocket_cur",
            "select only_cur,  pocket_cur and not pocket_true",
            "select shared,    pocket_true and pocket_cur",
            "color red, only_true",
            "color yellow, only_cur",
            "color white, shared",
        ]
    c += [
        "deselect",
        "orient lig_true",
        "zoom lig_true, 8",
        "bg_color white",
        "set cartoon_transparency, 0.6",
    ]
    return c


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--uniprot", required=True)
    ap.add_argument("--pocket", required=True,
                    help='Pocket token exactly as named: "2" or "pocket3" (never normalised)')
    ap.add_argument("--domain", default=None)
    ap.add_argument("--conf", default=None, help='e.g. "4_5orz"; default: first in manifest')
    ap.add_argument("--true-base", required=True)
    ap.add_argument("--current-base", default="")
    ap.add_argument("--mode", choices=["emit", "session"], default="emit")
    ap.add_argument("--out", default="", help="session mode: .pse path (and .png alongside)")
    ap.add_argument("--png", action="store_true", help="session mode: also ray-trace a PNG")
    args = ap.parse_args()

    true_pdb, row = find_conf(args.true_base, args.uniprot, args.pocket,
                              args.domain, args.conf)
    if not true_pdb:
        sys.exit(f"no true-ligand conformation for {args.uniprot} pocket '{args.pocket}' "
                 f"under {args.true_base} (run Phase 1 first, and note that only "
                 f"template-route pockets have a recoverable ligand)")

    cur_pdb = None
    if args.current_base:
        cur_pdb, _ = find_conf(args.current_base, args.uniprot, args.pocket,
                               args.domain, row["conf"])
        if not cur_pdb:
            print(f"# note: no production cavity pocket for this conformation under "
                  f"{args.current_base}; drawing the true pocket only", file=sys.stderr)

    name = f"{args.uniprot}_{args.pocket}"
    cmds = commands(true_pdb, row, cur_pdb, name)

    meta = (f"# {args.uniprot} domain {row['domain']} pocket '{row['pocket']}' "
            f"conf {row['conf']}\n"
            f"# template PDB {row.get('pdb_id','?')} ligand {row.get('het_code','?')} "
            f"({row.get('n_lig_atoms','?')} heavy atoms)\n"
            f"# align rmsd {row.get('align_rmsd','?')} A over {row.get('align_len','?')} res, "
            f"centroid offset {row.get('centroid_offset','?')} A\n"
            f"# green = paper's 6 A pocket, orange = what we encoded, magenta = grid centre\n")

    if args.mode == "emit":
        print(meta + "\n".join(cmds))
        return

    try:
        import pymol2
    except ImportError:
        sys.exit("pymol2 not importable - run with /home/marina/anaconda3/bin/python")
    out = args.out or f"{name}.pse"
    with pymol2.PyMOL() as p:
        for c in cmds:
            p.cmd.do(c)
        n_true = p.cmd.count_atoms("pocket_true and name CA")
        n_cur = p.cmd.count_atoms("pocket_cur and name CA") if cur_pdb else 0
        n_shared = p.cmd.count_atoms("shared and name CA") if cur_pdb else 0
        p.cmd.save(out)
        if args.png:
            p.cmd.set("ray_opaque_background", 1)
            p.cmd.png(os.path.splitext(out)[0] + ".png", width=1400, height=1050,
                      dpi=150, ray=1)
    print(meta.rstrip())
    print(f"# residues: true {n_true}, current {n_cur}, shared {n_shared}"
          + (f", IoU {n_shared / (n_true + n_cur - n_shared):.3f}"
             if cur_pdb and (n_true + n_cur - n_shared) else ""))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
