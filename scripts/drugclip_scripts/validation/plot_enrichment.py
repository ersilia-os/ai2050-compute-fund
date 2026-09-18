#!/usr/bin/env python3
"""
Plot the DrugCLIP enrichment results — runs LOCALLY (needs stylia).

Reads the CSVs written by enrichment_validation.py (downloaded from the cluster) and draws
three panels:

  A  ECDF of EF@1% over the pockets, MATCHED vs MISMATCHED-target vs shuffled labels.
     This is the panel that carries the result. Every molecule in the deck is somebody's
     top hit, so "EF > 1" is not the claim — "matched >> mismatched" is.
  B  Per-target ROC-AUC, sorted, against the 0.5 random line.
  C  EF@1% vs number of actives, with the attainable ceiling drawn in — EF is capped at
     1/chi only while the actives fit inside the top chi of the deck.

Run with a conda env that has stylia:
    STYLIA_ENV=$(for e in $(conda env list | grep -v '#' | grep -v '^base' | awk '{print $1}'); do
        conda run -n $e python -c "import stylia" 2>/dev/null && echo $e && break; done)
    conda run -n $STYLIA_ENV python plot_enrichment.py ./enrichment_out/

Usage:
    python plot_enrichment.py <results_dir> [--ef-col ef1pct_z] [--out enrichment.png]
  where <results_dir> holds enrichment_pockets.csv / _targets.csv / _controls.csv.
"""

import argparse
import csv
import os

import numpy as np
import stylia

# Format: slide | Style: ersilia — change with stylia.set_format() / stylia.set_style()
stylia.set_format("slide")
stylia.set_style("ersilia")


def read_csv(path):
    if not os.path.isfile(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def col(rows, name):
    """Finite float column."""
    out = []
    for r in rows:
        v = r.get(name, "")
        if v == "" or v is None:
            continue
        try:
            x = float(v)
        except ValueError:
            continue
        if np.isfinite(x):
            out.append(x)
    return np.asarray(out, dtype=float)


def merge_controls(rows):
    """enrichment_controls.csv has separate shuffle and mismatch rows per key — merge them."""
    merged = {}
    for r in rows:
        key = (r.get("level", ""), r.get("key", ""))
        m = merged.setdefault(key, {"level": key[0], "key": key[1]})
        for k, v in r.items():
            if v not in ("", None):
                m[k] = v
    return list(merged.values())


def ecdf(values):
    v = np.sort(values)
    return v, np.arange(1, v.size + 1) / v.size


def plot_ecdf(ax, series, ef_col):
    """series: list of (label, values, color)."""
    for label, values, color in series:
        if values.size == 0:
            continue
        x, y = ecdf(values)
        ax.plot(x, y, color=color, label=f"{label} (n={values.size})")
    nc = stylia.NamedColors()
    ax.axvline(1.0, color=nc.gray, linestyle="--")
    ax.set_xscale("symlog", linthresh=1.0)
    ax.legend()
    stylia.label(ax, xlabel=f"{ef_col} (symlog)", ylabel="Cumulative fraction of pockets",
                 title="Matched vs control", abc="A")


def plot_target_auc(ax, auc):
    nc = stylia.NamedColors()
    order = np.argsort(auc)
    ax.scatter(np.arange(auc.size), auc[order], color=nc.plum)
    ax.axhline(0.5, color=nc.gray, linestyle="--")
    stylia.label(ax, xlabel="Target (sorted)", ylabel="ROC-AUC",
                 title=f"Per-target AUC (median {np.median(auc):.3f})", abc="B")


def plot_ef_vs_actives(ax, n_act, ef, ef_max, ef_col):
    nc = stylia.NamedColors()
    ax.scatter(n_act, ef, color=nc.plum)
    if ef_max.size == n_act.size and ef_max.size:
        o = np.argsort(n_act)
        ax.plot(n_act[o], ef_max[o], color=nc.gray)
    ax.set_xscale("log")
    ax.set_yscale("log")
    # The log y-axis drops every EF==0 pocket, so say how many are missing rather than
    # letting the empty lower region read as "no pockets there".
    n_zero = int((ef == 0).sum())
    stylia.label(ax, xlabel="Actives in deck", ylabel=ef_col,
                 title="EF vs ceiling (grey)" + (f", {n_zero} zeros hidden" if n_zero else ""),
                 abc="C")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results_dir", help="Dir holding enrichment_*.csv")
    ap.add_argument("--ef-col", default="ef1pct_z", help="EF column to plot (default: ef1pct_z)")
    ap.add_argument("--auc-col", default="auc_z")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    d = args.results_dir
    pockets = [r for r in read_csv(os.path.join(d, "enrichment_pockets.csv"))
               if r.get("status") == "ok"]
    targets = [r for r in read_csv(os.path.join(d, "enrichment_targets.csv"))
               if r.get("status") == "ok"]
    controls = merge_controls(read_csv(os.path.join(d, "enrichment_controls.csv")))
    ctrl_p = [r for r in controls if r.get("level") == "pocket"]

    if not pockets:
        print(f"ERROR: no scored rows in {d}/enrichment_pockets.csv")
        return
    print(f"Loaded {len(pockets)} pockets, {len(targets)} targets, {len(ctrl_p)} pocket controls")

    nc = stylia.NamedColors()
    ef_matched = col(pockets, args.ef_col)
    ef_mismatch = col(ctrl_p, f"{args.ef_col}_mismatch")
    ef_shuffle = col(ctrl_p, f"{args.ef_col}_shuffle_mean")

    series = [
        ("matched", ef_matched, nc.plum),
        ("mismatched target", ef_mismatch, nc.orange),
        ("shuffled labels", ef_shuffle, nc.gray),
    ]

    fig, axs = stylia.create_figure(1, 3)
    plot_ecdf(axs.next(), series, args.ef_col)

    auc_t = col(targets, args.auc_col)
    if auc_t.size:
        plot_target_auc(axs.next(), auc_t)
    else:
        stylia.label(axs.next(), xlabel="", ylabel="", title="No target rows", abc="B")

    n_act = col(pockets, "n_act_deck")
    ef_max = col(pockets, args.ef_col.replace("_z", "_max").replace("_cos", "_max"))
    if n_act.size == ef_matched.size:
        plot_ef_vs_actives(axs.next(), n_act, ef_matched, ef_max, args.ef_col)
    else:
        stylia.label(axs.next(), xlabel="", ylabel="", title="Column length mismatch", abc="C")

    out = args.out or os.path.join(d, f"enrichment_{args.ef_col}.png")
    stylia.save_figure(out)
    print(f"Saved {out}")

    for name, v in (("matched", ef_matched), ("mismatched", ef_mismatch), ("shuffled", ef_shuffle)):
        if v.size:
            print(f"  median {args.ef_col} [{name:<11s}] = {np.median(v):.3f}")

    # Paired by screen_dir, never by row order: the control file is keyed independently.
    mism = {r["key"]: r.get(f"{args.ef_col}_mismatch") for r in ctrl_p if "key" in r}
    beat = tot = 0
    for r in pockets:
        a, b = r.get(args.ef_col), mism.get(r.get("screen_dir"))
        if not a or not b:
            continue
        try:
            a, b = float(a), float(b)
        except ValueError:
            continue
        if np.isfinite(a) and np.isfinite(b):
            tot += 1
            beat += int(a > b)
    if tot:
        print(f"  pockets beating their own mismatched control: {beat}/{tot}")


if __name__ == "__main__":
    main()
