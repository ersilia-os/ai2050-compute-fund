#!/usr/bin/env python3
"""
Compare two DrugCLIP screens of the same library (milestone 3b): is the new one the old one
plus the intended changes, and nothing else?

Built for the Hit Locator check: the 6 Oct screen (`screen/`, targets_ligand + the OLD
targets_mtb) against the 25 Nov screen (`screen_v2/`, ai2050_targets = targets_ligand +
targets_mtb_v2, new loader). The human pockets and the library embeddings did not change,
so every human target and pocket row must reproduce. The Mtb rows are expected to differ;
they are listed, not tested.

Checks
------
  deck      same molecules; if the order differs, rows are re-paired by SMILES
  labels    every new row is targets_ligand or targets_mtb_v2; counts per set
  human     per targets_ligand target and pocket: max |dz| old vs new, and the overlap of
            the top 1% (the regime the EF@1% figure was measured in). FLOAT-level noise
            can swap molecules tied at the top-1% boundary, so overlap just under 1 is
            expected then; a DIFFERENT row with low overlap is not
  mtb       which Mtb targets are new, gone, or present in both (pockets redefined)

Verdict per row: IDENTICAL (bit-equal), FLOAT (max |dz| < 1e-3, i.e. summation-order noise
from BLAS on a different node or thread count; changes no ranking that matters), DIFFERENT.
The 1e-3 is a regression tolerance for "same computation", not a scientific cutoff.

Read-only, ~1-2 GB RAM for a 460k library. Run on a head node:
    /shared/python39/bin/python3.9 compare-screens.py \
        --old /fsx/output/Enamine_Hit_Locator_460K/screen \
        --new /fsx/output/Enamine_Hit_Locator_460K/screen_v2

Exit code 0 if every human row is IDENTICAL or FLOAT, 1 otherwise.
"""

import argparse
import os
import sys

import numpy as np

HUMAN = "targets_ligand"
FLOAT_TOL = 1e-3


def load_deck(d):
    with open(os.path.join(d, "deck_smiles.txt"), encoding="utf-8") as f:
        return [ln.rstrip("\n") for ln in f if ln.strip()]


def load_npz(d, name):
    z = np.load(os.path.join(d, name), allow_pickle=False)
    return {k: z[k] for k in z.files}


def row_keys(npz, kind):
    uni = [str(u) for u in npz["uniprot"]]
    if kind == "target":
        return uni
    return [f"{u}|{dom}|{p}" for u, dom, p in zip(uni, npz["domain"], npz["pocket"])]


def set_names(npz):
    if "set_name" in npz:
        return [str(s) for s in npz["set_name"]]
    return [None] * len(npz["uniprot"])


def top_set(v, k):
    return set(np.argpartition(-v.astype(np.float64), k - 1)[:k].tolist())


def verdict(dz):
    if dz == 0.0:
        return "IDENTICAL"
    return "FLOAT" if dz < FLOAT_TOL else "DIFFERENT"


