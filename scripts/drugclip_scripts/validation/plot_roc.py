#!/usr/bin/env python3
"""
ROC curves for every target — runs LOCALLY (needs stylia).

Rebuilds the curves from `target_scores.npz` + `deck_smiles.txt` (written by
enrichment_validation.py --dump-npz) and the local screen_results leader lists. Nothing is
recomputed on the cluster: the npz holds each target's score for all ~36k deck molecules.

Because the npz has every target, the MISMATCHED control curves are reconstructed too — the
same deterministic cyclic shift over sorted UniProts that enrichment_validation.py uses.
That comparison is the point: with a deck where every molecule is somebody's top hit, the
matched mean curve pulling away from the mismatched mean curve is the result, not the
distance from the diagonal.

Default figure: all 66 matched curves (lightened), the mean matched curve, the mean
mismatched curve, and the diagonal.  --grid instead draws one small panel per target,
sorted by AUC.

Run with a conda env that has stylia:
    STYLIA_ENV=$(for e in $(conda env list | grep -v '#' | grep -v '^base' | awk '{print $1}'); do
        conda run -n $e python -c "import stylia" 2>/dev/null && echo $e && break; done)
    conda run -n $STYLIA_ENV python plot_roc.py ./enrichment_out/

Usage:
    python plot_roc.py <results_dir> [--screen-results DIR] [--grid] [--out PNG]
"""

import argparse
import csv
import os
import re

import numpy as np
import stylia

# Format: slide | Style: ersilia — change with stylia.set_format() / stylia.set_style()
stylia.set_format("slide")
stylia.set_style("ersilia")

SCREEN_RE = re.compile(r"^AF-(?P<uni>.+?)-F1-model_v4_(?P<dom>\d+)_(?P<pocket>.+)$")
GRID = np.linspace(0.0, 1.0, 201)


def load_actives(screen_dir, smi2idx):
    """UniProt → deck indices of that target's leader molecules (union over its pockets)."""
    csv.field_size_limit(10 * 1024 * 1024)
    by_uni = {}
    for d in sorted(os.listdir(screen_dir)):
        m = SCREEN_RE.match(d)
        if not m:
            continue
        leader = os.path.join(screen_dir, d, "leader.csv")
        if not os.path.isfile(leader):
            continue
        acc = by_uni.setdefault(m.group("uni"), set())
        with open(leader, newline="") as f:
            for row in csv.DictReader(f):
                j = smi2idx.get((row.get("smiles") or "").strip())
                if j is not None:
                    acc.add(j)
    return {u: np.fromiter(sorted(v), dtype=np.int64) for u, v in by_uni.items() if v}


def roc(y, s):
    """(fpr, tpr, auc) — step curve, highest score first."""
    order = np.argsort(-s, kind="stable")
    ys = y[order].astype(np.float64)
    tps, fps = np.cumsum(ys), np.cumsum(1.0 - ys)
    na, nd = tps[-1], fps[-1]
    if na == 0 or nd == 0:
        return None, None, float("nan")
    fpr, tpr = np.r_[0.0, fps / nd], np.r_[0.0, tps / na]
    return fpr, tpr, float(np.trapz(tpr, fpr))


def curves(scores, actives, n_deck, partner_of=None):
    """-> (interpolated TPRs on GRID, aucs, uniprots) for matched or mismatched labels."""
    tprs, aucs, unis = [], [], []
    for u in sorted(scores):
        lab_u = partner_of[u] if partner_of else u
        if lab_u not in actives:
            continue
        y = np.zeros(n_deck, dtype=np.uint8)
        y[actives[lab_u]] = 1
        fpr, tpr, a = roc(y, scores[u].astype(np.float64))
        if fpr is None:
            continue
        tprs.append(np.interp(GRID, fpr, tpr))
        aucs.append(a)
        unis.append(u)
    return np.array(tprs), np.array(aucs), unis


