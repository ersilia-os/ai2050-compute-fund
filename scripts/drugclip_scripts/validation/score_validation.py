#!/usr/bin/env python3
"""
Reproduce the DrugCLIP screening score for each validated pocket and compare to the
paper's leader.csv.

Implements the recipe from Drug-The-Whole-Genome/unimol/tasks/drugclip.py
(retrieval_multi_folds, lines 1786-1802):

  1. per-fold cosine, mean over 6 folds:   res = einsum('cfd,nfd->cn', P, M) / 6
  2. adjusted robust z per conformation over a BACKGROUND molecule set:
        med = median(res_bg, axis=1); mad = median(|res_bg - med|, axis=1)
        z   = 0.6745 * (res - med) / (mad + 1e-6)
  3. max-pool over the pocket's conformations:  score = z.max(axis=0)

We emit TWO scores per molecule:
  - our_score_z    : the full z-scored recipe above (needs a good background).
  - our_score_cos  : background-FREE max-pool of the mean-fold cosine — a diagnostic that
                     isolates the embeddings from the background/normalization choice.

Background (for the z-score) defaults to the union of encoded leader molecules
(--emb-dir). For a faithful z (matching the paper's ~500M library), pass
--background-emb-dir pointing at a random decoy library's embeddings (+ --background-sample).

Embeddings (pocket_reps.pkl, mol_reps.h5) are already per-fold L2-normalized, so a
per-fold dot product is the cosine; do NOT renormalize.

Per pocket, writes <out_dir>/<screen_dir>/scores.csv:
    oid, smiles, paper_score, our_score_z, our_score_cos, paper_rank, our_rank_z, our_rank_cos

Usually launched by run-validation.sh as a dependent job.
"""

import argparse
import csv
import glob
import os
import pickle
import sys

import h5py
import numpy as np


SMILES_COLS = ("smiles", "canonical_smiles", "input")


def _loader_row_order(input_csv, smis):
    """Reorder `smis` (input order) into the order the encoder actually wrote h5 rows.

    unimol's load_mols_dataset_dtwg (Drug-The-Whole-Genome/unimol/tasks/drugclip.py:498)
    does `sorted(list(set(keys)))` on the LMDB "success" keys, which are STRINGS. So the
    dataset is ordered LEXICOGRAPHICALLY — "0", "1", "10", "100", "1000", ... — while
    <chunk>.smiles.txt is written in input order. mol_reps row r therefore holds the
    molecule at lexicographic position r, not input position r.

    The keys are written as `str(n_ok)` (smiles_to_lmdb.py:155), a counter over SUCCESSFUL
    molecules — not the input row index. Key i therefore belongs to line i of .smiles.txt,
    and the permutation is fixed by the number of successes alone.

    `input_csv` is accepted for call-site compatibility and deliberately unused. Deriving the
    keys from input row indices is wrong for any chunk where RDKit dropped a molecule: the
    missing index leaves a hole that shifts every lexicographic position after it. On a
    2,000-row chunk a single failure at input 1500 mispairs 102 rows; one at input 5 mispairs
    1997 of 1999.
    """
    order = sorted(range(len(smis)), key=str)
    return [smis[o] for o in order]


def _load_pairs(emb_dir, library=None, input_dir=None):
    """Load (smiles_list, emb (N,768)) from all matching *_drugclip_*.h5 + .smiles.txt.

    Two correctness guards, both of which the raw files fail silently without:
      - rows are re-paired with SMILES in the encoder's lexicographic order (see
        _loader_row_order); `input_dir` must hold the <library>_chunk_NNN.csv inputs.
      - chunks with incomplete folds are dropped. require_dataset() pre-allocates zeros
        and the encode loop fills fold-major, so a job that dies part-way leaves a
        correctly-shaped h5 whose later folds are all zero.
    """
    pat = f"{library}_drugclip_*.h5" if library else "*_drugclip_*.h5"
    h5_files = sorted(glob.glob(os.path.join(emb_dir, pat)))
    if input_dir is None and library:
        input_dir = os.path.join("/fsx/input", library)
    smiles_all, embs_all = [], []
    n_skip_fold = n_skip_order = 0
    for h5f in h5_files:
        base = os.path.basename(h5f)
        smi_txt = h5f[:-3] + ".smiles.txt"
        if not os.path.isfile(smi_txt):
            print(f"  WARN missing smiles index for {base} — skipping")
            continue
        with open(smi_txt, encoding="utf-8") as f:
            smis = [ln.strip() for ln in f if ln.strip()]
        with h5py.File(h5f, "r") as f:
            emb = f["mol_reps"][:]
        if len(smis) != len(emb):
            print(f"  WARN {base}: {len(smis)} smiles vs {len(emb)} rows — skipping")
            continue

        folds = np.linalg.norm(emb.reshape(len(emb), 6, 128), axis=2)
        if len(emb) == 0 or float(folds.min()) < 0.9:
            done = int((folds > 0.9).all(axis=1).sum())
            print(f"  WARN {base}: incomplete folds ({done}/{len(emb)} rows have all 6) — skipping")
            n_skip_fold += 1
            continue

        chunk_num = base[:-3].split("_")[-1]
        stem = library or base.split("_drugclip_")[0]
        ordered = _loader_row_order(os.path.join(input_dir or "", f"{stem}_chunk_{chunk_num}.csv"), smis)
        if ordered is None:
            print(f"  WARN {base}: cannot recover encoder row order from "
                  f"{input_dir}/{stem}_chunk_{chunk_num}.csv — skipping")
            n_skip_order += 1
            continue

        smiles_all.extend(ordered)
        embs_all.append(emb)
    if n_skip_fold or n_skip_order:
        print(f"  {n_skip_fold} chunk(s) skipped for incomplete folds, "
              f"{n_skip_order} for unrecoverable row order")
    return smiles_all, embs_all


