#!/usr/bin/env python3
"""
Build a pockets_index.csv restricted to the conformations of one pocket set.

Why this is needed
------------------
`run-validation.sh` passes the shared
`/fsx/input/validation_leaders/pockets_index.csv`, which covers all 339 pockets across
66 targets.  The true-ligand set only has 157 pockets / 576 conformations, because the
GenPack-route ligand was never distributed.

`enrichment_validation.py` survives that at the POCKET level -- a pocket with no resolvable
conformation is emitted with `status="skip_no_conf"` and excluded.  But at the TARGET level
it does not:

    keys_t = ordered_unique_keys(groups, sds, name2idx)   # only conformations that exist
    ...
    act_t  = target_act[uni]                              # actives unioned over ALL pockets

so a target's actives would come from all its pockets while its scores came from only the
template ones -- an inflated active set, and metrics not comparable to the baseline.
`n_pockets` would be overstated too.

Filtering the index fixes both levels.  Use the SAME restricted index for the baseline run
and the rebuilt run and the comparison is exactly like-for-like: same pockets, same
conformations, same actives, same deck -- only the pocket geometry differs.

Usage:
    python make_restricted_index.py \
        --index        /fsx/input/validation_leaders/pockets_index.csv \
        --targets-base /fsx/input/targets_ligand \
        --out          /fsx/input/validation_leaders/pockets_index_ligand.csv
"""

import argparse
import csv
import glob
import os
import sys
from collections import defaultdict

COLUMNS = ["screen_dir", "uniprot", "domain", "pocket", "pocket_key", "leader_csv"]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--index", required=True, help="the full pockets_index.csv")
    ap.add_argument("--targets-base", required=True,
                    help="pocket set to restrict to; its <ID>/pockets/manifest.csv are read")
    ap.add_argument("--out", required=True)
    ap.add_argument("--min-targets", type=int, default=10,
                    help="warn if fewer targets survive than enrichment_validation.py accepts")
    args = ap.parse_args()

    mans = sorted(glob.glob(os.path.join(args.targets_base, "*", "pockets", "manifest.csv")))
    if not mans:
        sys.exit(f"no manifest.csv under {args.targets_base}")

    keep = set()
    for m in mans:
        d = os.path.dirname(m)
        for r in csv.DictReader(open(m)):
            # Only conformations whose PDB is actually present can ever be encoded.
            if os.path.exists(os.path.join(d, r["pocket_file"])):
                keep.add(r["pocket_key"])
    print(f"{len(mans)} manifests -> {len(keep)} conformation keys in {args.targets_base}")

    rows_in, rows_out = 0, []
    with open(args.index, newline="") as f:
        rd = csv.DictReader(f)
        missing = [c for c in COLUMNS if c not in (rd.fieldnames or [])]
        if missing:
            sys.exit(f"{args.index} is missing columns: {missing}")
        for r in rd:
            rows_in += 1
            if r["pocket_key"] in keep:
                rows_out.append({c: r[c] for c in COLUMNS})

    if not rows_out:
        sys.exit("no index rows matched - do the pocket_keys agree between the two sets?")

    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        w.writeheader()
        w.writerows(rows_out)

    pockets = defaultdict(int)
    for r in rows_out:
        pockets[r["screen_dir"]] += 1
    unis = {r["uniprot"] for r in rows_out}
    print(f"wrote {args.out}")
    print(f"  {len(rows_out)} conformation rows (from {rows_in})")
    print(f"  {len(pockets)} pockets, {len(unis)} targets")
    print(f"  conformations per pocket: min {min(pockets.values())} max {max(pockets.values())}")

    n1 = sum(1 for v in pockets.values() if v == 1)
    print(f"  single-conformation pockets: {n1}  "
          "(these give the free n_conf==1 z-vs-cos identity check)")

    # keys present in the pocket set but absent from the index would be silently unscored
    idx_keys = {r["pocket_key"] for r in rows_out}
    orphan = keep - idx_keys
    if orphan:
        print(f"  NOTE {len(orphan)} conformation(s) exist in {args.targets_base} but are not "
              f"in the index - they will not be scored. e.g. {sorted(orphan)[:2]}")

    if len(unis) < args.min_targets:
        print(f"  WARNING only {len(unis)} targets; enrichment_validation.py needs "
              f">= {args.min_targets} unless --allow-partial-deck is passed")


if __name__ == "__main__":
    main()
