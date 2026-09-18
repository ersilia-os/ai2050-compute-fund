#!/usr/bin/env python3
"""
Phase 2: how far is our production pocket from the DrugCLIP authors' real one?

For each template-route pocket we now hold two competing definitions of "the pocket",
both evaluated with upstream's hard-coded rule (encode_pockets.py:102 -- complete
residues with at least one heavy atom within 6 A of the ligand):

  CURRENT  cavity pseudo-ligand: fpocket alpha spheres within 8 A of the averaged
           Glide GRID_CENTER          (prepare_fpocket_cavity_for_drugclip.py)
  TRUE     the real PDBbind ligand the authors transposed onto the AlphaFold
           superdomain                (recover_template_ligands.py)

and we report, per pocket:

  * residue counts under each definition, and their ratio
  * IoU of the two residue sets
  * centroid_offset -- |true ligand centroid - grid centre|
  * whether the pocket exceeds --max-pocket-atoms (the silent-crop risk)

then join to enrichment_pockets.csv and test Spearman(IoU, auc_z).  That last test is
a direct replication of the paper's fig. S10A, which reports dEF1% correlating with
pocket IoU against holo (P < 0.005).

This is the go/no-go for Phase 4.  If IoU is already high, the pocket location is not
what is holding us back and there is no point spending GPU on a rebuild.

The CURRENT definition needs the production `_LIG.pdb` files.  Those live on the
cluster (/fsx/input/targets); only a 12-target subset is on the laptop.  Where a
pocket's current file is missing the row is still emitted with the true-ligand
geometry and the offset (both computable from the manifest alone) and IoU is left
blank -- so the script is useful before any sync, and more useful after one.

Usage:
    python compare_pocket_geometry.py \
        --true-base    /home/marina/Documents/AI2050/Targets/targets_ligand \
        --current-base /home/marina/fpocket_staging/targets_fpocket \
        --enrichment   /home/marina/ersilia/AI2050-Compute-Fund/enrichment_out \
        --out          pocket_geometry.csv
"""

import argparse
import csv
import glob
import os
import statistics as st
from collections import defaultdict

import numpy as np

CUTOFF = 6.0          # upstream's hard-coded residue-selection radius, encode_pockets.py:102


def read_pdb(path):
    """Return (residues, ligand_coords): residues maps (chain, resi) -> Nx3 heavy coords."""
    res = defaultdict(list)
    lig = []
    with open(path) as f:
        for l in f:
            if l.startswith("ATOM"):
                try:
                    res[(l[21], l[22:27])].append(
                        (float(l[30:38]), float(l[38:46]), float(l[46:54])))
                except ValueError:
                    pass
            elif l.startswith("HETATM"):
                try:
                    lig.append((float(l[30:38]), float(l[38:46]), float(l[46:54])))
                except ValueError:
                    pass
    return {k: np.asarray(v) for k, v in res.items()}, np.asarray(lig)


def pocket_residues(residues, lig, cutoff=CUTOFF):
    """Residue keys within `cutoff` A of any ligand heavy atom, and their atom count."""
    if lig.size == 0:
        return set(), 0
    keep = set()
    n_at = 0
    for key, coords in residues.items():
        if np.linalg.norm(coords[:, None, :] - lig[None, :, :], axis=-1).min() <= cutoff:
            keep.add(key)
            n_at += len(coords)
    return keep, n_at


def spearman(a, b):
    a, b = np.asarray(a, float), np.asarray(b, float)
    ok = np.isfinite(a) & np.isfinite(b)
    if ok.sum() < 3:
        return float("nan"), 0
    ra = np.argsort(np.argsort(a[ok]))
    rb = np.argsort(np.argsort(b[ok]))
    return float(np.corrcoef(ra, rb)[0, 1]), int(ok.sum())


