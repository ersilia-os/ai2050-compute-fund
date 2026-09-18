#!/usr/bin/env python3
"""
Enrichment analysis of the DrugCLIP pocket embeddings against the paper's leader lists.

WHY THIS AND NOT THE ABSOLUTE SCORE
-----------------------------------
The paper's `leader.csv` score is an adjusted robust z computed against a ~500M molecule
library; ours can only use the ~36k molecules we have. Location and scale therefore differ
by construction and are not reproducible.

But the background enters the recipe ONLY as a per-conformation, strictly increasing affine
map:

    z_c(n) = a_c * res_c(n) + b_c ,   a_c = 0.6745 / (mad_c + 1e-6) > 0

and every rank-based metric (EF, ROC-AUC, BEDROC, Spearman) is invariant under it. So for a
single-conformation pocket the background choice is EXACTLY irrelevant, and for a
multi-conformation pocket it matters only through which conformation wins the max-pool.
Enrichment is therefore reproducible where the absolute z is not. (The n_conf == 1 rows are
used as a built-in assertion of this: their z and cos metrics must agree to 1e-12.)

THE BENCHMARK
-------------
One screening deck = the union of every `leader.csv` SMILES (~35,952 molecules), encoded
once. For every pocket the whole deck is scored, and molecule m is labelled ACTIVE for
pocket p iff m is in p's leader.csv; it stays a decoy for every other pocket. Reported at
two levels: per pocket (primary) and per target (actives = union over the target's pockets,
score = max over all its conformations).

CONTROLS
--------
The deck is not a neutral decoy set: every molecule in it is somebody's top hit, and
thousands are listed by more than one target. So "EF >> 1" proves nothing on its own. The
load-bearing comparison is MATCHED vs MISMATCHED — the same label vector scored by a
different target's pocket, which holds the number of actives (and hence the EF ceiling)
fixed. A label-shuffle null is also emitted, which gives the empirical null for every metric
at the actual prevalence (note BEDROC's null is ~1/alpha, NOT 0).

Usually launched by run-validation.sh (`all` or `enrich` scope).
"""

import argparse
import csv
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score_validation import (  # noqa: E402
    _load_pairs,
    load_pocket_groups,
    load_pocket_reps,
)

csv.field_size_limit(10 * 1024 * 1024)

Z_CONST = 0.6745


# ── metric naming ──────────────────────────────────────────────────────────────

def ef_name(chi):
    """0.01 -> 'ef1pct', 0.005 -> 'ef0p5pct'."""
    return f"ef{100 * chi:g}pct".replace(".", "p")


def alpha_name(alpha):
    """20 -> 'a20', 80.5 -> 'a80p5'."""
    return f"a{alpha:g}".replace(".", "p")


# ── ranking + metrics (self-contained: rdkit is not available to /shared/python39) ──

class Ranking:
    """A fixed descending ranking of one score vector, reusable across label vectors.

    Precomputes the sort order, the tie-aware 1-based mid-ranks and the sorted scores, so
    the shuffle control can recompute every metric without re-sorting.
    """

    __slots__ = ("s", "n", "order", "s_sorted", "ranks", "n_unique")

    def __init__(self, s):
        self.s = np.asarray(s, dtype=np.float64)
        self.n = self.s.size
        self.order = np.argsort(-self.s, kind="stable")
        self.s_sorted = self.s[self.order]
        new = np.empty(self.n, dtype=bool)
        new[0] = True
        np.not_equal(self.s_sorted[1:], self.s_sorted[:-1], out=new[1:])
        grp = np.cumsum(new) - 1
        starts = np.flatnonzero(new)
        ends = np.r_[starts[1:], self.n] - 1
        mid = (starts + ends) / 2.0 + 1.0          # mean rank within each tie group
        self.ranks = np.empty(self.n, dtype=np.float64)
        self.ranks[self.order] = mid[grp]
        self.n_unique = int(new.sum())


def roc_auc(rk, y):
    """Mann-Whitney U on ascending mid-ranks (matches sklearn, ties included)."""
    na = int(y.sum())
    nd = rk.n - na
    if na == 0 or nd == 0:
        return float("nan")
    asc = (rk.n + 1.0) - rk.ranks
    return float((asc[y == 1].sum() - na * (na + 1) / 2.0) / (na * nd))


