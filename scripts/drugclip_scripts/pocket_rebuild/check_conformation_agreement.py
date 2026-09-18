#!/usr/bin/env python3
"""QC: do a pocket's conformations agree on which residues belong to it?

Why this exists
---------------
Phase 1 validated each transposed ligand by centroid offset -- |ligand centroid - grid
centre|. That check has a blind spot: a ligand is elongated, so its centre can be in exactly
the right place while its long axis points the wrong way, and the 6 A shell then selects a
completely different residue set.

Observed on P17252 pocket "0": centroid offsets all 1.4-4.0 A (passing), yet the pocket is
the ATP site displaced 7.2 A, missing the DFG motif (D481-F482-G483) and reaching into the
C-terminus instead. AUC 0.359, while the same target's correctly-oriented pockets score
0.841 and 0.800.

The check
---------
Every conformation of one pocket is the SAME site on the SAME protein -- a different
GenPack-refined receptor and a different template ligand, but the same binding site. So
their residue sets should largely agree. A conformation that disagrees with its siblings has
a badly-oriented (or plain wrong) ligand.

Costs nothing but reading the PDBs we already have, and needs no re-encoding to interpret.

Usage:
    python check_conformation_agreement.py \
        --true-base /home/marina/Documents/AI2050/Targets/targets_ligand \
        --enrichment /home/marina/ersilia/AI2050-Compute-Fund/enrichment_out_tpl_lig
"""

import argparse
import csv
import glob
import itertools
import os
import statistics as st
from collections import defaultdict

import numpy as np

CUTOFF = 6.0


def pocket_residues(path, cutoff=CUTOFF):
    """Residue keys within `cutoff` A of the LIG ligand, plus the ligand centroid."""
    res = defaultdict(list)
    lig = []
    with open(path) as f:
        for l in f:
            if l.startswith("ATOM"):
                res[(l[21], l[22:27])].append(
                    (float(l[30:38]), float(l[38:46]), float(l[46:54])))
            elif l.startswith("HETATM"):
                lig.append((float(l[30:38]), float(l[38:46]), float(l[46:54])))
    L = np.asarray(lig)
    if not len(L):
        return set(), None
    keep = set()
    for k, v in res.items():
        if np.linalg.norm(np.asarray(v)[:, None, :] - L[None, :, :], axis=-1).min() <= cutoff:
            keep.add(k)
    return keep, L.mean(axis=0)


def jaccard(a, b):
    u = a | b
    return len(a & b) / len(u) if u else float("nan")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--true-base", required=True)
    ap.add_argument("--enrichment", default="",
                    help="enrichment dir to join AUC against (optional)")
    ap.add_argument("--min-agreement", type=float, default=0.5,
                    help="flag a pocket whose median pairwise Jaccard is below this")
    ap.add_argument("--out", default="conformation_agreement.csv")
    args = ap.parse_args()

    # pocket -> [(conf, pdb_id, residue set, centroid)]
    pockets = defaultdict(list)
    for man in sorted(glob.glob(os.path.join(args.true_base, "*", "pockets", "manifest.csv"))):
        d = os.path.dirname(man)
        for r in csv.DictReader(open(man)):
            p = os.path.join(d, r["pocket_file"])
            if not os.path.exists(p):
                continue
            s, c = pocket_residues(p)
            key = (r["uniprot"], r["domain"], r["pocket"])
            pockets[key].append((r["conf"], r.get("pdb_id", ""), s, c,
                                 float(r.get("centroid_offset", "nan"))))

    enr = {}
    if args.enrichment:
        f = os.path.join(args.enrichment, "enrichment_pockets.csv")
        if os.path.exists(f):
            enr = {r["screen_dir"]: r for r in csv.DictReader(open(f))}

    rows, flagged = [], []
    for (uni, dom, pk), confs in sorted(pockets.items()):
        sd = f"AF-{uni}-F1-model_v4_{dom}_{pk}"
        auc = enr.get(sd, {}).get("auc_z", "")
        if len(confs) < 2:
            rows.append({"screen_dir": sd, "uniprot": uni, "domain": dom, "pocket": pk,
                         "n_conf": 1, "median_jaccard": "", "min_jaccard": "",
                         "worst_conf": "", "worst_conf_agreement": "",
                         "n_res_median": len(confs[0][2]), "auc_z": auc, "flag": "single_conf"})
            continue

        js = [jaccard(a[2], b[2]) for a, b in itertools.combinations(confs, 2)]
        # each conformation vs the consensus of the others
        per = {}
        for i, c in enumerate(confs):
            others = [confs[j][2] for j in range(len(confs)) if j != i]
            per[c[0]] = st.median([jaccard(c[2], o) for o in others])
        worst = min(per, key=per.get)
        med = st.median(js)
        flag = "LOW_AGREEMENT" if med < args.min_agreement else ""
        rows.append({"screen_dir": sd, "uniprot": uni, "domain": dom, "pocket": pk,
                     "n_conf": len(confs), "median_jaccard": round(med, 3),
                     "min_jaccard": round(min(js), 3),
                     "worst_conf": worst, "worst_conf_agreement": round(per[worst], 3),
                     "n_res_median": int(st.median([len(c[2]) for c in confs])),
                     "auc_z": auc, "flag": flag})
        if flag:
            flagged.append((sd, med, per, confs, auc))

    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {args.out}  ({len(rows)} pockets)")

    multi = [r for r in rows if r["n_conf"] != 1]
    meds = [r["median_jaccard"] for r in multi]
    print(f"\n{len(multi)} multi-conformation pockets "
          f"({len(rows) - len(multi)} single-conformation, cannot be checked)")
    print(f"  median pairwise Jaccard: median {st.median(meds):.3f}  "
          f"q25 {np.percentile(meds, 25):.3f}  min {min(meds):.3f}")
    print(f"  pockets below {args.min_agreement}: {len(flagged)}")

    if flagged:
        print(f"\n=== LOW-AGREEMENT POCKETS (ligand orientation suspect) ===")
        for sd, med, per, confs, auc in sorted(flagged, key=lambda x: x[1]):
            a = f"{float(auc):.3f}" if auc else "  -  "
            print(f"  {sd:38s} AUC {a}  median Jaccard {med:.3f}  n_conf {len(confs)}")
            for c in confs:
                mark = "  <-- outlier" if per[c[0]] == min(per.values()) else ""
                print(f"       conf {c[0]:>10s} {c[1]:>5s}  agree {per[c[0]]:.3f}  "
                      f"n_res {len(c[2]):3d}  offset {c[4]:5.2f}A{mark}")

    # does agreement predict AUC?
    pairs = [(r["median_jaccard"], float(r["auc_z"])) for r in multi if r["auc_z"]]
    if len(pairs) > 5:
        x = np.array([p[0] for p in pairs]); y = np.array([p[1] for p in pairs])
        rho = np.corrcoef(np.argsort(np.argsort(x)), np.argsort(np.argsort(y)))[0, 1]
        print(f"\nSpearman(conformation agreement, AUC) = {rho:+.3f}  (n={len(pairs)})")
        lo = y[x < args.min_agreement]; hi = y[x >= args.min_agreement]
        if len(lo):
            print(f"  low-agreement  pockets: n={len(lo):3d}  AUC median {np.median(lo):.3f}")
        print(f"  high-agreement pockets: n={len(hi):3d}  AUC median {np.median(hi):.3f}")


if __name__ == "__main__":
    main()
