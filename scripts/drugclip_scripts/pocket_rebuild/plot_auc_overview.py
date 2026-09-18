#!/usr/bin/env python3
"""
One overview figure of the whole pipeline — runs LOCALLY (needs stylia).

Every pocket and every target in a single view, with each point coloured by which pocket
DEFINITION it actually got (true ligand / fpocket cavity / 1-atom baseline). That is the
"how are we doing overall" picture: coverage and performance in the same frame, so it is
obvious both how good the good pockets are and how much of the set is still on the weak
definition.

  A  all pockets, sorted by AUC, coloured by source, against the 0.5 line
  B  per target (median over its pockets), sorted
  C  AUC distribution per source — the like-for-like comparison of definitions

Inputs: the enrichment run on the MERGED pocket set (see merge_pocket_sets.py), that set's
pocket_source.csv, and pockets_index.csv to map pocket_key -> screen_dir.

Usage:
    python plot_auc_overview.py ./enrichment_out_best/ \
        --pocket-source ./targets_best_pocket_source.csv \
        --pockets-index ./pockets_index.csv
"""

import argparse
import csv
import os
from collections import Counter, defaultdict

import numpy as np
import stylia

# Format: slide | Style: ersilia — change with stylia.set_format() / stylia.set_style()
stylia.set_format("slide")
stylia.set_style("ersilia")

SHORT = {"targets_ligand": "true ligand", "targets_fpocket": "fpocket cavity",
         "targets": "1-atom baseline", "targets_a511": "baseline a511",
         "targets_probe": "grown probe"}


def pocket_sources(pocket_source_csv, pockets_index_csv):
    """-> {screen_dir: source}. A pocket whose conformations disagree is labelled 'mixed'."""
    key2dir = {}
    with open(pockets_index_csv, newline="") as f:
        for r in csv.DictReader(f):
            key2dir[r["pocket_key"]] = r["screen_dir"]
    per_dir = defaultdict(Counter)
    with open(pocket_source_csv, newline="") as f:
        for r in csv.DictReader(f):
            sd = key2dir.get(r["pocket_key"])
            if sd:
                per_dir[sd][r["source"]] += 1
    out = {}
    for sd, c in per_dir.items():
        out[sd] = SHORT.get(c.most_common(1)[0][0], c.most_common(1)[0][0]) if len(c) == 1 \
            else "mixed"
    return out


def plot_pockets(ax, aucs, srcs, colors):
    order = np.argsort(aucs)
    x = np.arange(len(aucs))
    for s in sorted(set(srcs)):
        m = np.array([srcs[i] == s for i in order])
        if m.any():
            ax.scatter(x[m], aucs[order][m], color=colors[s], label=f"{s} ({m.sum()})")
    nc = stylia.NamedColors()
    ax.axhline(0.5, color=nc.gray, linestyle="--")
    ax.legend()
    stylia.label(ax, xlabel="Pocket (sorted)", ylabel="ROC-AUC",
                 title=f"{len(aucs)} pockets, median {np.median(aucs):.3f}", abc="A")


def plot_targets(ax, per_target):
    nc = stylia.NamedColors()
    v = np.array(sorted(per_target.values()))
    ax.scatter(np.arange(len(v)), v, color=nc.plum)
    ax.axhline(0.5, color=nc.gray, linestyle="--")
    stylia.label(ax, xlabel="Target (sorted)", ylabel="ROC-AUC",
                 title=f"{len(v)} targets, median {np.median(v):.3f}", abc="B")


def plot_by_source(ax, aucs, srcs, colors):
    labels = sorted(set(srcs))
    rng = np.random.default_rng(0)
    for i, s in enumerate(labels):
        v = aucs[np.array([x == s for x in srcs])]
        if not len(v):
            continue
        ax.scatter(i + rng.uniform(-0.18, 0.18, len(v)), v, color=colors[s])
        ax.plot([i - 0.3, i + 0.3], [np.median(v)] * 2, color=stylia.NamedColors().gray)
    nc = stylia.NamedColors()
    ax.axhline(0.5, color=nc.gray, linestyle="--")
    ax.set_xticks(range(len(labels)))
    ax.set_xticklabels(labels, rotation=20, ha="right")
    stylia.label(ax, xlabel="", ylabel="ROC-AUC", title="By pocket definition", abc="C")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results_dir")
    ap.add_argument("--pocket-source", required=True)
    ap.add_argument("--pockets-index", required=True)
    ap.add_argument("--auc-col", default="auc_z")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    rows = [r for r in csv.DictReader(
        open(os.path.join(args.results_dir, "enrichment_pockets.csv")))
        if r.get("status") == "ok" and r.get(args.auc_col)]
    if not rows:
        print("ERROR: no scored pockets")
        return
    src_of = pocket_sources(args.pocket_source, args.pockets_index)

    aucs = np.array([float(r[args.auc_col]) for r in rows])
    srcs = [src_of.get(r["screen_dir"], "unknown") for r in rows]
    per_target = defaultdict(list)
    for r, a in zip(rows, aucs):
        per_target[r["uniprot"]].append(a)
    per_target = {u: float(np.median(v)) for u, v in per_target.items()}

    labels = sorted(set(srcs))
    pal = stylia.CategoricalPalette("ersilia")
    colors = dict(zip(labels, pal.get(len(labels))))

    fig, axs = stylia.create_figure(1, 3)
    plot_pockets(axs.next(), aucs, srcs, colors)
    plot_targets(axs.next(), per_target)
    plot_by_source(axs.next(), aucs, srcs, colors)

    out = args.out or os.path.join(args.results_dir, "auc_overview.png")
    stylia.save_figure(out)
    print(f"Saved {out}")

    print(f"\nall pockets      n={len(aucs):4d}  median AUC {np.median(aucs):.3f}")
    print(f"all targets      n={len(per_target):4d}  median AUC "
          f"{np.median(list(per_target.values())):.3f}   (pocket_by_target)")
    for s in labels:
        v = aucs[np.array([x == s for x in srcs])]
        if len(v):
            print(f"  {s:<18s} n={len(v):4d}  median {np.median(v):.3f}  "
                  f"frac>0.5 {(v > 0.5).mean():.2f}")


if __name__ == "__main__":
    main()
