#!/usr/bin/env python3
"""The two arms in the familiar 3-panel layout, on SHARED axes.

Top row  = single-point pockets (what we had).
Bottom   = true-ligand pockets (the paper's definition).

Same 155 pockets, 57 targets and 35,931-molecule deck in both; only pocket geometry differs.
Axis limits are shared per column, so the rows are directly comparable -- running
plot_enrichment.py twice autoscales each arm separately, which understates the difference.

Usage:
    /home/marina/anaconda3/envs/chemvis_env/bin/python plot_arms_side_by_side.py
"""

import csv
import os
from collections import defaultdict

import numpy as np
import stylia

# Format: slide | Style: ersilia - change with stylia.set_format() / stylia.set_style()
stylia.set_format("slide")
stylia.set_style("ersilia")

ROOT = "/home/marina/ersilia/AI2050-Compute-Fund"
ARMS = [("Single-point pocket", os.path.join(ROOT, "enrichment_out_tpl_base")),
        ("True-ligand pocket", os.path.join(ROOT, "enrichment_out_tpl_lig"))]
EF = "ef5pct_z"


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return np.nan


def load(d):
    P = {r["screen_dir"]: r for r in csv.DictReader(open(f"{d}/enrichment_pockets.csv"))}
    T = {r["uniprot"]: r for r in csv.DictReader(open(f"{d}/enrichment_targets.csv"))}
    # enrichment_controls.csv writes TWO rows per key: one carrying the shuffle stats
    # (partner_key empty) and one the mismatched-target stats. Assigning row-by-row lets the
    # second silently overwrite the first, which drops the shuffle control entirely.
    C = defaultdict(lambda: defaultdict(dict))
    for r in csv.DictReader(open(f"{d}/enrichment_controls.csv")):
        for k, v in r.items():
            if v != "" or k not in C[r["level"]][r["key"]]:
                C[r["level"]][r["key"]][k] = v
    return P, T, C


def ecdf(v):
    v = np.sort(np.asarray([x for x in v if np.isfinite(x)]))
    return v, np.arange(1, len(v) + 1) / len(v)


def plot_controls(ax, matched, mismatched, shuffled, nc, arm, abc):
    ax.axvline(1.0, color=nc.gray, zorder=0)
    for lab, v, col in [("matched", matched, nc.plum),
                        ("mismatched target", mismatched, nc.orange),
                        ("shuffled labels", shuffled, nc.gray)]:
        x, y = ecdf(v)
        ax.plot(x, y, color=col, label=f"{lab} (n={len(x)})")
    ax.set_xscale("symlog", linthresh=1.0)
    ax.set_xlim(-0.2, 100)
    ax.set_ylim(0, 1.02)
    ax.legend()
    stylia.label(ax, xlabel="EF@5% (symlog)", ylabel="Cumulative fraction",
                 title=f"{arm}: matched vs controls", abc=abc)


def plot_target_auc(ax, auc, nc, arm, abc):
    v = np.sort(np.asarray(auc))
    ax.axhline(0.5, color=nc.gray, zorder=0)
    ax.scatter(np.arange(len(v)), v, color=nc.plum)
    ax.set_ylim(0.0, 1.0)
    ax.set_xlim(-2, len(v) + 1)
    below = int(np.sum(v < 0.5))
    stylia.label(ax, xlabel="Target (sorted)", ylabel="ROC-AUC",
                 title=f"{arm}: AUC median {np.median(v):.3f} ({below}/{len(v)} below 0.5)",
                 abc=abc)


def plot_ef_vs_actives(ax, ef, nact, nc, arm, abc):
    ef = np.asarray(ef, float)
    nact = np.asarray(nact, float)
    ok = np.isfinite(ef) & (ef > 0)
    ax.axhline(1.0, color=nc.gray, zorder=0)
    ax.scatter(nact[ok], ef[ok], color=nc.plum)
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_ylim(0.05, 200)
    ax.set_xlim(8, 400)
    stylia.label(ax, xlabel="Actives in deck", ylabel="EF@5%",
                 title=f"{arm}: EF median {np.median(ef[ok]):.2f} ({int((~ok).sum())} zeros)",
                 abc=abc)


def main():
    nc = stylia.NamedColors()
    fig, axs = stylia.create_figure(2, 3)
    letters = iter("ABCDEF")
    for name, d in ARMS:
        P, T, C = load(d)
        keys = list(P)
        matched = [num(P[k][EF]) for k in keys]
        mismatched = [num(C["pocket"][k][f"{EF}_mismatch"]) for k in keys if k in C["pocket"]]
        shuffled = [num(C["pocket"][k][f"{EF}_shuffle_mean"]) for k in keys if k in C["pocket"]]
        short = "Single point" if "Single" in name else "True ligand"
        plot_controls(axs.next(), matched, mismatched, shuffled, nc, short, next(letters))
        plot_target_auc(axs.next(), [num(r["auc_z"]) for r in T.values()], nc,
                        short, next(letters))
        plot_ef_vs_actives(axs.next(), matched,
                           [num(P[k]["n_act_deck"]) for k in keys], nc, short, next(letters))
        print(f"{name}: EF@5% median {np.nanmedian(matched):.3f}  "
              f"mismatched {np.nanmedian(mismatched):.3f}  "
              f"target AUC median {np.median([num(r['auc_z']) for r in T.values()]):.3f}")
    out = os.path.join(ROOT, "pocket_arms_side_by_side.png")
    stylia.save_figure(out)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
