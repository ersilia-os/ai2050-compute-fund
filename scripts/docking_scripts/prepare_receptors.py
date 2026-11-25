#!/usr/bin/env python3
"""
Add hydrogens to the Mtb docking receptors with PDBFixer (one-off, laptop).

Why
---
Uni-Dock's `unidocktools proteinprep` reads the receptor's existing hydrogens and adds
Gasteiger charges and AutoDock atom types; it never adds hydrogens. Vina ignores hydrogen
positions, but it needs the polar hydrogens to type donor atoms (Trott & Olson 2010,
J Comput Chem 31:455), so a receptor with no hydrogens has no donors at all.

The human set (`targets_ligand`) docks into Schrodinger-refined receptors that already
carry hydrogens. The Mtb set (`targets_mtb_v2`) was built from raw AlphaFold models: the
receptor is the ATOM block of each pocket's `_LIG.pdb`, with zero hydrogens. This
script protonates those (decision 2026-11-25: PDBFixer, pH 7.4). The two sets are
therefore prepared differently; `make_docking_manifest.py` records which method each
receptor got (`receptor_prep`), and results should be read with that in mind.

What it does, per pocket conformation listed in <pockets-base>/<U>/pockets/manifest.csv
-----------------------------------------------------------------------------------
1. Keeps the ATOM records only. The HETATM block is the transplanted ligand that
   defined the pocket; it is not part of the receptor.
2. Checks, and reports before writing anything:
     - hydrogens already present  -> skipped (nothing to do)
     - chain breaks (C-N > 2.0 A between consecutive residues) -> STOP. A break means
       the file is not a complete model; protonating it would cap false chain ends.
3. PDBFixer: no missing-residue modelling (AlphaFold models are complete), missing heavy
   atoms added and logged (normally only the C-terminal OXT), then
   addMissingHydrogens(pH).
4. Writes <out-dir>/<U>/protonated/<stem>_H.pdb with a REMARK line recording the method
   and pH, which make_docking_manifest.py reads into `receptor_prep`.

`<stem>_H.pdb` naming: `<stem>_LIG.pdb` -> `<stem>_H.pdb`. The same rule is in
make_docking_manifest.py (`protonated_name`); change both together.

Upload afterwards (a new S3 prefix, so FSx imports it as new files):
    aws s3 cp --recursive <out-dir>/ s3://ai2050-ersilia-cluster/input/targets/ \
        --exclude "*" --include "*/protonated/*_H.pdb"

Environment: any Python with pdbfixer + openmm (on Marina's laptop, the `clpp` conda env).

Usage:
    python prepare_receptors.py                       # every target under --pockets-base
    python prepare_receptors.py --uniprot P9WJV5      # one target
    python prepare_receptors.py --dry-run             # checks only, writes nothing
"""

import argparse
import csv
import io
import math
import os
import sys
from importlib.metadata import version, PackageNotFoundError

root = os.path.dirname(os.path.abspath(__file__))
pockets_base_default = os.path.join(root, "..", "..", "data", "mtb")
out_dir_default = os.path.join(root, "..", "..", "data", "processed", "receptors_protonated")

DEFAULT_PH = 7.4
MAX_PEPTIDE_BOND = 2.0      # A; a longer C-N distance between consecutive residues is a break
REMARK_TAG = "DOCKPREP"     # make_docking_manifest.py looks for this word


def protonated_name(pocket_file):
    """`<stem>_LIG.pdb` -> `<stem>_H.pdb` (same rule in make_docking_manifest.py)."""
    base = os.path.basename(pocket_file)
    stem = base[:-len("_LIG.pdb")] if base.endswith("_LIG.pdb") else os.path.splitext(base)[0]
    return f"{stem}_H.pdb"


def atom_block(path):
    """ATOM/TER lines of a PDB (the receptor), plus END."""
    with open(path) as f:
        lines = [ln for ln in f if ln.startswith(("ATOM", "TER"))]
    return "".join(lines) + "END\n"


def is_hydrogen(line):
    el = line[76:78].strip()
    if el:
        return el.upper() == "H"
    return line[12:16].strip().upper().startswith("H")


def describe(block):
    """Counts and chain breaks for an ATOM block."""
    n_heavy = n_h = 0
    res = {}
    for ln in block.splitlines():
        if not ln.startswith("ATOM"):
            continue
        if is_hydrogen(ln):
            n_h += 1
        else:
            n_heavy += 1
        key = (ln[21], int(ln[22:26]), ln[26])
        xyz = (float(ln[30:38]), float(ln[38:46]), float(ln[46:54]))
        res.setdefault(key, {})[ln[12:16].strip()] = xyz
    keys = sorted(res)
    breaks = []
    for a, b in zip(keys, keys[1:]):
        if a[0] != b[0]:
            continue
        c, n = res[a].get("C"), res[b].get("N")
        if c is None or n is None or math.dist(c, n) > MAX_PEPTIDE_BOND:
            breaks.append(f"{a[0]}{a[1]}-{b[1]}")
    return {"n_heavy": n_heavy, "n_h": n_h, "n_res": len(keys),
            "chains": "".join(sorted({k[0] for k in keys})), "breaks": breaks}


def pkg_version(name):
    try:
        return version(name)
    except PackageNotFoundError:
        return "unknown"


