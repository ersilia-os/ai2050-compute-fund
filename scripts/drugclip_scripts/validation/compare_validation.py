#!/usr/bin/env python3
"""
Aggregate the per-pocket validation results into one summary table.

Reads every <scores-dir>/<screen_dir>/scores.csv produced by score_validation.py and,
per pocket, computes correlations of BOTH our scores vs the paper's:
  - spearman_z / spearman_cos   rank correlation of our_score_z / our_score_cos vs paper_score
  - pearson_cos                 linear correlation of our_score_cos vs paper_score
  - top10_cos / top20_cos       overlap of our (cosine) top-k vs the paper's top-k (by oid)
  - n_common                    molecules scored by both

our_score_cos is background-free (isolates the embeddings); our_score_z is the full
z-scored recipe and depends on the background quality. PRIMARY diagnostic = spearman_cos.

Usage:
    python compare_validation.py \
        --scores-dir /fsx/output/validation_leaders/validation \
        --out        /fsx/output/validation_leaders/validation_summary.csv
"""

import argparse
import csv
import glob
import os

import numpy as np


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


def pearson(a, b):
    if len(a) < 3 or np.std(a) == 0 or np.std(b) == 0:
        return float("nan")
    return float(np.corrcoef(a, b)[0, 1])


def topk_overlap(ids, paper, ours, k):
    k = min(k, len(ids))
    if k == 0:
        return float("nan")
    pt = {ids[i] for i in np.argsort(-np.asarray(paper))[:k]}
    ot = {ids[i] for i in np.argsort(-np.asarray(ours))[:k]}
    return len(pt & ot) / k


def load_scores(path):
    ids, ps, z, cos = [], [], [], []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            ids.append(row["oid"] or row["smiles"])
            ps.append(float(row["paper_score"]))
            z.append(float(row["our_score_z"]))
            cos.append(float(row["our_score_cos"]))
    return ids, np.array(ps), np.array(z), np.array(cos)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scores-dir", default="/fsx/output/validation_leaders/validation")
    ap.add_argument("--out", default="/fsx/output/validation_leaders/validation_summary.csv")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.scores_dir, "*", "scores.csv")))
    if not files:
        print(f"ERROR: no scores.csv under {args.scores_dir}")
        return

    rows = []
    for sf in files:
        sd = os.path.basename(os.path.dirname(sf))
        ids, ps, z, cos = load_scores(sf)
        if len(ids) == 0:
            continue
        rows.append({
            "screen_dir": sd,
            "n_common": len(ids),
            "spearman_cos": round(spearman(ps, cos), 4),
            "spearman_z": round(spearman(ps, z), 4),
            "pearson_cos": round(pearson(ps, cos), 4),
            "top10_cos": round(topk_overlap(ids, ps, cos, 10), 4),
            "top20_cos": round(topk_overlap(ids, ps, cos, 20), 4),
        })

    rows.sort(key=lambda r: (r["spearman_cos"] if r["spearman_cos"] == r["spearman_cos"] else -9),
              reverse=True)

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    def med(key):
        v = np.array([r[key] for r in rows], dtype=float)
        v = v[~np.isnan(v)]
        return (np.median(v), np.mean(v), int(np.sum(v > 0.5)), len(v)) if len(v) else (float("nan"),) * 4

    m_cos = med("spearman_cos")
    m_z = med("spearman_z")
    t10 = np.nanmedian([r["top10_cos"] for r in rows])

    print("==========================================")
    print("Validation summary")
    print("==========================================")
    print(f"Pockets compared        : {len(rows)}")
    print(f"Spearman[cos] median    : {m_cos[0]:.3f}  mean {m_cos[1]:.3f}  (>0.5: {m_cos[2]}/{m_cos[3]})")
    print(f"Spearman[z]   median    : {m_z[0]:.3f}  mean {m_z[1]:.3f}  (>0.5: {m_z[2]}/{m_z[3]})")
    print(f"Top-10[cos] overlap med : {t10:.3f}")
    print(f"Summary CSV             : {args.out}")
    print("==========================================")


if __name__ == "__main__":
    main()
