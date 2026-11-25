#!/usr/bin/env python3
"""
Turn a DrugCLIP screen into a Uni-Dock work list: which ligand goes into which pocket.

Decision (Marina, 2026-10-06): each ligand is docked into the SINGLE pocket where DrugCLIP
scored it highest -- one docking run per ligand, not one per (ligand, pocket) pair.

What that does and does not let you conclude
--------------------------------------------
It answers "does docking like the pocket DrugCLIP picked, and how well".  It does NOT give
a per-pocket correlation between the two methods, because each ligand is only ever docked
where DrugCLIP already liked it.  So a disagreement cannot be attributed: it may be about
WHICH pocket, or about the score AT that pocket, and this design cannot separate them.
Nothing downstream will flag that, so it belongs next to any comparison that comes out.

Assigning by argmax also means every ligand gets a pocket, including ones that score badly
everywhere.  `--min-score` and `--max-per-pocket` exist to cut that tail; neither has a
validated value and both default to off.

Batching
--------
Grouping by winning pocket is what makes this efficient: 460k ligands across 191 pockets is
~2,400 per pocket on average, and Uni-Dock wants >=1,000 per batch.  One SMILES file per
pocket is written for exactly that.

Receptors
---------
`unidocktools proteinprep` does NOT add hydrogens, so the receptor must already have them.
  targets_ligand -> the Schrodinger-refined `*_complex_refined.pdb` named in manifest.csv
                    (`source_refined_pdb`), which carries H.
                    receptor_prep = schrodinger_refined
  targets_mtb_v2 -> built from raw AlphaFold models with no hydrogens.  Since 2026-11-25
                    they are protonated once by prepare_receptors.py (PDBFixer, pH 7.4) and
                    staged as <refined-base>/<U>/protonated/<stem>_H.pdb.
                    receptor_prep = pdbfixer_pH7.40 (read from the file's DOCKPREP remark)
  neither        -> the _LIG.pdb ATOM block as-is, receptor_has_h=unknown,
                    receptor_prep=none.  dock_batches.py refuses a receptor with zero H.

Batches (`--batch-size`, default 1000)
-------------------------------------
batches.csv cuts every pocket's ligand file into consecutive batches, pocket by pocket in
manifest order: `batch_id, tag, manifest_row, start, end, n` (0-based, end exclusive,
line numbers in ligands/<tag>.smi).  dock_batches.py docks one batch per Uni-Dock call.

Memory: the whole pocket_scores.npz is loaded (pockets x molecules float32). For REAL
10.4M that is several GB: run this on a compute node, not the head node.

Box
---
Delegated to compute_box.py: centre = midpoint of the reference ligand's heavy-atom
bounding box, size = extent + 2 x 6 A.  The 6 A padding is the DrugCLIP pocket radius, so
the Vina box and the DrugCLIP pocket cover the same region of the protein.

Laptop or cluster; needs only numpy.
"""

import argparse
import csv
import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from compute_box import ligand_heavy_coords, DEFAULT_PADDING      # noqa: E402


def box_from_lig(path, padding):
    """(centre xyz, size xyz) from a _LIG.pdb's HETATM LIG residue."""
    coords = ligand_heavy_coords(path, all_atoms=False)
    if not coords:
        return None, None
    A = np.asarray(coords, dtype=float)
    lo, hi = A.min(axis=0), A.max(axis=0)
    return (lo + hi) / 2.0, (hi - lo) + 2.0 * padding


def protonated_name(pocket_file):
    """`<stem>_LIG.pdb` -> `<stem>_H.pdb` (same rule in prepare_receptors.py)."""
    base = os.path.basename(pocket_file)
    stem = base[:-len("_LIG.pdb")] if base.endswith("_LIG.pdb") else os.path.splitext(base)[0]
    return f"{stem}_H.pdb"


def protonated_prep(path):
    """receptor_prep label from prepare_receptors.py's `DOCKPREP method=.. pH=..` remark."""
    with open(path) as f:
        for ln in f:
            if not ln.startswith("REMARK"):
                break
            if "DOCKPREP" in ln:
                kv = dict(t.split("=", 1) for t in ln.split() if "=" in t)
                return f"{kv.get('method', 'unknown')}_pH{kv.get('pH', '?')}"
    return "protonated_unknown"


def read_sets(base):
    """uniprot -> original set name from <base>/sets.csv; {} for an unmerged pocket set.

    Same file screen_library.py reads: a merged set (ai2050_targets) records each target's
    original set there, and that is the set_name the screen wrote into pocket_scores.npz.
    """
    path = os.path.join(base, "sets.csv")
    if not os.path.isfile(path):
        return {}
    with open(path, newline="") as f:
        return {r["uniprot"]: r["set_name"] for r in csv.DictReader(f)}


