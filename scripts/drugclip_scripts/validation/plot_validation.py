#!/usr/bin/env python3
"""
Plot our DrugCLIP scores against the paper's — runs LOCALLY (needs stylia).

Reads the per-pocket scores.csv files produced by score_validation.py (downloaded from
the cluster) and draws a scatter with the paper's `score` on the x-axis and our score on
the y-axis, one point per (pocket, molecule), coloured by pocket. Absolute scales differ
(our z-score runs higher because our background is the leader union, not the 500M
library), so the visual signal is the monotonic/linear trend — a fitted line and the
overall Spearman/Pearson are annotated.

Run with a conda env that has stylia:
    STYLIA_ENV=$(for e in $(conda env list | grep -v '#' | grep -v '^base' | awk '{print $1}'); do
        conda run -n $e python -c "import stylia" 2>/dev/null && echo $e && break; done)
    conda run -n $STYLIA_ENV python plot_validation.py ./validation_out/validation

Usage:
    python plot_validation.py <results_dir> [--out validation_scatter.png]
  where <results_dir> contains <screen_dir>/scores.csv files.
"""

import argparse
import csv
import glob
import os

import numpy as np
import stylia

# Format: slide | Style: ersilia — change with stylia.set_format() / stylia.set_style()
stylia.set_format("slide")
stylia.set_style("ersilia")


def rankdata_desc(values):
    v = np.asarray(values, dtype=float)
    order = np.argsort(-v, kind="mergesort")
    ranks = np.empty(len(v), dtype=float)
    sv = v[order]
    i = 0
    while i < len(v):
        j = i
        while j + 1 < len(v) and sv[j + 1] == sv[i]:
            j += 1
        for k in range(i, j + 1):
            ranks[order[k]] = (i + j) / 2.0 + 1.0
        i = j + 1
    return ranks


def spearman(a, b):
    if len(a) < 3:
        return float("nan")
    ra, rb = rankdata_desc(a), rankdata_desc(b)
    if np.std(ra) == 0 or np.std(rb) == 0:
        return float("nan")
    return float(np.corrcoef(ra, rb)[0, 1])


def load_all(results_dir, score_col):
    files = sorted(glob.glob(os.path.join(results_dir, "*", "scores.csv")))
    if not files:
        # allow pointing directly at a dir of scores.csv or a parent
        files = sorted(glob.glob(os.path.join(results_dir, "**", "scores.csv"), recursive=True))
    paper, ours, pocket = [], [], []
    for sf in files:
        name = os.path.basename(os.path.dirname(sf))
        with open(sf, newline="") as f:
            for row in csv.DictReader(f):
                paper.append(float(row["paper_score"]))
                ours.append(float(row[score_col]))
                pocket.append(name)
    return np.array(paper), np.array(ours), pocket, files


def plot_scatter(ax, paper, ours, pocket, ylabel):
    labels = sorted(set(pocket))
    idx = {p: i for i, p in enumerate(labels)}
    codes = np.array([idx[p] for p in pocket])
    cm = stylia.CyclicColormap("ersilia")
    cm.fit(codes)
    ax.scatter(paper, ours, c=cm.transform(codes))

    # Linear trend line over the paper-score range
    if len(paper) >= 2 and np.std(paper) > 0:
        slope, intercept = np.polyfit(paper, ours, 1)
        xs = np.linspace(paper.min(), paper.max(), 100)
        nc = stylia.NamedColors()
        ax.plot(xs, slope * xs + intercept, color=nc.gray)

    rho = spearman(paper, ours)
    r = float(np.corrcoef(paper, ours)[0, 1]) if np.std(ours) > 0 else float("nan")
    stylia.label(
        ax,
        xlabel="Paper DrugCLIP score",
        ylabel=ylabel,
        title=f"n={len(paper)}, {len(labels)} pockets  |  Spearman={rho:.2f}  Pearson={r:.2f}",
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results_dir", help="Dir containing <screen_dir>/scores.csv files")
    ap.add_argument("--score-col", default="our_score_cos",
                    choices=["our_score_cos", "our_score_z"],
                    help="Which of our scores to plot on the y-axis (default: cosine, background-free)")
    ap.add_argument("--out", default=None, help="Output PNG (default: <results_dir>/validation_scatter_<col>.png)")
    args = ap.parse_args()

    paper, ours, pocket, files = load_all(args.results_dir, args.score_col)
    if len(paper) == 0:
        print(f"ERROR: no scores.csv found under {args.results_dir}")
        return
    print(f"Loaded {len(paper)} points from {len(files)} pockets ({args.score_col})")

    ylabel = "Our DrugCLIP cosine (max-pool)" if args.score_col == "our_score_cos" else "Our DrugCLIP z-score"
    out = args.out or os.path.join(args.results_dir, f"validation_scatter_{args.score_col}.png")

    # Single square panel (scatter): width=0.5, height=0.5
    fig, axs = stylia.create_figure(1, 1, width=0.5, height=0.5)
    plot_scatter(axs.next(), paper, ours, pocket, ylabel)
    stylia.save_figure(out)
    print(f"Saved {out}")


if __name__ == "__main__":
    main()
