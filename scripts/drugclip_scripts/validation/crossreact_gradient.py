#!/usr/bin/env python3
"""Is the mismatched-target control a null, or is it measuring real cross-reactivity?

The mismatched control scores a target's actives against a *different* target's pocket. On a
set that is mostly kinases that is not a neutral control: ATP-site inhibitors genuinely bind
related kinases, so an elevated mismatched AUC may be correct pharmacology rather than an
artefact. A leaders-vs-decoy population artefact predicts the same elevation, so the single
control number cannot separate the two.

They differ in one respect. Cross-reactivity depends on WHICH partner you are scored against —
high for a close relative, ~0.5 for an unrelated target. A population artefact is flat across
partners, because it is a property of the molecules and not of the pocket.

`target_scores.npz` holds every target's score for the whole deck, so we can score each
target's actives against all N-1 other pockets instead of the one cyclic-shift partner, and
regress that on how similar the two targets are (correlation of how they rank the full deck).

Usage:
    python crossreact_gradient.py output/enrichment_out_ligand_chembl [more_dirs ...]
        [--screen-results /home/marina/Documents/AI2050/Targets/screen_results]

Reads results dirs produced with --dump-npz. Runs entirely offline on the laptop.
"""

import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from plot_roc import load_actives                                    # noqa: E402

DEFAULT_SCREEN = "/home/marina/Documents/AI2050/Targets/screen_results"


def cross_auc_matrix(results_dir, screen_results):
    """-> (uniprots, A, S, n_deck).

    A[i, j] = ROC-AUC of target i's actives ranked by target j's pocket (diagonal = matched).
    S[i, j] = Pearson correlation of targets i and j over the full deck = how similarly the two
              pockets rank the same library, used as a data-driven target-similarity measure.
    """
    with open(os.path.join(results_dir, "deck_smiles.txt"), encoding="utf-8") as f:
        deck = [ln.strip() for ln in f]
    smi2idx = {}
    for i, s in enumerate(deck):
        if s:
            smi2idx.setdefault(s, i)

    d = np.load(os.path.join(results_dir, "target_scores.npz"))
    actives = load_actives(screen_results, smi2idx)
    unis = [u for u in sorted(d.files) if u in actives]
    n_deck = len(deck)

    # Rank each target's score vector once; AUC for any active set is then a rank sum
    # (Mann-Whitney U), which is O(n_act) per pair instead of an O(N log N) sort per pair.
    ranks = {}
    for u in unis:
        order = np.argsort(d[u].astype(np.float64), kind="stable")   # ascending
        r = np.empty(n_deck)
        r[order] = np.arange(1, n_deck + 1)
        ranks[u] = r

    def auc(act, r):
        na = len(act)
        return (r[act].sum() - na * (na + 1) / 2.0) / (na * (n_deck - na))

    A = np.array([[auc(actives[u], ranks[v]) for v in unis] for u in unis])
    S = np.corrcoef(np.vstack([d[u].astype(np.float64) for u in unis]))
    return unis, A, S, n_deck


def report(results_dir, screen_results):
    unis, A, S, n_deck = cross_auc_matrix(results_dir, screen_results)
    n = len(unis)
    eye = np.eye(n, dtype=bool)

    print(f"\n{'=' * 70}\n{os.path.basename(results_dir.rstrip('/'))}"
          f"   deck {n_deck:,}   targets {n}\n{'=' * 70}")
    print(f"  matched (diagonal)              median AUC {np.median(np.diag(A)):.3f}")
    print(f"  mismatched (all {n - 1} partners)   median AUC {np.median(A[~eye]):.3f}")
    print(f"  per-target WORST partner        median AUC "
          f"{np.median([A[i][~eye[i]].min() for i in range(n)]):.3f}")
    print(f"  per-target BEST partner         median AUC "
          f"{np.median([A[i][~eye[i]].max() for i in range(n)]):.3f}")

    sim, cross = S[~eye], A[~eye]
    print(f"\n  partner similarity vs mismatched AUC:  r = {np.corrcoef(sim, cross)[0, 1]:.3f}")
    q = np.quantile(sim, [0.0, 1 / 3, 2 / 3, 1.0])
    print(f"\n  {'partner similarity':<24s}{'n pairs':>9s}{'median AUC':>13s}{'frac > 0.6':>12s}")
    for lo, hi, lab in [(q[0], q[1], "least similar third"),
                        (q[1], q[2], "middle third"),
                        (q[2], q[3], "most similar third")]:
        m = (sim >= lo) & (sim <= hi)
        print(f"  {lab:<24s}{m.sum():>9d}{np.median(cross[m]):>13.3f}"
              f"{(cross[m] > 0.6).mean():>12.2f}")

    print("\n  A rising gradient (and sub-chance worst partners) means the control is measuring\n"
          "  cross-reactivity, not an artefact — so it is a HARD control, not a null.")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("results_dirs", nargs="+", help="dirs holding target_scores.npz + deck_smiles.txt")
    ap.add_argument("--screen-results", default=DEFAULT_SCREEN)
    args = ap.parse_args()

    for d in args.results_dirs:
        for p in ("target_scores.npz", "deck_smiles.txt"):
            if not os.path.isfile(os.path.join(d, p)):
                print(f"ERROR: {d}/{p} not found — the run needs --dump-npz")
                return
        report(d, args.screen_results)


if __name__ == "__main__":
    main()
