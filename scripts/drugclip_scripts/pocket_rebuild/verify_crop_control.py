#!/usr/bin/env python3
"""
Phase 0 control: did changing ONLY --max-pocket-atoms change only the cropped pockets?

The whole value of the 256 -> 511 re-encode is that it has a built-in control.  Pockets whose
6 A shell holds <= 256 heavy atoms were never cropped, so their embeddings must come back
unchanged.  Pockets above the limit went through CroppingPocketDataset's seeded random
subsample (weighted toward the centroid, so it sheds the periphery) and must change.

Three possible verdicts, and only one of them makes the AUC comparison worth looking at:

  VALID        under-256 unchanged, over-256 moved.  Interpret the AUC.
  INVALID      under-256 moved too -> something other than --max-pocket-atoms differs
               between the runs.  Do not interpret the AUC; find out what changed.
  NULL RESULT  over-256 barely moved -> the crop was doing almost nothing.  Expect no AUC
               change, and save the scoring job.

"Unchanged" means per-fold cosine > 0.999, not bit-identical: the encoder runs under --fp16
and is mildly non-deterministic.

Pocket sizes are computed once and cached (--cache), because parsing ~2,264 conformation PDBs
off FSx is the slow part and you will want to re-run this.

Usage (head node):
    /shared/python39/bin/python3.9 verify_crop_control.py \
        --old-base /fsx/input/targets \
        --new-base /fsx/input/targets_a511 \
        --threshold 256
"""

import argparse
import csv
import glob
import os
import pickle
import sys
import time
from multiprocessing import Pool

import numpy as np

CUTOFF = 6.0          # upstream's hard-coded radius, encode_pockets.py:102


def pocket_atom_count(path):
    """Heavy atoms in complete residues within 6 A of the LIG ligand.

    Residues are contiguous in these PDBs, so we take the per-atom minimum distance to the
    ligand and reduce it over residue boundaries -- much faster than a dict of per-residue
    lists when this runs over thousands of files.
    """
    xs, keys, lig = [], [], []
    try:
        with open(path) as f:
            for l in f:
                if l.startswith("ATOM"):
                    if l[76:78].strip() == "H":
                        continue
                    xs.append((float(l[30:38]), float(l[38:46]), float(l[46:54])))
                    keys.append(l[21] + l[22:27])
                elif l.startswith("HETATM"):
                    if l[76:78].strip() == "H":
                        continue
                    lig.append((float(l[30:38]), float(l[38:46]), float(l[46:54])))
    except (OSError, ValueError):
        return path, -1
    if not xs or not lig:
        return path, 0
    P, L = np.asarray(xs), np.asarray(lig)
    # per-atom min distance to any ligand atom, chunked so the matrix stays small
    dmin = np.empty(len(P))
    for i in range(0, len(P), 4096):
        blk = P[i:i + 4096]
        dmin[i:i + 4096] = np.linalg.norm(blk[:, None, :] - L[None, :, :], axis=-1).min(axis=1)
    # residue boundaries
    ks = np.asarray(keys)
    starts = np.flatnonzero(np.r_[True, ks[1:] != ks[:-1]])
    res_min = np.minimum.reduceat(dmin, starts)
    sizes = np.diff(np.r_[starts, len(P)])
    return path, int(sizes[res_min <= CUTOFF].sum())


def load_cache(path):
    if not path or not os.path.exists(path):
        return {}
    out = {}
    with open(path) as f:
        for r in csv.DictReader(f):
            out[r["path"]] = int(r["n_atoms"])
    return out