def read_manifest(base, uni):
    path = os.path.join(base, uni, "pockets", "manifest.csv")
    if not os.path.isfile(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def resolve_pocket(base, uni, domain, pocket):
    """Pick one representative conformation for this pocket.

    A pocket has several conformations, each its own `_LIG.pdb` and its own refined
    receptor. Docking needs ONE. Take the first by conf order so the choice is
    deterministic and reproducible rather than filesystem-dependent.
    """
    rows = [r for r in read_manifest(base, uni)
            if r.get("domain") == domain and r.get("pocket") == pocket]
    if not rows:
        return None
    rows.sort(key=lambda r: str(r.get("conf", "")))
    return rows[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--screen-dir", required=True,
                    help="output of screen_library.py (pocket_scores.npz, deck_smiles.txt)")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--targets-base", action="append", required=True, metavar="DIR",
                    help="repeatable; same sets the screen used")
    ap.add_argument("--refined-base", default="/fsx/input/targets",
                    help="where <UNIPROT>/refined/<source_refined_pdb> lives")
    ap.add_argument("--padding", type=float, default=DEFAULT_PADDING,
                    help="box padding per side, A (default matches the pocket radius)")
    ap.add_argument("--max-per-pocket", type=int, default=0,
                    help="keep only this many top-scoring ligands per pocket (0 = all). "
                         "Not a validated cutoff.")
    ap.add_argument("--min-score", type=float, default=None,
                    help="drop ligands whose best-pocket z is below this. Not a validated "
                         "cutoff; by default every ligand is assigned somewhere.")
    ap.add_argument("--batch-size", type=int, default=1000,
                    help="ligands per Uni-Dock call in batches.csv (default 1000, the "
                         "October value; Uni-Dock prefers >=1000)")
    a = ap.parse_args()
    if a.batch_size < 1:
        sys.exit("ERROR: --batch-size must be >= 1")

    npz = os.path.join(a.screen_dir, "pocket_scores.npz")
    smi_path = os.path.join(a.screen_dir, "deck_smiles.txt")
    for p in (npz, smi_path):
        if not os.path.isfile(p):
            sys.exit(f"ERROR: missing {p}")

    d = np.load(npz, allow_pickle=False)
    S = d["scores"]                                   # (n_pockets, n_mol)
    uni_a, set_a = d["uniprot"], d["set_name"]
    dom_a, pk_a = d["domain"], d["pocket"]
    smis = [ln.strip() for ln in open(smi_path) if ln.strip()]
    if len(smis) != S.shape[1]:
        sys.exit(f"ERROR: {len(smis)} smiles vs {S.shape[1]} score columns")
    print(f"{S.shape[0]} pockets x {S.shape[1]} molecules")

    # winning pocket per ligand
    best_row = np.argmax(S, axis=0)
    best_val = S[best_row, np.arange(S.shape[1])]
    keep = np.ones(len(smis), dtype=bool)
    if a.min_score is not None:
        keep &= best_val >= a.min_score
        print(f"  --min-score {a.min_score}: {int(keep.sum())} of {len(smis)} ligands kept")

    # set_name -> folder. A plain set is found by its folder name; a merged folder also
    # answers to every set listed in its sets.csv. Two folders claiming one set would make
    # the receptor lookup depend on argument order, so that is an error.
    base_by_set = {}
    for b in a.targets_base:
        names = {os.path.basename(b.rstrip("/"))} | set(read_sets(b).values())
        for n in names:
            if base_by_set.get(n, b) != b:
                sys.exit(f"ERROR: set {n} is claimed by both {base_by_set[n]} and {b}; "
                         "pass only one of them as --targets-base")
            base_by_set[n] = b
    os.makedirs(a.out_dir, exist_ok=True)
    lig_dir = os.path.join(a.out_dir, "ligands")
    os.makedirs(lig_dir, exist_ok=True)

    rows, n_lig, missing = [], 0, 0
    for r in range(S.shape[0]):
        idx = np.where(keep & (best_row == r))[0]
        if len(idx) == 0:
            continue
        idx = idx[np.argsort(-best_val[idx].astype(np.float64), kind="stable")]
        if a.max_per_pocket:
            idx = idx[:a.max_per_pocket]

        uni, sset = str(uni_a[r]), str(set_a[r])
        domain, pocket = str(dom_a[r]), str(pk_a[r])
        base = base_by_set.get(sset)
        if base is None:
            print(f"  WARN no --targets-base for set {sset}; skipping {uni} {pocket}")
            missing += 1
            continue
        man = resolve_pocket(base, uni, domain, pocket)
        if man is None:
            print(f"  WARN no manifest row for {uni} d{domain} {pocket}")
            missing += 1
            continue

        lig_pdb = os.path.join(base, uni, "pockets", man["pocket_file"])
        centre, size = box_from_lig(lig_pdb, a.padding) if os.path.isfile(lig_pdb) \
            else (None, None)
        if centre is None:
            print(f"  WARN cannot read reference ligand for {uni} {pocket}: {lig_pdb}")
            missing += 1
            continue

        src = man.get("source_refined_pdb") or ""
        refined = os.path.join(a.refined_base, uni, "refined", src) if src else ""
        protonated = os.path.join(a.refined_base, uni, "protonated",
                                  protonated_name(man["pocket_file"]))
        if src and os.path.isfile(refined):
            receptor, has_h, prep = refined, "yes", "schrodinger_refined"
        elif os.path.isfile(protonated):
            # targets_mtb_v2: AlphaFold receptor protonated by prepare_receptors.py
            receptor, has_h, prep = protonated, "yes", protonated_prep(protonated)
        else:
            # No refined or protonated counterpart. The _LIG.pdb's ATOM records are the
            # receptor, from a raw AlphaFold model with no hydrogens.
            receptor, has_h, prep = lig_pdb, "unknown", "none"

        tag = f"{uni}_d{domain}_{pocket}".replace("/", "-")
        smi_file = os.path.join(lig_dir, f"{tag}.smi")
        with open(smi_file, "w") as f:
            for i in idx:
                f.write(f"{smis[i]}\t{uni}_{pocket}_{i}\n")
        n_lig += len(idx)

        rows.append({
            "uniprot": uni, "set_name": sset, "domain": domain, "pocket": pocket,
            "tag": tag, "n_ligands": len(idx), "ligand_file": smi_file,
            "receptor": receptor, "receptor_has_h": has_h, "receptor_prep": prep,
            "reference_ligand": lig_pdb, "het_code": man.get("het_code", ""),
            "center_x": round(float(centre[0]), 3),
            "center_y": round(float(centre[1]), 3),
            "center_z": round(float(centre[2]), 3),
            "size_x": round(float(size[0]), 2),
            "size_y": round(float(size[1]), 2),
            "size_z": round(float(size[2]), 2),
            "best_z_max": round(float(best_val[idx[0]]), 4),
            "best_z_min": round(float(best_val[idx[-1]]), 4),
        })

    if not rows:
        sys.exit("ERROR: no pockets resolved")
    out_csv = os.path.join(a.out_dir, "docking_manifest.csv")
    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    # batches.csv: consecutive slices of each pocket's .smi, pocket by pocket
    batches, bid = [], 0
    for mrow, r in enumerate(rows, 1):
        for start in range(0, r["n_ligands"], a.batch_size):
            bid += 1
            end = min(start + a.batch_size, r["n_ligands"])
            batches.append({"batch_id": bid, "tag": r["tag"], "manifest_row": mrow,
                            "start": start, "end": end, "n": end - start})
    bat_csv = os.path.join(a.out_dir, "batches.csv")
    with open(bat_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(batches[0].keys()))
        w.writeheader()
        w.writerows(batches)

    no_h = sum(1 for r in rows if r["receptor_has_h"] != "yes")
    small = sum(1 for r in rows if r["n_ligands"] < 1000)
    print(f"\nwrote {out_csv}")
    print(f"  {len(rows)} pockets, {n_lig} ligand-pocket pairs "
          f"(one docking run each)")
    print(f"wrote {bat_csv}")
    print(f"  {len(batches)} batches of <= {a.batch_size} ligands")
    preps = {}
    for r in rows:
        preps[r["receptor_prep"]] = preps.get(r["receptor_prep"], 0) + 1
    print("  receptor prep: " + ", ".join(f"{k} {v}" for k, v in sorted(preps.items())))
    if no_h:
        print(f"  !! {no_h} pocket(s) with a receptor of unknown protonation: "
              "dock_batches.py will refuse them. Run prepare_receptors.py and stage "
              "<refined-base>/<U>/protonated/ first.")
    print(f"  {small} pocket(s) with <1000 ligands (Uni-Dock prefers larger batches)")
    if missing:
        print(f"  {missing} pocket(s) skipped, see WARNs above")


if __name__ == "__main__":
    main()