def enrichment(rk, y, chi):
    """(ef, ef_max) at top fraction chi.

    A tie group straddling the cut gets fractional credit (the expectation over random
    tie orderings), so the answer never depends on deck insertion order.
    """
    na = int(y.sum())
    if na == 0:
        return float("nan"), float("nan")
    n = rk.n
    k = max(1, int(math.ceil(chi * n)))
    ys = y[rk.order]
    hits = float(ys[:k].sum())
    if k < n and rk.s_sorted[k] == rk.s_sorted[k - 1]:
        neg = -rk.s_sorted
        cut = -rk.s_sorted[k - 1]
        lo = int(np.searchsorted(neg, cut, side="left"))
        hi = int(np.searchsorted(neg, cut, side="right"))
        hits = float(ys[:lo].sum()) + (k - lo) * float(ys[lo:hi].mean())
    prevalence = na / n
    ef = (hits / k) / prevalence
    ef_max = (min(na, k) / k) / prevalence
    return float(ef), float(ef_max)


def bedroc(rk, y, alpha):
    """Truchon & Bayly (2007) eq. 36. NOTE the null is ~1/alpha, not 0."""
    na = int(y.sum())
    n = rk.n
    if na == 0 or na == n:
        return float("nan")
    ra = na / n
    r = rk.ranks[y == 1]
    num = float(np.exp(-alpha * r / n).mean())
    den = (1.0 / n) * (1.0 - math.exp(-alpha)) / math.expm1(alpha / n)
    rie = num / den
    f1 = ra * math.sinh(alpha / 2.0) / (math.cosh(alpha / 2.0) - math.cosh(alpha / 2.0 - alpha * ra))
    f2 = 1.0 / (1.0 - math.exp(alpha * (1.0 - ra)))
    return float(rie * f1 + f2)


def metric_block(rk, y, fracs, alphas, suffix, include_max=False):
    """Flat {column: value} dict of EF/AUC/BEDROC. `suffix` is 'z' or 'cos'."""
    out = {}
    for chi in fracs:
        ef, ef_max = enrichment(rk, y, chi)
        name = ef_name(chi)
        out[f"{name}_{suffix}"] = ef
        if include_max:
            out[f"{name}_max"] = ef_max
            out[f"{name}_norm_{suffix}"] = (ef / ef_max) if ef_max else float("nan")
    out[f"auc_{suffix}"] = roc_auc(rk, y)
    for a in alphas:
        out[f"bedroc_{alpha_name(a)}_{suffix}"] = bedroc(rk, y, a)
    return out