def save_cache(path, d):
    if not path:
        return
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["path", "n_atoms"])
        w.writerows(sorted(d.items()))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--old-base", default="/fsx/input/targets")
    ap.add_argument("--new-base", default="/fsx/input/targets_a511")
    ap.add_argument("--threshold", type=int, default=256,
                    help="the OLD run's --max-pocket-atoms; pockets above it were cropped")
    ap.add_argument("--tol", type=float, default=0.999,
                    help="per-fold cosine above this counts as unchanged (fp16 noise)")
    ap.add_argument("--cache", default="pocket_atom_counts.csv")
    ap.add_argument("--out", default="crop_control.csv")
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    args = ap.parse_args()

    new_pkls = sorted(glob.glob(os.path.join(args.new_base, "*", "pockets", "pocket_reps.pkl")))
    if not new_pkls:
        sys.exit(f"no pocket_reps.pkl under {args.new_base}")
    print(f"{len(new_pkls)} encoded targets under {args.new_base}")

    # ---- pair up embeddings ----------------------------------------------------
    rows, need = [], []
    for new_pkl in new_pkls:
        pdir = os.path.dirname(new_pkl)
        tid = os.path.basename(os.path.dirname(pdir))
        old_pkl = os.path.join(args.old_base, tid, "pockets", "pocket_reps.pkl")
        man = os.path.join(pdir, "manifest.csv")
        if not os.path.exists(old_pkl):
            print(f"  skip {tid}: no baseline pkl")
            continue
        if not os.path.exists(man):
            print(f"  skip {tid}: no manifest.csv")
            continue
        with open(old_pkl, "rb") as f:
            on, orp = pickle.load(f)
        with open(new_pkl, "rb") as f:
            nn, nrp = pickle.load(f)
        orp = np.asarray(orp, dtype=np.float64)
        nrp = np.asarray(nrp, dtype=np.float64)
        oi = {n: i for i, n in enumerate(on)}
        f2 = {r["pocket_key"]: r["pocket_file"] for r in csv.DictReader(open(man))}
        for j, name in enumerate(nn):
            if name not in oi or name not in f2:
                continue
            p = os.path.join(pdir, f2[name])
            cos = float(np.einsum("fd,fd->", orp[oi[name]], nrp[j]) / orp.shape[1])
            rows.append({"uniprot": tid, "pocket_key": name, "path": p, "cosine": cos})
            need.append(p)

    print(f"{len(rows)} conformations matched between the two runs")
    if not rows:
        sys.exit("nothing matched - check that the two trees hold the same pocket_keys")

    # ---- pocket sizes, cached --------------------------------------------------
    cache = load_cache(args.cache)
    todo = sorted({p for p in need if p not in cache})
    if todo:
        print(f"measuring pocket size for {len(todo)} PDBs "
              f"({len(need) - len(todo)} cached), {args.jobs} workers ...")
        t0 = time.time()
        with Pool(args.jobs) as pool:
            for k, (p, n) in enumerate(pool.imap_unordered(pocket_atom_count, todo, 16), 1):
                cache[p] = n
                if k % 250 == 0 or k == len(todo):
                    el = time.time() - t0
                    print(f"  {k}/{len(todo)}  {el:.0f}s elapsed, "
                          f"~{el / k * (len(todo) - k):.0f}s left")
        save_cache(args.cache, cache)
        print(f"  cached to {args.cache}")
    else:
        print(f"all pocket sizes cached in {args.cache}")

    for r in rows:
        r["n_atoms"] = cache.get(r["path"], -1)
        r["cropped"] = int(r["n_atoms"] > args.threshold)

    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["uniprot", "pocket_key", "n_atoms",
                                          "cropped", "cosine", "path"])
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {args.out}")

    # ---- the verdict -----------------------------------------------------------
    bad = [r for r in rows if r["n_atoms"] < 0]
    under = [r["cosine"] for r in rows if 0 <= r["n_atoms"] <= args.threshold]
    over = [r["cosine"] for r in rows if r["n_atoms"] > args.threshold]

    print("\n" + "=" * 62)
    print(f"THE CONTROL  (threshold {args.threshold} heavy atoms, tol cosine > {args.tol})")
    print("=" * 62)
    if bad:
        print(f"  {len(bad)} PDBs unreadable - excluded")
    for nm, v in (("UNDER (never cropped, must be unchanged)", under),
                  ("OVER  (was cropped, should move)        ", over)):
        if v:
            print(f"  {nm}  n={len(v):4d}  cosine median {np.median(v):.6f}  "
                  f"min {min(v):.6f}")
        else:
            print(f"  {nm}  n=   0")
    n_under_moved = sum(c < args.tol for c in under)
    n_over_moved = sum(c < args.tol for c in over)
    print(f"\n  under-256 that moved : {n_under_moved}/{len(under)}   <-- expect 0")
    print(f"  over-256  that moved : {n_over_moved}/{len(over)}   <-- expect most")

    print()
    if under and n_under_moved > 0.02 * len(under):
        print("  INVALID -- pockets that were never cropped changed anyway.")
        print("  Something other than --max-pocket-atoms differs between the two runs.")
        print("  Do NOT interpret the AUC until that is explained.")
    elif over and n_over_moved < 0.5 * len(over):
        print("  NULL RESULT -- even the cropped pockets barely moved, so the 256 limit was")
        print("  doing little. Expect no AUC change; consider skipping the scoring job.")
    elif not over:
        print("  NO CROPPED POCKETS found above the threshold - nothing to test.")
    else:
        print("  VALID -- only the cropped pockets moved. The AUC comparison is interpretable.")
        print("  Next: run-validation.sh enrich with TARGETS_BASE=<new> VAL_TAG=<tag>,")
        print("        then compare AUC for cropped vs uncropped pockets separately.")


if __name__ == "__main__":
    main()
