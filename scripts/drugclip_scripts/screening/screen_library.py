#!/usr/bin/env python3
"""
Score an encoded molecule library against every encoded pocket — the production screen.

This is NOT validation: there are no labels, no actives and no enrichment. It scores a
library against pocket sets and writes the full score matrices plus a per-target top-N.
Validation lives in ../validation/; see docs/claude_sessions/2026-09-18_drugclip_validation.md
for what the numbers from that arm do and do not license.

Scoring, identical to the validated path
----------------------------------------
Per-fold cosine (`conformation_scores`), robust-z per conformation over the whole deck
(`robust_z`), then max-pool: over a pocket's conformations for the pocket score, and over
all of a target's conformations for the target score.  Both are imported from
enrichment_validation so there is exactly one implementation.

The z step is load-bearing for multi-conformation pockets.  Within one conformation the
background is a strictly increasing affine map and every rank metric is invariant to it,
but the max-pool ACROSS conformations is not — without z, a conformation with a higher
baseline wins the pool regardless of fit.

Two guards that the raw files fail silently without (both inherited from `_iter_pairs`)
-----------------------------------------------------------------------------------
  * h5 rows are in LEXICOGRAPHIC key order, not input order, and `mol_reps` carries no
    molecule identity — so positional pairing is wrong and invisible.
  * a job that dies mid-encode leaves a correctly-shaped, mostly-zero h5; chunks whose
    per-fold norms are not all ~1 are dropped rather than scored.

Both caused the pre-2026-09-14 embeddings to be void.  Do not reimplement either.

Pocket sets are kept SEPARABLE in the output (`set_name` column).  `targets_ligand` has a
measured enrichment (EF@1% 28.6, AUC 0.944 on a 236k deck); `targets_mtb_v2` has none,
because those targets have no `leader.csv`.  Merging them into one ranked list would attach
the first number to the second set's results.

`set_name` is the pocket set's folder name, except for a merged folder such as
`ai2050_targets` (targets_ligand + targets_mtb_v2 side by side): there the folder name says
nothing about provenance, so each target's original set is read from `<base>/sets.csv`
(`uniprot,set_name`).  A target missing from that file is an error, not a fallback.

Runs on cpu-queue — this is BLAS, not inference.

Memory: the deck is held once, at N x 768 x 4 bytes (1.4 GB for 460k, 32 GB for REAL
10.4M), plus the score rows ((targets + pockets) x N x 4 bytes) and one target's (c, N)
temporaries. Expected peak for REAL ~45-50 GB, under a c6i.8xlarge's 64 GB. The run
prints its measured peak RSS at the end.
"""

import argparse
import csv
import os
import resource
import sys

import h5py
import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "..", "validation"))

from score_validation import _h5_files, _iter_pairs, load_pocket_reps   # noqa: E402
from enrichment_validation import conformation_scores, robust_z         # noqa: E402


def peak_rss_gb():
    """Peak resident memory of this process so far (Linux reports ru_maxrss in KiB)."""
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024 ** 2


def load_deck(emb_dir, library, input_dir):
    """(smiles list, Mf (6,128,N) float32) for the whole library, holding ONE copy of it.

    The deck is allocated once and each chunk is copied straight into its slot, so the
    peak is one deck plus one chunk. The previous version stacked a list of every chunk
    (vstack, then a redundant astype, then a transposed copy), which held up to three full
    copies at once: ~96 GB for REAL 10.4M, against 64 GB on a c6i.8xlarge.

    Chunks come from _iter_pairs in the same order, with the same row-order and
    partial-fold guards, so the deck is value-for-value what the old code built.
    """
    # Upper bound from the h5 headers (no data read). Chunks the guards drop leave unused
    # columns at the end, sliced off below as a view rather than a copy.
    n_max = 0
    for path in _h5_files(emb_dir, library):
        with h5py.File(path, "r") as f:
            n_max += f["mol_reps"].shape[0]
    if n_max == 0:
        sys.exit(f"ERROR: no embeddings under {emb_dir}")

    Mf = np.empty((6, 128, n_max), dtype=np.float32)
    smis, off = [], 0
    for chunk_smis, emb in _iter_pairs(emb_dir, library=library, input_dir=input_dir):
        n = len(emb)
        if off + n > n_max:
            sys.exit("ERROR: chunks grew while loading -- is an encode job still writing?")
        # (n,768) -> (n,6,128) -> (6,128,n), written in place
        Mf[:, :, off:off + n] = emb.reshape(n, 6, 128).transpose(1, 2, 0)
        smis.extend(chunk_smis)
        off += n
    if off == 0:
        sys.exit(f"ERROR: no usable embeddings under {emb_dir}")
    if len(smis) != off:
        sys.exit(f"ERROR: {len(smis)} smiles vs {off} rows after loading")
    if off < n_max:
        # View, not copy. Each Mf[f] keeps a unit inner stride, so the GEMMs still go
        # straight to BLAS without copying.
        print(f"  {n_max - off} rows of skipped chunks left unused")
        Mf = Mf[:, :, :off]
    return smis, Mf