def load_leaders(emb_dir, library, input_dir=None):
    """Encoded leader molecules → (smiles->row index, M (N,6,128) float32)."""
    smiles_all, embs_all = _load_pairs(emb_dir, library, input_dir)
    if not embs_all:
        print(f"ERROR: no embedding h5 files in {emb_dir}")
        sys.exit(1)
    M = np.concatenate(embs_all, axis=0).astype(np.float32)
    M = M.reshape(M.shape[0], 6, 128)                      # fold-major → (N, 6, 128)
    smi2idx = {}
    for i, s in enumerate(smiles_all):
        smi2idx.setdefault(s, i)
    return smi2idx, M


def load_background(bg_dir, library, sample, input_dir=None):
    """Background embeddings (N,6,128) for the z-score, optionally random-sampled to `sample`."""
    _, embs_all = _load_pairs(bg_dir, library, input_dir)
    if not embs_all:
        print(f"ERROR: no background embeddings in {bg_dir}")
        sys.exit(1)
    M = np.concatenate(embs_all, axis=0).astype(np.float32).reshape(-1, 6, 128)
    if sample and sample < M.shape[0]:
        rng = np.random.default_rng(0)
        M = M[rng.choice(M.shape[0], size=sample, replace=False)]
    return M


def load_pocket_groups(pockets_index):
    """pockets_index.csv → {screen_dir: {uniprot, domain, pocket, leader_csv, keys[...]}}.

    One CSV row per (pocket x conformation), so `keys` collects the conformations.
    """
    groups = {}
    with open(pockets_index, newline="") as f:
        for row in csv.DictReader(f):
            sd = row["screen_dir"]
            g = groups.setdefault(sd, {
                "uniprot": row["uniprot"], "domain": row["domain"],
                "pocket": row["pocket"], "leader_csv": row["leader_csv"], "keys": [],
            })
            g["keys"].append(row["pocket_key"])
    return groups


def load_pocket_reps(targets_base, uniprot, cache):
    """(names, name2idx, reps (n_conf,6,128) float32) for a target, memoized in `cache`.

    Returns None if the target has no pocket_reps.pkl. `reps` is per-fold unit-norm —
    do NOT renormalize.
    """
    if uniprot not in cache:
        pkl_path = os.path.join(targets_base, uniprot, "pockets", "pocket_reps.pkl")
        if not os.path.isfile(pkl_path):
            cache[uniprot] = None
        else:
            with open(pkl_path, "rb") as f:
                names, reps = pickle.load(f)
            cache[uniprot] = (list(names), {n: i for i, n in enumerate(names)},
                              np.asarray(reps, dtype=np.float32))
    return cache[uniprot]


