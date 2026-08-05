# DrugCLIP score validation

Reproduce the DrugCLIP paper's per-pocket screening scores on our AWS cluster and check
that we get the same **ranking** (ideally similar scores) for the 66 human targets whose
pockets we already encoded.

Ground truth = the paper's `screen_results/<screen_dir>/leader.csv`
(`screen_dir = AF-<uniprot>-F1-model_v4_<domain>_<pocket>`, columns `smiles,Name,oid,score`).
`score` is the DrugCLIP adjusted-robust-z, already max-pooled over the pocket's
conformations, thresholded `≥ 4`, sorted descending — top hits only.

## The scoring recipe (from `Drug-The-Whole-Genome/unimol/tasks/drugclip.py:1786-1802`)

Pocket conformation embeddings `P (n_conf, 6, 128)` and molecule embeddings `M (n_mol, 6, 128)`
are both **already per-fold L2-normalized**, so a per-fold dot product is the cosine.

1. per-fold cosine, mean over 6 folds: `res = einsum('cfd,nfd->cn', P, M) / 6`
2. adjusted robust z per conformation over a **background** molecule set:
   `med = median(res_bg, axis=1); mad = median(|res_bg-med|, axis=1); z = 0.6745*(res-med)/(mad+1e-6)`
3. max-pool over the pocket's conformations: `score = z.max(axis=0)`

We use the **union of all encoded leader molecules** as the background (median/MAD). This
reproduces the ranking; absolute z-scores run higher than the paper's because our
background is smaller and more active than the 500M library. Primary metric = per-pocket
**Spearman** + top-k overlap, not absolute-score match.

## Files

| File | Where | Role |
|------|-------|------|
| `run-validation.sh` | head node | **master**: prep → encode → dependent score+compare (all on `gpu-queue`) |
| `prepare_validation_mols.py` | head node | pool leader SMILES → chunks + `pockets_index.csv` |
| `score_validation.py` | cluster (dependent job) | apply the recipe → per-pocket `scores.csv` |
| `compare_validation.py` | cluster (dependent job) | Spearman / top-k / frac>4 → `validation_summary.csv` |
| `plot_validation.py` | **laptop** | stylia scatter: x = paper score, y = our score |

The pocket side is **reused unchanged** — `/fsx/input/targets/<ID>/pockets/pocket_reps.pkl`
+ `manifest.csv`. Nothing is re-encoded on the pocket side.

## Workflow

```bash
# 0. one-time, from the laptop: ship the ground truth to the cluster
aws s3 sync /home/marina/Documents/AI2050/Targets/screen_results \
    s3://ai2050-ersilia-cluster/input/validation_leaders/screen_results/

# 1. head node: pilot first (P00519), inspect, then all
bash /shared/scripts/drugclip_scripts/validation/run-validation.sh pilot
#    ...check /fsx/output/validation_leaders/validation_summary.csv, then:
bash /shared/scripts/drugclip_scripts/validation/run-validation.sh all

# 2. laptop: download + plot
aws s3 sync s3://ai2050-ersilia-cluster/output/validation_leaders/validation/ ./validation_out/
STYLIA_ENV=$(for e in $(conda env list | grep -v '#' | grep -v '^base' | awk '{print $1}'); do
    conda run -n $e python -c "import stylia" 2>/dev/null && echo $e && break; done)
conda run -n $STYLIA_ENV python scripts/drugclip_scripts/validation/plot_validation.py ./validation_out/
```

## Outputs
- `/fsx/output/validation_leaders/validation/<screen_dir>/scores.csv` — `oid,smiles,paper_score,our_score,paper_rank,our_rank`
- `/fsx/output/validation_leaders/validation_summary.csv` — per-pocket Spearman/Pearson/top-k/frac>4
- `validation_scatter.png` (local) — paper (x) vs ours (y), coloured by pocket, with trend + Spearman/Pearson

## Notes / gotchas
- Embeddings are **per-fold** unit-norm (each 128 block), fold-major (`M[:, f, :]` ↔ `mol_reps` cols `f*128:(f+1)*128`). Do not renormalize the full 768 vector.
- Conformations are grouped into a pocket via `manifest.csv` (`uniprot,domain,pocket → pocket_key`), not by pkl name.
- The molecule encoder (`run-drugclip-job.sh`) checks weights at `/shared/drugclip-weights/model_weights/6_folds/`, while `submit-drugclip.sh` checks `/shared/drugclip-weights/6_folds/`; `run-validation.sh` preflight requires both to resolve.
- Leader molecules that fail RDKit 3D generation are dropped from the comparison (reported per pocket).
