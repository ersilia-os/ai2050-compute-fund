#!/usr/bin/env python3
"""
Merge several encoded pocket sets into one "best available definition" set.

The pocket sets cover different subsets of the 339 pockets:

    targets_ligand    true PDBbind ligand, 6 A         157 template pockets / 57 targets
    targets_fpocket   fpocket cavity pseudo-ligand     12 targets (467 genpack + 103 template)
    targets           1-atom probe at the grid centre  all 339 pockets / 66 targets

Each is already encoded, and `pocket_key` is identical across sets by construction, so they
can be merged per CONFORMATION without touching a GPU: take each conformation from the
highest-priority set that has it, fall back down the list otherwise. The result is full
339-pocket coverage scored with the best definition we have for each pocket, which is what
"how is the pipeline doing overall" actually means.

Writes, per target, under --out-base:
    <ID>/pockets/pocket_reps.pkl   (names, reps)  — same format as the inputs
    <ID>/pockets/manifest.csv      — copied from the fallback set, filtered to merged keys
and one provenance table at the top level:
    pocket_source.csv              uniprot,pocket_key,source

The provenance table is the point of the exercise as much as the merge — it lets the plot
colour every pocket by which definition it actually got.

Usage:
    python merge_pocket_sets.py \
        --sources /fsx/input/targets_ligand /fsx/input/targets_fpocket /fsx/input/targets \
        --out-base /fsx/input/targets_best

--sources is in PRIORITY ORDER, best first. The last one should be the set with full
coverage, or some pockets will be missing from the merge.
"""

import argparse
import csv
import os
import pickle
import shutil
import sys
from collections import Counter

import numpy as np


def load_reps(base, uni):
    """-> (names, reps (n,6,128)) or None."""
    p = os.path.join(base, uni, "pockets", "pocket_reps.pkl")
    if not os.path.isfile(p):
        return None
    with open(p, "rb") as f:
        names, reps = pickle.load(f)
    reps = np.asarray(reps, dtype=np.float32)
    if len(names) != len(reps):
        print(f"  WARN {uni} in {base}: {len(names)} names vs {len(reps)} reps — skipping")
        return None
    return list(names), reps


def targets_in(base):
    if not os.path.isdir(base):
        return set()
    return {d for d in os.listdir(base)
            if os.path.isfile(os.path.join(base, d, "pockets", "pocket_reps.pkl"))}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sources", nargs="+", required=True,
                    help="pocket set dirs in PRIORITY ORDER, best first; last should have full coverage")
    ap.add_argument("--out-base", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    for s in args.sources:
        if not os.path.isdir(s):
            sys.exit(f"source not found: {s}")

    # Same refusal as submit-pocket-encode.sh / stage-ligand-pockets.sh: never write over a
    # production or source pocket set. `--out-base /fsx/input/targets` is one keystroke away
    # from `targets_best` and would silently destroy the baseline every other arm compares to.
    out = os.path.realpath(args.out_base.rstrip("/"))
    if os.path.basename(out) == "targets":
        sys.exit(f"refusing to write to the production pocket set: {out}\n"
                 "  pick a new name, e.g. --out-base /fsx/input/targets_best")
    for s in args.sources:
        if os.path.realpath(s.rstrip("/")) == out:
            sys.exit(f"refusing to write into a source set: {out}")

    fallback = args.sources[-1]

    all_targets = sorted(set().union(*(targets_in(s) for s in args.sources)))
    if not all_targets:
        sys.exit("no encoded targets found in any source")
    print(f"{len(all_targets)} targets across {len(args.sources)} sources")
    print(f"priority: {' > '.join(os.path.basename(s) for s in args.sources)}")

    tally = Counter()
    provenance = []
    n_written = 0

    for uni in all_targets:
        merged = {}                       # pocket_key -> (rep, source)
        for src in args.sources:          # priority order: first wins
            got = load_reps(src, uni)
            if got is None:
                continue
            names, reps = got
            tag = os.path.basename(src)
            for name, rep in zip(names, reps):
                if name not in merged:
                    merged[name] = (rep, tag)
        if not merged:
            print(f"  SKIP {uni}: no conformations in any source")
            continue

        # Keep the fallback set's ordering where possible so the merged pkl reads like the
        # baseline; anything only present in a higher-priority set is appended.
        base_order = []
        got_fb = load_reps(fallback, uni)
        if got_fb is not None:
            base_order = [n for n in got_fb[0] if n in merged]
        names_out = base_order + [n for n in merged if n not in set(base_order)]
        reps_out = np.stack([merged[n][0] for n in names_out]).astype(np.float32)

        for n in names_out:
            src = merged[n][1]
            tally[src] += 1
            provenance.append((uni, n, src))

        if args.dry_run:
            n_written += 1
            continue

        pdir = os.path.join(args.out_base, uni, "pockets")
        os.makedirs(pdir, exist_ok=True)
        with open(os.path.join(pdir, "pocket_reps.pkl"), "wb") as f:
            pickle.dump((names_out, reps_out), f)

        # manifest: take the fallback's (it has every pocket_key) and filter to what we kept
        src_man = os.path.join(fallback, uni, "pockets", "manifest.csv")
        dst_man = os.path.join(pdir, "manifest.csv")
        if os.path.isfile(src_man):
            keep = set(names_out)
            with open(src_man, newline="") as fi:
                rdr = csv.DictReader(fi)
                rows = [r for r in rdr if r.get("pocket_key") in keep]
                fields = rdr.fieldnames
            with open(dst_man, "w", newline="") as fo:
                w = csv.DictWriter(fo, fieldnames=fields)
                w.writeheader()
                w.writerows(rows)
        else:
            for s in args.sources:
                alt = os.path.join(s, uni, "pockets", "manifest.csv")
                if os.path.isfile(alt):
                    shutil.copy(alt, dst_man)
                    break
            else:
                print(f"  WARN {uni}: no manifest.csv in any source — pocket grouping will fail")
        n_written += 1

    if not args.dry_run:
        os.makedirs(args.out_base, exist_ok=True)
        with open(os.path.join(args.out_base, "pocket_source.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["uniprot", "pocket_key", "source"])
            w.writerows(provenance)

    print("")
    print("conformations by source:")
    for src, n in tally.most_common():
        print(f"  {src:<22s} {n:>6d}")
    print(f"  {'TOTAL':<22s} {sum(tally.values()):>6d}")
    print(f"\n{'would write' if args.dry_run else 'wrote'} {n_written} targets → {args.out_base}")
    if not args.dry_run:
        print(f"provenance → {args.out_base}/pocket_source.csv")


if __name__ == "__main__":
    main()