def rankdata_desc(values):
    v = np.asarray(values, dtype=float)
    order = np.argsort(-v, kind="mergesort")
    ranks = np.empty(len(v), dtype=float)
    sorted_v = v[order]
    i = 0
    while i < len(v):
        j = i
        while j + 1 < len(v) and sorted_v[j + 1] == sorted_v[i]:
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pockets-index", default="/fsx/input/validation_leaders/pockets_index.csv")
    ap.add_argument("--targets-base", default="/fsx/input/targets")
    ap.add_argument("--emb-dir", default="/fsx/output/validation_leaders/drugclip")
    ap.add_argument("--library", default="validation_leaders")
    ap.add_argument("--input-dir", default="/fsx/input/validation_leaders",
                    help="Holds <library>_chunk_NNN.csv — needed to undo the encoder's "
                         "lexicographic row order (see _loader_row_order).")
    ap.add_argument("--out-dir", default="/fsx/output/validation_leaders/validation")
    ap.add_argument("--background-emb-dir", default=None,
                    help="Embeddings dir for the z-score background (default: the leader union).")
    ap.add_argument("--background-library", default=None,
                    help="Library prefix within --background-emb-dir (default: any).")
    ap.add_argument("--background-sample", type=int, default=50000,
                    help="Random-sample this many background molecules (only if a separate bg dir is given).")
    args = ap.parse_args()

    csv.field_size_limit(10 * 1024 * 1024)

    print("Loading leader (scored) molecule embeddings ...")
    smi2idx, M = load_leaders(args.emb_dir, args.library, args.input_dir)
    print(f"  {M.shape[0]} molecules, shape {M.shape}")

    if args.background_emb_dir:
        print(f"Loading z-score background from {args.background_emb_dir} ...")
        M_bg = load_background(args.background_emb_dir, args.background_library,
                               args.background_sample)
        print(f"  background: {M_bg.shape[0]} molecules")
    else:
        M_bg = M
        print(f"  z-score background = leader union ({M_bg.shape[0]} molecules)")

    groups = load_pocket_groups(args.pockets_index)

    os.makedirs(args.out_dir, exist_ok=True)
    pkl_cache = {}
    n_ok = n_skip = 0

    for sd, g in sorted(groups.items()):
        uni = g["uniprot"]
        seen = uni in pkl_cache
        entry = load_pocket_reps(args.targets_base, uni, pkl_cache)
        if entry is None:
            if not seen:
                print(f"  SKIP {sd}: no pocket_reps.pkl for {uni}")
            n_skip += 1
            continue
        names, name2idx, reps = entry

        conf_idx = [name2idx[k] for k in g["keys"] if k in name2idx]
        missing = [k for k in g["keys"] if k not in name2idx]
        if missing:
            print(f"  WARN {sd}: {len(missing)}/{len(g['keys'])} pocket_keys not in pkl")
        if not conf_idx:
            print(f"  SKIP {sd}: no conformation embeddings resolved")
            n_skip += 1
            continue
        P = reps[conf_idx]                                            # (n_conf, 6, 128)

        # Background per-conformation stats (mean-fold cosine over the background set)
        res_bg = np.einsum("cfd,nfd->cn", P, M_bg, optimize=True) / 6.0
        med = np.median(res_bg, axis=1, keepdims=True)
        mad = np.median(np.abs(res_bg - med), axis=1, keepdims=True)

        leaders = []
        with open(g["leader_csv"], newline="") as f:
            for row in csv.DictReader(f):
                s = (row.get("smiles") or "").strip()
                if not s:
                    continue
                try:
                    ps = float(row["score"])
                except (KeyError, ValueError):
                    continue
                leaders.append((row.get("oid", ""), s, ps))

        lead_idx, kept = [], []
        for oid, s, ps in leaders:
            j = smi2idx.get(s)
            if j is not None:
                lead_idx.append(j)
                kept.append((oid, s, ps))
        if not kept:
            print(f"  SKIP {sd}: none of {len(leaders)} leader molecules were encoded")
            n_skip += 1
            continue

        Ml = M[lead_idx]                                             # (n_lead, 6, 128)
        res = np.einsum("cfd,nfd->cn", P, Ml, optimize=True) / 6.0   # mean-fold cosine
        z = 0.6745 * (res - med) / (mad + 1e-6)
        our_z = z.max(axis=0)                                        # z max-pool
        our_cos = res.max(axis=0)                                    # background-free cosine max-pool

        paper_scores = np.array([k[2] for k in kept], dtype=float)
        paper_rank = rankdata_desc(paper_scores)
        rank_z = rankdata_desc(our_z)
        rank_cos = rankdata_desc(our_cos)

        out_sub = os.path.join(args.out_dir, sd)
        os.makedirs(out_sub, exist_ok=True)
        with open(os.path.join(out_sub, "scores.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["oid", "smiles", "paper_score", "our_score_z", "our_score_cos",
                        "paper_rank", "our_rank_z", "our_rank_cos"])
            for (oid, s, ps), zz, cc, pr, rz, rc in zip(kept, our_z, our_cos, paper_rank, rank_z, rank_cos):
                w.writerow([oid, s, f"{ps:.6f}", f"{zz:.6f}", f"{cc:.6f}", int(pr), int(rz), int(rc)])

        rho_z = spearman(paper_scores, our_z)
        rho_cos = spearman(paper_scores, our_cos)
        n_dropped = len(leaders) - len(kept)
        print(f"  {sd}: n_conf={P.shape[0]} n_common={len(kept)}"
              + (f" (dropped {n_dropped})" if n_dropped else "")
              + f"  Spearman[z]={rho_z:.3f}  Spearman[cos]={rho_cos:.3f}")
        n_ok += 1

    print("==========================================")
    print(f"Scored {n_ok} pockets, skipped {n_skip}. → {args.out_dir}")
    print("Spearman[cos] is background-free (isolates the embeddings);")
    print("Spearman[z] needs a good background (--background-emb-dir for the faithful one).")
    print("==========================================")


if __name__ == "__main__":
    main()