def compare(kind, old, new, old_cols, k_top):
    """Compare the human rows of one matrix kind. Returns the number of DIFFERENT rows."""
    ok, nk = row_keys(old, kind), row_keys(new, kind)
    o_idx = {k: i for i, k in enumerate(ok)}
    o_set, n_set = set_names(old), set_names(new)
    O, N = old["scores"], new["scores"]

    rows, missing = [], []
    for j, key in enumerate(nk):
        if n_set[j] != HUMAN:
            continue
        i = o_idx.get(key)
        if i is None:
            missing.append(key)
            continue
        if o_set[i] not in (HUMAN, None):
            missing.append(f"{key} (old set {o_set[i]})")
            continue
        a = O[i][old_cols].astype(np.float64)
        b = N[j].astype(np.float64)
        finite = np.isfinite(a) & np.isfinite(b)
        dz = float(np.abs(a[finite] - b[finite]).max()) if finite.any() else float("inf")
        if (~finite).any() and not np.array_equal(~np.isfinite(a), ~np.isfinite(b)):
            dz = float("inf")
        overlap = len(top_set(a, k_top) & top_set(b, k_top)) / k_top
        rows.append((key, dz, overlap))

    counts = {"IDENTICAL": 0, "FLOAT": 0, "DIFFERENT": 0}
    for _, dz, _ in rows:
        counts[verdict(dz)] += 1
    top_changed = sum(1 for *_, ov in rows if ov < 1.0)
    worst = max((dz for _, dz, _ in rows), default=0.0)
    min_ov = min((ov for *_, ov in rows), default=1.0)
    print(f"\n{kind} rows, {HUMAN}: {len(rows)} compared | "
          + " ".join(f"{k} {v}" for k, v in counts.items())
          + f" | max |dz| {worst:.2e} | top-1% not identical in {top_changed}"
          + f" (min overlap {min_ov:.4f})")
    for key, dz, ov in sorted(rows, key=lambda r: -r[1]):
        if verdict(dz) == "DIFFERENT" or ov < 1.0:
            print(f"   {verdict(dz):9s} {key}: max |dz| {dz:.3e}, top-1% overlap {ov:.4f}")
    if missing:
        print(f"   not in old run ({len(missing)}): " + ", ".join(missing[:20]))
    return counts["DIFFERENT"] + len(missing)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--old", required=True, help="e.g. /fsx/output/<lib>/screen")
    ap.add_argument("--new", required=True, help="e.g. /fsx/output/<lib>/screen_v2")
    a = ap.parse_args()

    # ── deck ────────────────────────────────────────────────────────────────
    d_old, d_new = load_deck(a.old), load_deck(a.new)
    print(f"deck: old {len(d_old):,} molecules, new {len(d_new):,}")
    if d_old == d_new:
        print("  same molecules, same order")
        old_cols = slice(None)
    else:
        pos = {}
        for i, s in enumerate(d_old):
            pos.setdefault(s, i)
        miss = [s for s in d_new if s not in pos]
        if miss or len(set(d_new)) != len(d_new):
            sys.exit(f"ERROR: decks differ beyond order ({len(miss)} new SMILES not in old, "
                     f"{len(d_new) - len(set(d_new))} duplicates in new); "
                     "rows cannot be paired")
        print("  same molecules, DIFFERENT order -- re-paired by SMILES")
        old_cols = np.array([pos[s] for s in d_new])
    k_top = max(1, len(d_new) // 100)

    # ── labels ──────────────────────────────────────────────────────────────
    t_old, t_new = load_npz(a.old, "target_scores.npz"), load_npz(a.new, "target_scores.npz")
    sets_new = set_names(t_new)
    labels = {}
    for s in sets_new:
        labels[s] = labels.get(s, 0) + 1
    print(f"\nnew targets by set: " + ", ".join(f"{k} {v}" for k, v in sorted(labels.items(), key=str)))
    bad_labels = [s for s in labels if s not in (HUMAN, "targets_mtb_v2")]
    if bad_labels:
        print(f"   UNEXPECTED set_name values: {bad_labels}")
    sets_old = set_names(t_old)
    if sets_old[0] is None:
        print("   (old run has no set_name column; old rows matched by UniProt only)")

    # ── human rows ──────────────────────────────────────────────────────────
    n_bad = compare("target", t_old, t_new, old_cols, k_top)
    del t_old
    p_old, p_new = load_npz(a.old, "pocket_scores.npz"), load_npz(a.new, "pocket_scores.npz")
    n_bad += compare("pocket", p_old, p_new, old_cols, k_top)
    del p_old, p_new

    # ── Mtb: listed, not tested ─────────────────────────────────────────────
    new_mtb = {str(u) for u, s in zip(t_new["uniprot"], sets_new) if s != HUMAN}
    new_human = {str(u) for u, s in zip(t_new["uniprot"], sets_new) if s == HUMAN}
    t_old = load_npz(a.old, "target_scores.npz")
    old_mtb = {str(u) for u, s in zip(t_old["uniprot"], sets_old)
               if s != HUMAN and str(u) not in new_human}
    print(f"\nMtb targets (expected to differ, not tested):")
    print(f"   new only  ({len(new_mtb - old_mtb)}): {' '.join(sorted(new_mtb - old_mtb))}")
    print(f"   gone      ({len(old_mtb - new_mtb)}): {' '.join(sorted(old_mtb - new_mtb))}")
    print(f"   in both   ({len(new_mtb & old_mtb)}): {' '.join(sorted(new_mtb & old_mtb))}  "
          "(pockets redefined in targets_mtb_v2)")

    print("\nRESULT: human rows reproduce" if n_bad == 0
          else f"\nRESULT: {n_bad} human row(s) DIFFERENT or missing -- see above")
    sys.exit(0 if n_bad == 0 else 1)


if __name__ == "__main__":
    main()