def plot_overlay(ax, tprs, aucs, mm_tprs, mm_aucs):
    nc = stylia.NamedColors()
    for t in tprs:
        ax.plot(GRID, t, color=nc.get("plum", lighten=0.75))
    ax.plot([0, 1], [0, 1], color=nc.gray, linestyle="--")
    if len(mm_tprs):
        ax.plot(GRID, mm_tprs.mean(axis=0), color=nc.orange,
                label=f"mismatched (AUC {np.median(mm_aucs):.3f})")
    ax.plot(GRID, tprs.mean(axis=0), color=nc.plum,
            label=f"matched (AUC {np.median(aucs):.3f})")
    ax.legend()
    stylia.label(ax, xlabel="False positive rate", ylabel="True positive rate",
                 title=f"{len(tprs)} targets")


def plot_grid(axs, tprs, aucs, unis, n):
    nc = stylia.NamedColors()
    order = np.argsort(-aucs)
    for k in range(n):
        ax = axs.next()
        if k < len(order):
            i = order[k]
            ax.plot(GRID, tprs[i], color=nc.plum)
            ax.plot([0, 1], [0, 1], color=nc.gray, linestyle="--")
            stylia.label(ax, xlabel="", ylabel="", title=f"{unis[i]} {aucs[i]:.2f}")
        else:
            stylia.label(ax, xlabel="", ylabel="")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results_dir", help="Dir holding target_scores.npz + deck_smiles.txt")
    ap.add_argument("--screen-results", default="/home/marina/Documents/AI2050/Targets/screen_results")
    ap.add_argument("--grid", action="store_true", help="One panel per target instead of an overlay")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    npz = os.path.join(args.results_dir, "target_scores.npz")
    smi = os.path.join(args.results_dir, "deck_smiles.txt")
    for p in (npz, smi):
        if not os.path.isfile(p):
            print(f"ERROR: {p} not found — the run needs --dump-npz")
            return

    with open(smi, encoding="utf-8") as f:
        deck = [ln.strip() for ln in f]
    smi2idx = {}
    for i, s in enumerate(deck):
        if s:
            smi2idx.setdefault(s, i)
    d = np.load(npz)
    scores = {u: d[u] for u in d.files}
    n_deck = len(deck)
    print(f"deck {n_deck}, targets {len(scores)}")

    actives = load_actives(args.screen_results, smi2idx)
    print(f"label sets recovered for {len(actives)} targets")

    ks = sorted(scores)
    partner_of = {u: ks[(i + 1) % len(ks)] for i, u in enumerate(ks)}

    tprs, aucs, unis = curves(scores, actives, n_deck)
    mm_tprs, mm_aucs, _ = curves(scores, actives, n_deck, partner_of)
    if not len(tprs):
        print("ERROR: no curves built — check --screen-results")
        return
    print(f"matched   median AUC {np.median(aucs):.4f}  (min {aucs.min():.3f} max {aucs.max():.3f})")
    if len(mm_aucs):
        print(f"mismatched median AUC {np.median(mm_aucs):.4f}")
        print(f"targets beating their own control: {int((aucs > mm_aucs).sum())}/{len(aucs)}")

    if args.grid:
        n = len(tprs)
        ncols = 8
        nrows = int(np.ceil(n / ncols))
        fig, axs = stylia.create_figure(nrows, ncols)
        plot_grid(axs, tprs, aucs, unis, nrows * ncols)
        out = args.out or os.path.join(args.results_dir, "roc_grid.png")
    else:
        # Single square panel (ROC): width=0.5, height=0.5
        fig, axs = stylia.create_figure(1, 1, width=0.5, height=0.5)
        plot_overlay(axs.next(), tprs, aucs, mm_tprs, mm_aucs)
        out = args.out or os.path.join(args.results_dir, "roc_targets.png")

    stylia.save_figure(out)
    print(f"Saved {out}")

    worst = np.argsort(aucs)
    print("\nlowest  AUC:", ", ".join(f"{unis[i]} {aucs[i]:.3f}" for i in worst[:5]))
    print("highest AUC:", ", ".join(f"{unis[i]} {aucs[i]:.3f}" for i in worst[-5:][::-1]))


if __name__ == "__main__":
    main()