def med(v):
    v = [x for x in v if x is not None and np.isfinite(x)]
    return st.median(v) if v else float("nan")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--true-base", required=True,
                    help="Output of recover_template_ligands.py: <base>/<UNIPROT>/pockets/")
    ap.add_argument("--current-base", default="",
                    help="Tree of production cavity _LIG.pdb (optional; enables IoU)")
    ap.add_argument("--enrichment", default="",
                    help="enrichment_out dir containing enrichment_pockets.csv (optional)")
    ap.add_argument("--max-pocket-atoms", type=int, default=256,
                    help="Flag pockets above this many heavy atoms (the crop threshold)")
    ap.add_argument("--out", default="pocket_geometry.csv")
    args = ap.parse_args()

    # ---- enrichment join table: screen_dir -> row -------------------------------
    enr = {}
    if args.enrichment:
        p = os.path.join(args.enrichment, "enrichment_pockets.csv")
        if os.path.exists(p):
            enr = {r["screen_dir"]: r for r in csv.DictReader(open(p))}
            print(f"joined against {len(enr)} enrichment rows")
        else:
            print(f"WARN no enrichment_pockets.csv under {args.enrichment}")

    # ---- index the current cavity pockets by pocket_key --------------------------
    cur = {}
    if args.current_base:
        for man in glob.glob(os.path.join(args.current_base, "*", "pockets", "manifest.csv")):
            d = os.path.dirname(man)
            for r in csv.DictReader(open(man)):
                fp = os.path.join(d, r["pocket_file"])
                if os.path.exists(fp):
                    cur[r["pocket_key"]] = fp
        print(f"found {len(cur)} production cavity pockets under {args.current_base}")
        if not cur:
            print("  (none -- IoU will be blank; sync /fsx/input/targets to enable it)")

    # ---- walk the true-ligand manifests ------------------------------------------
    rows = []
    mans = sorted(glob.glob(os.path.join(args.true_base, "*", "pockets", "manifest.csv")))
    if not mans:
        raise SystemExit(f"no manifests under {args.true_base} -- run Phase 1 first")

    for man in mans:
        d = os.path.dirname(man)
        for r in csv.DictReader(open(man)):
            true_pdb = os.path.join(d, r["pocket_file"])
            if not os.path.exists(true_pdb):
                continue
            residues, lig_true = read_pdb(true_pdb)
            set_true, at_true = pocket_residues(residues, lig_true)

            set_cur, at_cur, iou = None, None, None
            cur_pdb = cur.get(r["pocket_key"])
            if cur_pdb:
                # Same receptor conformation, so residue keys are directly comparable.
                res_c, lig_cur = read_pdb(cur_pdb)
                set_cur, at_cur = pocket_residues(res_c, lig_cur)
                union = set_true | set_cur
                iou = len(set_true & set_cur) / len(union) if union else float("nan")

            screen_dir = (f"AF-{r['uniprot']}-F1-model_v4_{r['domain']}_{r['pocket']}")
            e = enr.get(screen_dir, {})
            rows.append({
                "screen_dir": screen_dir,
                "pocket_key": r["pocket_key"],
                "uniprot": r["uniprot"], "domain": r["domain"], "pocket": r["pocket"],
                "conf": r["conf"], "pdb_id": r.get("pdb_id", ""),
                "het_code": r.get("het_code", ""),
                "n_lig_true": len(lig_true),
                "n_res_true": len(set_true), "n_atoms_true": at_true,
                "n_res_cur": len(set_cur) if set_cur is not None else "",
                "n_atoms_cur": at_cur if at_cur is not None else "",
                "res_ratio": round(len(set_true) / len(set_cur), 3)
                             if set_cur else "",
                "iou": round(iou, 4) if iou is not None else "",
                "centroid_offset": r.get("centroid_offset", ""),
                "align_rmsd": r.get("align_rmsd", ""),
                "align_len": r.get("align_len", ""),
                "over_crop_true": int(at_true > args.max_pocket_atoms),
                "over_crop_cur": (int(at_cur > args.max_pocket_atoms)
                                  if at_cur is not None else ""),
                "auc_z": e.get("auc_z", ""), "ef5pct_z": e.get("ef5pct_z", ""),
                "flag": r.get("flag", ""),
            })

    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {len(rows)} conformation rows -> {args.out}")

    # ---- summary ------------------------------------------------------------------
    def fget(row, k):
        try:
            return float(row[k])
        except (TypeError, ValueError):
            return None

    print("\n=== pocket geometry, per conformation ===")
    print(f"  true-ligand residues : median {med([r['n_res_true'] for r in rows]):.0f}")
    print(f"  true-ligand atoms    : median {med([r['n_atoms_true'] for r in rows]):.0f}"
          f"   over {args.max_pocket_atoms}: "
          f"{sum(r['over_crop_true'] for r in rows)}/{len(rows)}")
    offs = [fget(r, "centroid_offset") for r in rows]
    offs = [o for o in offs if o is not None]
    if offs:
        print(f"  centroid_offset      : median {st.median(offs):.2f} A  "
              f"q90 {np.percentile(offs, 90):.2f}  max {max(offs):.2f}  "
              f"(>5 A: {sum(o > 5 for o in offs)}/{len(offs)})")
    ious = [fget(r, "iou") for r in rows]
    ious = [i for i in ious if i is not None]
    if ious:
        print(f"  IoU(current, true)   : median {st.median(ious):.3f}  "
              f"q25 {np.percentile(ious, 25):.3f}  q75 {np.percentile(ious, 75):.3f}")
        print(f"  current residues     : median {med([fget(r,'n_res_cur') for r in rows]):.0f}")
    else:
        print("  IoU                  : not computed (no --current-base matches)")

    # ---- per pocket, then the paper's fig. S10A test ------------------------------
    byp = defaultdict(list)
    for r in rows:
        byp[r["screen_dir"]].append(r)
    print(f"\n=== per pocket ({len(byp)} pockets) ===")
    pk_iou, pk_auc, pk_off = [], [], []
    for sd, rs in byp.items():
        a = fget(rs[0], "auc_z")
        i = med([fget(x, "iou") for x in rs])
        o = med([fget(x, "centroid_offset") for x in rs])
        if a is not None:
            pk_auc.append(a)
            pk_iou.append(i)
            pk_off.append(o)
    if pk_auc:
        rho_i, n_i = spearman(pk_iou, pk_auc)
        rho_o, n_o = spearman(pk_off, pk_auc)
        print(f"  Spearman(IoU, auc_z)             = {rho_i:+.3f}  (n={n_i})"
              "   <- paper fig. S10A analogue")
        print(f"  Spearman(centroid_offset, auc_z) = {rho_o:+.3f}  (n={n_o})"
              "   <- negative means a mislocated pocket scores worse")
        good = [a for a, o in zip(pk_auc, pk_off) if o is not None and o <= 2]
        bad = [a for a, o in zip(pk_auc, pk_off) if o is not None and o > 5]
        if good:
            print(f"  pockets with offset <= 2 A : n={len(good):3d}  AUC median {med(good):.3f}")
        if bad:
            print(f"  pockets with offset >  5 A : n={len(bad):3d}  AUC median {med(bad):.3f}")

    if ious:
        print("\n=== go/no-go for Phase 4 ===")
        m = st.median(ious)
        if m > 0.7:
            print(f"  IoU median {m:.3f} is HIGH -- our pocket already matches the authors'.")
            print("  The pocket definition is not the bottleneck; do NOT spend GPU on a rebuild.")
        else:
            print(f"  IoU median {m:.3f} is LOW -- our pocket differs materially from the")
            print("  authors'. A rebuild is justified; proceed to Phase 4.")


if __name__ == "__main__":
    main()