def protonate(block, ph):
    """Run PDBFixer on an ATOM block. Returns (pdb text, n heavy atoms added)."""
    from openmm.app import PDBFile
    from pdbfixer import PDBFixer

    fixer = PDBFixer(pdbfile=io.StringIO(block))
    fixer.missingResidues = {}                 # AlphaFold models are complete: model nothing
    fixer.findMissingAtoms()
    n_added = sum(len(v) for v in fixer.missingAtoms.values()) + \
        sum(len(v) for v in fixer.missingTerminals.values())
    fixer.addMissingAtoms()
    fixer.addMissingHydrogens(ph)
    out = io.StringIO()
    PDBFile.writeFile(fixer.topology, fixer.positions, out, keepIds=True)
    return out.getvalue(), n_added


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pockets-base", default=pockets_base_default,
                    help="folder holding <UNIPROT>/pockets/manifest.csv (default data/mtb)")
    ap.add_argument("--out-dir", default=out_dir_default,
                    help="writes <out-dir>/<UNIPROT>/protonated/<stem>_H.pdb")
    ap.add_argument("--uniprot", action="append", default=None,
                    help="repeatable; default = every target with a pockets/manifest.csv")
    ap.add_argument("--ph", type=float, default=DEFAULT_PH,
                    help=f"protonation pH (default {DEFAULT_PH}, decided 2026-11-25)")
    ap.add_argument("--dry-run", action="store_true", help="checks only, write nothing")
    a = ap.parse_args()

    base = os.path.abspath(a.pockets_base)
    unis = a.uniprot or sorted(
        u for u in os.listdir(base)
        if os.path.isfile(os.path.join(base, u, "pockets", "manifest.csv")))
    if not unis:
        sys.exit(f"ERROR: no <UNIPROT>/pockets/manifest.csv under {base}")

    # 1. collect + check everything before writing anything
    jobs = []
    for uni in unis:
        man = os.path.join(base, uni, "pockets", "manifest.csv")
        if not os.path.isfile(man):
            sys.exit(f"ERROR: missing {man}")
        with open(man, newline="") as f:
            rows = list(csv.DictReader(f))
        for r in rows:
            if r.get("source_refined_pdb"):
                print(f"  skip {uni} {r['pocket_file']}: has a refined receptor")
                continue
            path = os.path.join(base, uni, "pockets", r["pocket_file"])
            if not os.path.isfile(path):
                sys.exit(f"ERROR: missing {path}")
            block = atom_block(path)
            jobs.append((uni, r["pocket_file"], block, describe(block)))

    print(f"{'target':<8} {'pocket file':<50} {'res':>5} {'chains':>6} {'heavy':>6} "
          f"{'H':>5}  breaks")
    for uni, pf, _b, d in jobs:
        print(f"{uni:<8} {pf:<50} {d['n_res']:>5} {d['chains']:>6} {d['n_heavy']:>6} "
              f"{d['n_h']:>5}  {','.join(d['breaks']) or '-'}")

    broken = [(u, pf) for u, pf, _b, d in jobs if d["breaks"]]
    if broken:
        sys.exit(f"\nSTOP: {len(broken)} receptor(s) have chain breaks, so they are not "
                 "complete models. Protonating them would cap false chain ends. "
                 "Use the full AlphaFold model as input instead.")
    if a.dry_run:
        print(f"\n--dry-run: {len(jobs)} receptor(s) checked, nothing written")
        return

    # 2. protonate
    vers = f"pdbfixer {pkg_version('pdbfixer')} openmm {pkg_version('openmm')}"
    print(f"\n{vers}   pH {a.ph}")
    log_rows = []
    for uni, pf, block, d in jobs:
        out_dir = os.path.join(a.out_dir, uni, "protonated")
        out = os.path.join(out_dir, protonated_name(pf))
        if d["n_h"] > 0:
            print(f"  {uni} {pf}: already has {d['n_h']} H - skipped")
            log_rows.append({"uniprot": uni, "pocket_file": pf, "action": "skipped_has_h",
                             **{k: d[k] for k in ("n_res", "n_heavy", "n_h")},
                             "heavy_added": 0, "h_after": d["n_h"], "out": ""})
            continue
        text, n_added = protonate(block, a.ph)
        after = describe(text)
        if after["n_res"] != d["n_res"]:
            sys.exit(f"ERROR {uni} {pf}: residue count changed {d['n_res']} -> "
                     f"{after['n_res']}")
        os.makedirs(out_dir, exist_ok=True)
        remark = (f"REMARK   1 {REMARK_TAG} method=pdbfixer pH={a.ph:.2f} {vers} "
                  f"source={pf}\n")
        with open(out + ".tmp", "w") as f:
            f.write(remark + text)
        os.replace(out + ".tmp", out)
        print(f"  {uni} {pf}: heavy {d['n_heavy']} -> {after['n_heavy']} "
              f"(+{n_added} missing atoms), H 0 -> {after['n_h']}")
        log_rows.append({"uniprot": uni, "pocket_file": pf, "action": "protonated",
                         "n_res": d["n_res"], "n_heavy": d["n_heavy"], "n_h": d["n_h"],
                         "heavy_added": after["n_heavy"] - d["n_heavy"],
                         "h_after": after["n_h"], "out": os.path.relpath(out, a.out_dir)})

    os.makedirs(a.out_dir, exist_ok=True)
    log = os.path.join(a.out_dir, "protonation_log.csv")
    with open(log, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(log_rows[0].keys()))
        w.writeheader()
        w.writerows(log_rows)
    print(f"\nwrote {log}")


if __name__ == "__main__":
    main()