def spearman(a, b):
    """Rank correlation, tie-aware, used only for the paper-score agreement column."""
    a = np.asarray(a, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    ok = np.isfinite(a) & np.isfinite(b)
    a, b = a[ok], b[ok]
    if a.size < 3:
        return float("nan")
    ra, rb = Ranking(a).ranks, Ranking(b).ranks
    if np.std(ra) == 0 or np.std(rb) == 0:
        return float("nan")
    return float(np.corrcoef(ra, rb)[0, 1])


# ── deck + scoring ─────────────────────────────────────────────────────────────

def load_ordered(emb_dir, library, input_dir):
    """-> (smiles in h5 row order, M (N,6,128) float32). Row order is already corrected
    for the encoder's lexicographic sort by _load_pairs."""
    smiles, embs = _load_pairs(emb_dir, library, input_dir)
    if not embs:
        print(f"ERROR: no usable embeddings in {emb_dir} for library '{library}'")
        sys.exit(1)
    M = np.concatenate(embs, axis=0).astype(np.float32)
    return smiles, M.reshape(M.shape[0], 6, 128)


def build_deck(emb_dir, library, input_dir=None,
               decoy_emb_dir=None, decoy_library=None, decoy_input_dir=None):
    """-> (smi2idx, Mf (6,128,N) float32 contiguous, deck_smiles, n_leaders, n_dropped).

    Leaders come first, decoys (if any) are appended. Only leader.csv SMILES are ever looked
    up when building label vectors, so a decoy can never be labelled active — except for a
    decoy whose SMILES string-equals a leader's, which would otherwise sit in the deck as an
    unlabelled duplicate of a true active (a false decoy by construction). Those are dropped
    here and counted; they should also be removed at staging.
    """
    deck_smiles, M = load_ordered(emb_dir, library, input_dir)
    n_leaders = M.shape[0]
    n_dropped = 0

    if decoy_emb_dir:
        dsmiles, dM = load_ordered(decoy_emb_dir, decoy_library, decoy_input_dir)
        leader_set = set(deck_smiles)
        keep = [i for i, s in enumerate(dsmiles) if s and s not in leader_set]
        n_dropped = len(dsmiles) - len(keep)
        M = np.concatenate([M, dM[keep]], axis=0)
        deck_smiles = deck_smiles + [dsmiles[i] for i in keep]
        del dM

    smi2idx = {}
    for i, s in enumerate(deck_smiles):
        smi2idx.setdefault(s, i)

    Mf = np.ascontiguousarray(M.transpose(1, 2, 0))       # (6,128,N)
    del M
    return smi2idx, Mf, deck_smiles, n_leaders, n_dropped


def conformation_scores(P, Mf):
    """P (c,6,128) x Mf (6,128,N) -> (c,N) float32 mean per-fold cosine.

    Numerically the same as einsum('cfd,nfd->cn', P, M)/6, but as 6 BLAS GEMMs: much
    faster and it allocates no temporaries. Both operands are already per-fold unit-norm,
    so the per-fold dot product IS the cosine — do not renormalize.
    """
    out = np.zeros((P.shape[0], Mf.shape[2]), dtype=np.float32)
    for f in range(6):
        out += P[:, f, :] @ Mf[f]
    out /= 6.0
    return out


def robust_z(S):
    """(c,N) -> ((c,N), mad_min). Median/MAD per conformation over the whole deck."""
    med = np.median(S, axis=1, keepdims=True)
    mad = np.median(np.abs(S - med), axis=1, keepdims=True)
    return Z_CONST * (S - med) / (mad + 1e-6), float(mad.min())


def ordered_unique_keys(groups, sds, name2idx):
    """The target's screened conformations, de-duplicated, in a stable order."""
    keys, seen = [], set()
    for sd in sds:
        for k in groups[sd]["keys"]:
            if k in name2idx and k not in seen:
                seen.add(k)
                keys.append(k)
    return keys


def centering_offsets(unis, by_target, groups, targets_base, pkl_cache, Mf):
    """Per-molecule mean score across targets — the hubness correction.

    DrugCLIP's molecule embedding space is hubbed: a subset of molecules sits close to ALL
    pocket vectors and monopolises the top of every pocket's ranking, which is why EF@1% can
    land below its null while AUC sits above 0.5. Subtracting each molecule's mean score over
    the targets removes exactly that molecule-intrinsic term, so a molecule only gets credit
    for scoring well against THIS pocket relative to how it scores everywhere.

    Costs one extra pass of the same GEMMs (memory-flat — we keep two (N,) accumulators, not
    every pocket's score vector, which matters once decoys push the deck past a million).
    """
    n = Mf.shape[2]
    sum_z = np.zeros(n, dtype=np.float64)
    sum_c = np.zeros(n, dtype=np.float64)
    n_seen = 0
    for uni in unis:
        entry = load_pocket_reps(targets_base, uni, pkl_cache)
        if entry is None:
            continue
        _names, name2idx, reps = entry
        keys_t = ordered_unique_keys(groups, sorted(by_target[uni]), name2idx)
        if not keys_t:
            continue
        S_t = conformation_scores(reps[[name2idx[k] for k in keys_t]], Mf)
        Z_t, _ = robust_z(S_t)
        sum_z += Z_t.max(axis=0)
        sum_c += S_t.max(axis=0)
        n_seen += 1
        del S_t, Z_t
    if n_seen == 0:
        return None, None
    return sum_z / n_seen, sum_c / n_seen


def load_labels(group, smi2idx):
    """leader.csv -> (active deck indices, paper scores aligned to them, n_listed)."""
    idxs, scores = [], []
    n_listed = 0
    with open(group["leader_csv"], newline="") as f:
        for row in csv.DictReader(f):
            smi = (row.get("smiles") or "").strip()
            if not smi:
                continue
            n_listed += 1
            j = smi2idx.get(smi)
            if j is None:
                continue                       # failed RDKit 3D embedding: not in the deck at all
            try:
                ps = float(row["score"])
            except (KeyError, ValueError):
                ps = float("nan")
            idxs.append(j)
            scores.append(ps)
    return np.asarray(idxs, dtype=np.int64), np.asarray(scores, dtype=np.float64), n_listed


def labels_to_vector(act_idx, n):
    y = np.zeros(n, dtype=np.uint8)
    y[act_idx] = 1
    return y


# ── output helpers ─────────────────────────────────────────────────────────────

def fmt(v):
    if v is None:
        return ""
    if isinstance(v, float):
        return "" if math.isnan(v) else f"{v:.6g}"
    return str(v)


def write_rows(path, rows, fieldnames):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(fieldnames)
        for r in rows:
            w.writerow([fmt(r.get(k)) for k in fieldnames])


def summarize(rows, metrics):
    """-> {metric: (n, median, mean, q25, q75)} over finite values."""
    out = {}
    for m in metrics:
        v = np.asarray([r[m] for r in rows if m in r and r[m] is not None], dtype=np.float64)
        v = v[np.isfinite(v)]
        if v.size == 0:
            out[m] = (0, float("nan"), float("nan"), float("nan"), float("nan"))
        else:
            out[m] = (int(v.size), float(np.median(v)), float(v.mean()),
                      float(np.percentile(v, 25)), float(np.percentile(v, 75)))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pockets-index", default="/fsx/input/validation_leaders/pockets_index.csv")
    ap.add_argument("--targets-base", default="/fsx/input/targets")
    ap.add_argument("--emb-dir", default="/fsx/output/validation_leaders/drugclip")
    ap.add_argument("--library", default="validation_leaders")
    ap.add_argument("--input-dir", default="/fsx/input/validation_leaders",
                    help="Holds <library>_chunk_NNN.csv — needed to undo the encoder's "
                         "lexicographic row order.")
    ap.add_argument("--decoy-emb-dir", default=None,
                    help="Embeddings of a decoy library to append to the deck (e.g. ChEMBL). "
                         "Decoys are never labelled active. Without this the decoys are the "
                         "other targets' leaders, which is an adversarial deck.")
    ap.add_argument("--decoy-library", default=None)
    ap.add_argument("--decoy-input-dir", default=None,
                    help="Holds the decoy library's <library>_chunk_NNN.csv (row-order remap).")
    ap.add_argument("--out-dir", default="/fsx/output/validation_leaders/enrichment")
    ap.add_argument("--ef-fractions", default="0.01,0.05,0.10")
    ap.add_argument("--bedroc-alphas", default="20,80.5",
                    help="alpha=20 is the reported one; 80.5 matches upstream cal_metrics().")
    ap.add_argument("--center-molecules", action="store_true",
                    help="Subtract each molecule's mean score across targets before ranking, to "
                         "cancel embedding hubness (see centering_offsets). Costs one extra "
                         "scoring pass. Run with VAL_TAG set to keep both result sets.")
    ap.add_argument("--n-shuffles", type=int, default=5)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--min-actives", type=int, default=5)
    ap.add_argument("--min-targets", type=int, default=10,
                    help="Abort if the index covers fewer targets (guards against a pilot deck).")
    ap.add_argument("--allow-partial-deck", action="store_true")
    ap.add_argument("--no-controls", action="store_true")
    ap.add_argument("--dump-npz", action="store_true",
                    help="Write per-target full-deck z vectors for offline re-analysis.")
    args = ap.parse_args()

    fracs = [float(x) for x in args.ef_fractions.split(",") if x.strip()]
    alphas = [float(x) for x in args.bedroc_alphas.split(",") if x.strip()]
    os.makedirs(args.out_dir, exist_ok=True)

    groups = load_pocket_groups(args.pockets_index)
    by_target = {}
    for sd, g in groups.items():
        by_target.setdefault(g["uniprot"], []).append(sd)
    unis = sorted(by_target)

    print("==========================================")
    print("DrugCLIP enrichment analysis")
    print("==========================================")
    print(f"Pockets index : {args.pockets_index}")
    print(f"  {len(groups)} pockets across {len(unis)} targets")

    if len(unis) < args.min_targets and not args.allow_partial_deck:
        print(f"ERROR: only {len(unis)} targets in the index (need >= {args.min_targets}).")
        print("  Enrichment needs the FULL deck — a pilot deck makes the decoy set meaningless.")
        print("  Re-run the pipeline with scope=all, or pass --allow-partial-deck if you")
        print("  really know what you are doing.")
        sys.exit(1)

    print("Loading deck embeddings ...")
    smi2idx, Mf, deck_smiles, n_leaders, n_dropped = build_deck(
        args.emb_dir, args.library, args.input_dir,
        args.decoy_emb_dir, args.decoy_library, args.decoy_input_dir)
    n_deck = Mf.shape[2]
    print(f"  deck: {n_deck} molecules ({Mf.nbytes / 1e6:.0f} MB)")
    if args.decoy_emb_dir:
        print(f"    {n_leaders} leaders + {n_deck - n_leaders} decoys from "
              f"'{args.decoy_library}'")
        if n_dropped:
            print(f"    {n_dropped} decoys dropped: SMILES identical to a leader "
                  "(they would be false decoys)")
    if len(smi2idx) != n_deck:
        print(f"  WARN {n_deck - len(smi2idx)} duplicate SMILES rows in the deck — "
              "these can never be labelled active and act as permanent decoys")

    # Labels per pocket, and their union per target.
    pocket_labels, target_labels, n_listed_total = {}, {}, 0
    for sd, g in groups.items():
        act_idx, paper, n_listed = load_labels(g, smi2idx)
        pocket_labels[sd] = (act_idx, paper, n_listed)
        n_listed_total += n_listed
        target_labels.setdefault(g["uniprot"], []).append(act_idx)
    target_act = {u: np.unique(np.concatenate(v)) if v else np.asarray([], dtype=np.int64)
                  for u, v in target_labels.items()}

    n_act_deck_total = sum(len(pocket_labels[sd][0]) for sd in groups)
    attrition = 1.0 - (n_act_deck_total / n_listed_total) if n_listed_total else 0.0
    print(f"  leader listings: {n_listed_total}, matched into the deck: {n_act_deck_total} "
          f"(attrition {100 * attrition:.2f}%)")
    if attrition > 0.02:
        print("  WARN attrition > 2% — check RDKit 3D embedding failures in the encode logs")

    # How many targets list each deck molecule (for the hubness diagnostic).
    n_targets_listing = np.zeros(n_deck, dtype=np.int32)
    for u in unis:
        n_targets_listing[target_act[u]] += 1

    rng = np.random.default_rng(args.seed)
    pkl_cache = {}

    off_z = off_c = None
    if args.center_molecules:
        print("")
        print("Pre-pass: per-molecule centering offsets (hubness correction) ...")
        off_z, off_c = centering_offsets(unis, by_target, groups, args.targets_base, pkl_cache, Mf)
        if off_z is None:
            print("  ERROR: no target could be scored — cannot compute offsets")
            sys.exit(1)
        print(f"  offset z: mean {off_z.mean():.3f}, sd {off_z.std():.3f}, "
              f"range [{off_z.min():.3f}, {off_z.max():.3f}]")
        print("  (a wide spread means strong hubness — that spread is what centering removes)")

    pocket_rows, target_rows, control_rows = [], [], []
    target_scores_z = {}                       # uniprot -> float32 (N,) for the mismatch control
    pocket_meta = {}                           # screen_dir -> (uniprot, act_idx)
    z_running_sum = np.zeros(n_deck, dtype=np.float64)
    n_pocket_scored = 0
    n_single_conf = n_single_conf_ok = 0

    print("")
    print("Scoring (one pass per target; every conformation scored once) ...")
    for uni in unis:
        sds = sorted(by_target[uni])
        entry = load_pocket_reps(args.targets_base, uni, pkl_cache)
        if entry is None:
            print(f"  SKIP {uni}: no pocket_reps.pkl")
            for sd in sds:
                pocket_rows.append({"screen_dir": sd, "uniprot": uni, "status": "skip_no_pkl"})
            target_rows.append({"uniprot": uni, "n_pockets": len(sds), "status": "skip_no_pkl"})
            continue
        _names, name2idx, reps = entry

        # Ordered-unique union of this target's screened conformations.
        keys_t = ordered_unique_keys(groups, sds, name2idx)
        if not keys_t:
            print(f"  SKIP {uni}: no conformation embeddings resolved")
            for sd in sds:
                pocket_rows.append({"screen_dir": sd, "uniprot": uni, "status": "skip_no_conf"})
            target_rows.append({"uniprot": uni, "n_pockets": len(sds), "status": "skip_no_conf"})
            continue
        row_of_key = {k: i for i, k in enumerate(keys_t)}

        P_t = reps[[name2idx[k] for k in keys_t]]            # (c_t, 6, 128)
        S_t = conformation_scores(P_t, Mf)                   # (c_t, N) float32
        if not np.all(np.isfinite(S_t)):
            print(f"  WARN {uni}: non-finite cosines in the score matrix")
        Z_t, mad_min = robust_z(S_t)

        # ── per pocket ────────────────────────────────────────────────────────
        for sd in sds:
            g = groups[sd]
            rows = [row_of_key[k] for k in g["keys"] if k in row_of_key]
            act_idx, paper, n_listed = pocket_labels[sd]
            base = {
                "screen_dir": sd, "uniprot": uni, "domain": g["domain"], "pocket": g["pocket"],
                "n_conf": len(rows), "n_deck": n_deck,
                "n_act_listed": n_listed, "n_act_deck": len(act_idx),
                "mad_min": mad_min,
            }
            if not rows:
                pocket_rows.append({**base, "status": "skip_no_conf"})
                continue
            if len(act_idx) < args.min_actives:
                pocket_rows.append({**base, "status": "skip_few_actives"})
                continue

            # float64 before ranking: float32 over a narrow cosine range can tie spuriously
            s_z = Z_t[rows].max(axis=0).astype(np.float64)
            s_c = S_t[rows].max(axis=0).astype(np.float64)
            if off_z is not None:
                s_z = s_z - off_z
                s_c = s_c - off_c
            rk_z, rk_c = Ranking(s_z), Ranking(s_c)
            y = labels_to_vector(act_idx, n_deck)

            row = {
                **base,
                "active_frac": len(act_idx) / n_deck,
                "n_unique_scores": rk_z.n_unique,
                **metric_block(rk_z, y, fracs, alphas, "z", include_max=True),
                **metric_block(rk_c, y, fracs, alphas, "cos"),
                "spearman_paper_z": spearman(paper, s_z[act_idx]),
                "spearman_paper_cos": spearman(paper, s_c[act_idx]),
                "status": "ok",
            }
            pocket_rows.append(row)
            pocket_meta[sd] = (uni, act_idx)
            n_pocket_scored += 1

            # Built-in assertion: with one conformation the max-pool is a no-op, so the
            # affine z cannot change any ranking.
            if len(rows) == 1:
                n_single_conf += 1
                same = all(
                    _close(row.get(f"{m}_z"), row.get(f"{m}_cos"))
                    for m in [ef_name(c) for c in fracs] + ["auc"] + [f"bedroc_{alpha_name(a)}" for a in alphas]
                )
                n_single_conf_ok += int(same)
                if not same:
                    print(f"  FAIL {sd}: n_conf==1 but z and cos metrics differ — "
                          "the max-pool or the labelling is wrong")

            if not args.no_controls and args.n_shuffles > 0:
                control_rows.append(_shuffle_control("pocket", sd, rk_z, y, fracs, alphas,
                                                     args.n_shuffles, rng))

        # ── target level ──────────────────────────────────────────────────────
        act_t = target_act[uni]
        s_zT = Z_t.max(axis=0).astype(np.float64)
        s_cT = S_t.max(axis=0).astype(np.float64)
        z_running_sum += s_zT          # uncentered, so the hubness diagnostic stays comparable
        if off_z is not None:
            s_zT = s_zT - off_z
            s_cT = s_cT - off_c
        target_scores_z[uni] = s_zT.astype(np.float32)
        base_t = {
            "uniprot": uni, "n_pockets": len(sds), "n_conf": len(keys_t), "n_deck": n_deck,
            "n_act_deck": len(act_t), "active_frac": len(act_t) / n_deck, "mad_min": mad_min,
        }
        if len(act_t) < args.min_actives:
            target_rows.append({**base_t, "status": "skip_few_actives"})
        else:
            rk_zT, rk_cT = Ranking(s_zT), Ranking(s_cT)
            yT = labels_to_vector(act_t, n_deck)
            target_rows.append({
                **base_t,
                "n_unique_scores": rk_zT.n_unique,
                **metric_block(rk_zT, yT, fracs, alphas, "z", include_max=True),
                **metric_block(rk_cT, yT, fracs, alphas, "cos"),
                "status": "ok",
            })
            if not args.no_controls and args.n_shuffles > 0:
                control_rows.append(_shuffle_control("target", uni, rk_zT, yT, fracs, alphas,
                                                     args.n_shuffles, rng))
        print(f"  {uni}: {len(sds)} pockets, {len(keys_t)} conformations, "
              f"{len(act_t)} actives in deck")
        del S_t, Z_t

    # ── mismatched-target control ─────────────────────────────────────────────
    # Same label vector, a DIFFERENT target's pocket score. Holding the actives fixed keeps
    # the EF ceiling identical, so this is directly comparable to the matched EF — which the
    # shuffle null is not. This is the comparison that carries the result.
    if not args.no_controls and len(target_scores_z) > 1:
        print("")
        print("Mismatched-target control ...")
        scored = [u for u in unis if u in target_scores_z]
        partner_of = {u: scored[(i + 1) % len(scored)] for i, u in enumerate(scored)}
        rk_cache = {}
        for u in scored:
            p = partner_of[u]
            if p not in rk_cache:
                rk_cache[p] = Ranking(target_scores_z[p].astype(np.float64))
            rk_p = rk_cache[p]
            if len(target_act[u]) >= args.min_actives:
                control_rows.append({
                    "level": "target", "key": u, "partner_key": p,
                    "n_act_deck": len(target_act[u]),
                    **{f"{k}_mismatch": v for k, v in
                       metric_block(rk_p, labels_to_vector(target_act[u], n_deck),
                                    fracs, alphas, "z").items()},
                })
        for sd, (u, act_idx) in pocket_meta.items():
            p = partner_of.get(u)
            if p is None or len(act_idx) < args.min_actives:
                continue
            control_rows.append({
                "level": "pocket", "key": sd, "partner_key": p, "n_act_deck": len(act_idx),
                **{f"{k}_mismatch": v for k, v in
                   metric_block(rk_cache[p], labels_to_vector(act_idx, n_deck),
                                fracs, alphas, "z").items()},
            })

    # ── outputs ───────────────────────────────────────────────────────────────
    metric_cols = (
        [f"{ef_name(c)}_z" for c in fracs] + [f"{ef_name(c)}_max" for c in fracs]
        + [f"{ef_name(c)}_norm_z" for c in fracs] + ["auc_z"]
        + [f"bedroc_{alpha_name(a)}_z" for a in alphas]
        + [f"{ef_name(c)}_cos" for c in fracs] + ["auc_cos"]
        + [f"bedroc_{alpha_name(a)}_cos" for a in alphas]
    )
    pocket_cols = (["screen_dir", "uniprot", "domain", "pocket", "n_conf", "n_deck",
                    "n_act_listed", "n_act_deck", "active_frac", "n_unique_scores"]
                   + metric_cols + ["spearman_paper_z", "spearman_paper_cos", "mad_min", "status"])
    target_cols = (["uniprot", "n_pockets", "n_conf", "n_deck", "n_act_deck", "active_frac",
                    "n_unique_scores"] + metric_cols + ["mad_min", "status"])

    p_pockets = os.path.join(args.out_dir, "enrichment_pockets.csv")
    p_targets = os.path.join(args.out_dir, "enrichment_targets.csv")
    write_rows(p_pockets, pocket_rows, pocket_cols)
    write_rows(p_targets, target_rows, target_cols)

    if control_rows:
        ctrl_cols = ["level", "key", "partner_key", "n_act_deck", "n_shuffles"]
        seen = set(ctrl_cols)
        for r in control_rows:
            for k in r:
                if k not in seen:
                    seen.add(k)
                    ctrl_cols.append(k)
        write_rows(os.path.join(args.out_dir, "enrichment_controls.csv"), control_rows, ctrl_cols)

    # Long-format summary. `pocket_by_target` is the headline: the 339 pockets are not
    # independent (1-11 per target), so a plain median over them over-weights the
    # heavily-pocketed targets.
    ok_p = [r for r in pocket_rows if r.get("status") == "ok"]
    ok_t = [r for r in target_rows if r.get("status") == "ok"]
    head = [ef_name(c) + "_z" for c in fracs] + ["auc_z"] + [f"bedroc_{alpha_name(a)}_z" for a in alphas]

    by_t = {}
    for r in ok_p:
        by_t.setdefault(r["uniprot"], []).append(r)
    pocket_by_target = [
        {"uniprot": u, **{m: float(np.median([x[m] for x in rs if np.isfinite(x.get(m, np.nan))]))
                          if any(np.isfinite(x.get(m, np.nan)) for x in rs) else float("nan")
                          for m in head}}
        for u, rs in by_t.items()
    ]

    null_med = {}
    for m in head:
        v = [r[f"{m}_shuffle_mean"] for r in control_rows
             if r.get("level") == "pocket" and f"{m}_shuffle_mean" in r]
        v = np.asarray(v, dtype=np.float64)
        v = v[np.isfinite(v)]
        null_med[m] = float(np.median(v)) if v.size else float("nan")

    summary_rows = []
    for level, rows in (("pocket", ok_p), ("pocket_by_target", pocket_by_target), ("target", ok_t)):
        stats = summarize(rows, head)
        for m in head:
            n, med, mean, q25, q75 = stats[m]
            nm = null_med.get(m, float("nan"))
            above = sum(1 for r in rows
                        if np.isfinite(r.get(m, np.nan)) and np.isfinite(nm) and r[m] > nm)
            summary_rows.append({
                "level": level, "score": "z", "metric": m, "n": n, "median": med, "mean": mean,
                "q25": q25, "q75": q75, "null_median": nm, "n_above_null": above,
            })
    write_rows(os.path.join(args.out_dir, "enrichment_summary.csv"), summary_rows,
               ["level", "score", "metric", "n", "median", "mean", "q25", "q75",
                "null_median", "n_above_null"])

    if args.dump_npz and target_scores_z:
        np.savez_compressed(os.path.join(args.out_dir, "target_scores.npz"), **target_scores_z)
        with open(os.path.join(args.out_dir, "deck_smiles.txt"), "w", encoding="utf-8") as f:
            f.write("\n".join(deck_smiles) + "\n")

    # Hubness: how much of the signal is just "molecules DrugCLIP likes in general".
    hub = spearman(z_running_sum / max(1, len(target_scores_z)), n_targets_listing.astype(float))

    print("")
    print("==========================================")
    print(f"Scored {n_pocket_scored}/{len(groups)} pockets, {len(ok_t)}/{len(unis)} targets")
    if n_single_conf:
        print(f"n_conf==1 assertion: {n_single_conf_ok}/{n_single_conf} rows have identical "
              "z and cos metrics (expected: all)")
    print(f"Hubness (mean z vs #targets listing a molecule): Spearman={hub:.3f}")
    print("")
    for r in summary_rows:
        print(f"  {r['level']:<17s} {r['metric']:<16s} n={r['n']:<4d} "
              f"median={r['median']:.3f}  null={r['null_median']:.3f}  "
              f"above_null={r['n_above_null']}")
    print("")
    print("Random expectation: EF=1, AUC=0.5, BEDROC~1/alpha (NOT 0).")
    print("The claim is matched >> mismatched in enrichment_controls.csv, not EF > 1:")
    print("every molecule in the deck is somebody's top hit.")
    print(f"→ {p_pockets}")
    print(f"→ {p_targets}")
    print("==========================================")


def _close(a, b, tol=1e-12):
    if a is None or b is None:
        return True
    if isinstance(a, float) and math.isnan(a) and isinstance(b, float) and math.isnan(b):
        return True
    return abs(float(a) - float(b)) <= tol * max(1.0, abs(float(a)), abs(float(b)))


def _shuffle_control(level, key, rk, y, fracs, alphas, n_shuffles, rng):
    """Empirical null: permute the labels, keep the ranking. Gives the true null for every
    metric at this row's actual prevalence (BEDROC's is ~1/alpha, not 0)."""
    acc = {}
    for _ in range(n_shuffles):
        yp = rng.permutation(y)
        for k, v in metric_block(rk, yp, fracs, alphas, "z").items():
            acc.setdefault(k, []).append(v)
    row = {"level": level, "key": key, "n_act_deck": int(y.sum()), "n_shuffles": n_shuffles}
    for k, v in acc.items():
        a = np.asarray(v, dtype=np.float64)
        a = a[np.isfinite(a)]
        row[f"{k}_shuffle_mean"] = float(a.mean()) if a.size else float("nan")
        row[f"{k}_shuffle_sd"] = float(a.std(ddof=0)) if a.size else float("nan")
    return row


if __name__ == "__main__":
    main()
