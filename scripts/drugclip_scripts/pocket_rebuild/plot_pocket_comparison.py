#!/usr/bin/env python3
"""Single-point vs true-ligand pockets: the Phase 4 result, in four panels.

Both arms score the SAME 155 pockets, 573 conformations and 35,931-molecule deck. Only the
pocket geometry differs, so every difference here is attributable to that.

Usage:
    conda run -n chemvis_env python plot_pocket_comparison.py
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
BASE = os.path.join(ROOT, "enrichment_out_tpl_base")
LIG = os.path.join(ROOT, "enrichment_out_tpl_lig")


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


def plot_paired(ax, xb, xl, nc):
    """Per-pocket AUC, baseline against true-ligand. Points above the diagonal improved."""
    ax.axhline(0.5, color=nc.gray, zorder=0)
    ax.axvline(0.5, color=nc.gray, zorder=0)
    ax.plot([0, 1], [0, 1], color=nc.gray, zorder=1)
    ax.scatter(xb, xl, color=nc.plum, zorder=2)
    ax.set_xlim(0.1, 1.0)
    ax.set_ylim(0.1, 1.0)
    up = int(np.sum(np.asarray(xl) > np.asarray(xb)))
    stylia.label(ax, xlabel="AUC, single-point pocket", ylabel="AUC, true-ligand pocket",
                 title=f"{up}/{len(xb)} pockets improved", abc="A")


def plot_ecdf_auc(ax, data, nc):
    """Matched vs mismatched, both arms. The control is what makes the result credible."""
    ax.axvline(0.5, color=nc.gray, zorder=0)
    for (lab, v, color) in data:
        x, y = ecdf(v)
        ax.plot(x, y, color=color, label=lab)
    ax.set_xlim(0.0, 1.0)
    ax.legend()
    stylia.label(ax, xlabel="ROC-AUC per pocket", ylabel="Cumulative fraction",
                 title="Matched vs mismatched control", abc="B")


def plot_ef(ax, data, nc):
    """EF@5%; null is 1. Clipped at 20 so the bulk stays readable."""
    ax.axvline(1.0, color=nc.gray, zorder=0)
    for (lab, v, color) in data:
        x, y = ecdf(np.clip(v, 0, 20))
        ax.plot(x, y, color=color, label=lab)
    ax.set_xlim(0, 20)
    ax.legend()
    stylia.label(ax, xlabel="EF@5% per pocket (clipped at 20)", ylabel="Cumulative fraction",
                 title="Enrichment factor, null = 1", abc="C")


def plot_targets(ax, tb, tl, nc):
    """Per-target AUC, ordered by the true-ligand arm."""
    order = np.argsort(tl)
    idx = np.arange(len(tl))
    ax.axhline(0.5, color=nc.gray, zorder=0)
    ax.plot(idx, np.asarray(tb)[order], color=nc.blue, label="single point")
    ax.plot(idx, np.asarray(tl)[order], color=nc.plum, label="true ligand")
    ax.set_ylim(0.0, 1.0)
    ax.legend()
    stylia.label(ax, xlabel="Target (ordered by true-ligand AUC)", ylabel="ROC-AUC",
                 title="57 targets", abc="D")


def main():
    nc = stylia.NamedColors()
    Pb, Tb, Cb = load(BASE)
    Pl, Tl, Cl = load(LIG)
    keys = [k for k in Pl if k in Pb]
    tkeys = [k for k in Tl if k in Tb]

    auc_b = [num(Pb[k]["auc_z"]) for k in keys]
    auc_l = [num(Pl[k]["auc_z"]) for k in keys]
    mm_b = [num(Cb["pocket"][k]["auc_z_mismatch"]) for k in keys if k in Cb["pocket"]]
    mm_l = [num(Cl["pocket"][k]["auc_z_mismatch"]) for k in keys if k in Cl["pocket"]]

    ef_b = [num(Pb[k]["ef5pct_z"]) for k in keys]
    ef_l = [num(Pl[k]["ef5pct_z"]) for k in keys]
    efm_b = [num(Cb["pocket"][k]["ef5pct_z_mismatch"]) for k in keys if k in Cb["pocket"]]
    efm_l = [num(Cl["pocket"][k]["ef5pct_z_mismatch"]) for k in keys if k in Cl["pocket"]]

    # Four clearly distinct colours: the two matched arms are the comparison, the two
    # mismatched arms are the controls and must be visually separable from both.
    auc_data = [
        ("true ligand, matched", auc_l, nc.plum),
        ("true ligand, mismatched", mm_l, nc.mint),
        ("single point, matched", auc_b, nc.blue),
        ("single point, mismatched", mm_b, nc.gray),
    ]
    ef_data = [
        ("true ligand, matched", ef_l, nc.plum),
        ("true ligand, mismatched", efm_l, nc.mint),
        ("single point, matched", ef_b, nc.blue),
        ("single point, mismatched", efm_b, nc.gray),
    ]

    fig, axs = stylia.create_figure(2, 2)
    plot_paired(axs.next(), auc_b, auc_l, nc)
    plot_ecdf_auc(axs.next(), auc_data, nc)
    plot_ef(axs.next(), ef_data, nc)
    plot_targets(axs.next(),
                 [num(Tb[k]["auc_z"]) for k in tkeys],
                 [num(Tl[k]["auc_z"]) for k in tkeys], nc)
    out = os.path.join(ROOT, "pocket_rebuild_comparison.png")
    stylia.save_figure(out)
    print(f"wrote {out}")
    print(f"  pockets {len(keys)}  targets {len(tkeys)}")
    print(f"  AUC  median  {np.median(auc_b):.3f} -> {np.median(auc_l):.3f}")
    print(f"  EF5% median  {np.median(ef_b):.3f} -> {np.median(ef_l):.3f}")


if __name__ == "__main__":
    main()