def read_manifest(targets_base, uniprot):
    """pocket_key -> (domain, pocket). manifest.csv is the common interface across sets."""
    path = os.path.join(targets_base, uniprot, "pockets", "manifest.csv")
    out = {}
    if not os.path.isfile(path):
        return out
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            key = row.get("pocket_key")
            if key:
                out[key] = (row.get("domain", "0"), row.get("pocket", "?"))
    return out


def targets_in(base):
    if not os.path.isdir(base):
        return []
    return sorted(d for d in os.listdir(base)
                  if os.path.isfile(os.path.join(base, d, "pockets", "pocket_reps.pkl")))


def read_sets(base):
    """uniprot -> original set name from <base>/sets.csv; {} for an unmerged pocket set."""
    path = os.path.join(base, "sets.csv")
    if not os.path.isfile(path):
        return {}
    with open(path, newline="") as f:
        return {r["uniprot"]: r["set_name"] for r in csv.DictReader(f)}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--library", required=True, help="e.g. Enamine_Hit_Locator_460K")
    ap.add_argument("--emb-dir", default=None,
                    help="default /fsx/output/<library>/drugclip")
    ap.add_argument("--input-dir", default=None,
                    help="default /fsx/input/<library>; holds <lib>_chunk_NNN.csv")
    ap.add_argument("--targets-base", action="append", default=None, metavar="DIR",
                    help="repeatable; default /fsx/input/ai2050_targets (the merged "
                         "targets_ligand + targets_mtb_v2 set)")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--top-n", type=int, default=1000,
                    help="rows per target in the top-N export. NOT a validated cutoff -- "
                         "at 460k molecules the top 1%% is 4,600, the regime the EF@1%% "
                         "figure was measured in. The full matrices are written regardless, "
                         "so this only sets the convenience export.")
    ap.add_argument("--no-full-matrix", action="store_true",
                    help="skip the .npz score matrices (they are what makes every later "
                         "question answerable without rescoring)")
    a = ap.parse_args()

    emb_dir = a.emb_dir or f"/fsx/output/{a.library}/drugclip"
    input_dir = a.input_dir or f"/fsx/input/{a.library}"
    bases = a.targets_base or ["/fsx/input/ai2050_targets"]
    os.makedirs(a.out_dir, exist_ok=True)

    print(f"library     : {a.library}")
    print(f"embeddings  : {emb_dir}")
    print(f"inputs      : {input_dir}")
    print(f"pocket sets : {', '.join(bases)}")
    print(f"top-N       : {a.top_n}   (output-size parameter, not a scientific cutoff)\n")

    # Resolve every target's set name BEFORE the deck load, so a merged pocket set with an
    # incomplete sets.csv fails in seconds rather than after the library is in memory.
    set_of = {}
    for base in bases:
        base_name = os.path.basename(base.rstrip("/"))
        sets = read_sets(base)
        for uni in targets_in(base):
            if sets and uni not in sets:
                sys.exit(f"ERROR: {uni} under {base} is not listed in {base}/sets.csv")
            set_of[(base, uni)] = sets.get(uni, base_name)

    print("Loading deck ...")
    smis, Mf = load_deck(emb_dir, a.library, input_dir)
    n_mol = Mf.shape[2]
    print(f"  {n_mol} molecules, deck {n_mol * 768 * 4 / 1e9:.2f} GB, "
          f"peak RSS so far {peak_rss_gb():.1f} GiB\n")

    pocket_rows, target_rows = [], []
    pocket_meta, target_meta = [], []
    cache = {}

    for base in bases:
        base_name = os.path.basename(base.rstrip("/"))
        unis = targets_in(base)
        if not unis:
            print(f"WARN  {base_name}: no encoded targets under {base}")
            continue
        print(f"{base_name}: {len(unis)} targets")
        for uni in unis:
            set_name = set_of[(base, uni)]
            got = load_pocket_reps(base, uni, cache)
            if got is None:
                continue
            names, _name2idx, P = got                      # P (c,6,128), per-fold unit-norm
            # Guard: an encode that died mid-fold leaves a shaped-but-zero block.
            fold_norms = np.linalg.norm(P, axis=2)
            if float(fold_norms.min()) < 0.9:
                bad = int((fold_norms <= 0.9).any(axis=1).sum())
                print(f"  SKIP {uni}: {bad}/{len(names)} conformations have an empty fold")
                continue

            S = conformation_scores(P, Mf)                 # (c, N) mean per-fold cosine
            if not np.isfinite(S).all():
                print(f"  WARN {uni}: non-finite cosines")
            Z, _mad_min = robust_z(S)                      # per-conformation normalisation

            # target score: max-pool over ALL of this target's conformations
            target_rows.append(Z.max(axis=0))
            target_meta.append((uni, set_name, len(names)))

            # pocket score: max-pool within each pocket
            key2grp = read_manifest(base, uni)
            groups = {}
            for i, nm in enumerate(names):
                grp = key2grp.get(nm, ("0", nm))           # unmapped -> its own pocket
                groups.setdefault(grp, []).append(i)
            for (domain, pocket), idx in sorted(groups.items()):
                pocket_rows.append(Z[idx].max(axis=0))
                pocket_meta.append((uni, set_name, domain, pocket, len(idx)))
            print(f"  {uni}: {len(names)} conformations -> {len(groups)} pockets")
        print()

    if not target_rows:
        sys.exit("ERROR: nothing scored")

    # The deck is not needed past scoring: free it before stacking the score rows, and
    # free each row list once stacked. Rows are already float32 (copy=False is a no-op
    # check, not a copy).
    del Mf, cache
    T = np.vstack(target_rows).astype(np.float32, copy=False)
    del target_rows
    P_ = np.vstack(pocket_rows).astype(np.float32, copy=False)
    del pocket_rows
    print(f"scored {T.shape[0]} targets / {P_.shape[0]} pockets x {n_mol} molecules")

    with open(os.path.join(a.out_dir, "deck_smiles.txt"), "w") as f:
        f.write("\n".join(smis) + "\n")

    if not a.no_full_matrix:
        np.savez_compressed(
            os.path.join(a.out_dir, "target_scores.npz"), scores=T,
            uniprot=np.array([m[0] for m in target_meta]),
            set_name=np.array([m[1] for m in target_meta]),
            n_conf=np.array([m[2] for m in target_meta]))
        np.savez_compressed(
            os.path.join(a.out_dir, "pocket_scores.npz"), scores=P_,
            uniprot=np.array([m[0] for m in pocket_meta]),
            set_name=np.array([m[1] for m in pocket_meta]),
            domain=np.array([m[2] for m in pocket_meta]),
            pocket=np.array([m[3] for m in pocket_meta]),
            n_conf=np.array([m[4] for m in pocket_meta]))
        print(f"wrote target_scores.npz and pocket_scores.npz to {a.out_dir}")

    # top-N per target. float64 before ranking: float32 over a narrow cosine range ties
    # spuriously, which silently reorders the head of the list.
    out_csv = os.path.join(a.out_dir, f"top_{a.top_n}_per_target.csv")
    with open(out_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["uniprot", "set_name", "rank", "smiles", "score_z"])
        for r, (uni, set_name, _nc) in enumerate(target_meta):
            v = T[r].astype(np.float64)
            k = min(a.top_n, len(v))
            top = np.argpartition(-v, k - 1)[:k]
            top = top[np.argsort(-v[top], kind="stable")]
            for rank, i in enumerate(top, 1):
                w.writerow([uni, set_name, rank, smis[i], f"{v[i]:.4f}"])
    print(f"wrote {out_csv}")
    print(f"\npeak RSS {peak_rss_gb():.1f} GiB for {n_mol} molecules "
          f"(scale by molecule count to size a larger library)")
    print("\nNOTE: targets_ligand carries a measured enrichment (EF@1% 28.6, AUC 0.944);")
    print("      targets_mtb_v2 has none. Keep the set_name blocks separate in any report.")


if __name__ == "__main__":
    main()
