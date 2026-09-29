# DrugCLIP validation — enrichment

Does our DrugCLIP setup retrieve the right molecules for the 66 human targets whose pockets we
encoded? Ground truth is the paper's `screen_results/<screen_dir>/leader.csv`. This README is
the run guide; the results, controls and open work are written up in
[`docs/05_drugclip_validation.md`](../../../docs/05_drugclip_validation.md).

## Pocket sets on `/fsx/input/`

Five `targets*` directories exist and they are easy to confuse:

| dir | definition | atoms/lig | conf | targets | encoded | use |
|---|---|---|---|---|---|---|
| `targets` | 1-atom probe at grid centre | 1 | 2,264 | 66 | yes | production baseline; no signal |
| `targets_best` | best available per conformation | mixed | 2,264 | 66 | yes | broadest coverage, but 184/339 pockets are dead weight — **not** the headline |
| `targets_ligand` | true PDBbind ligand, 6 Å | 29 | 573 | 57 | yes | **use this** — template route only, 0 genpack |
| `targets_fpocket` | fpocket cavity pseudo-ligand | 88 | 570 | 12 | yes | tested, no benefit |
| `targets_a511` | same geometry as `targets`, re-encoded at `--max-pocket-atoms 511` | 1 | 2,264 | 66 | yes | crop control; crop never bound |
| `targets_probe` | grown probe | 33 | 377 | 10 | 6 only | partial/abandoned |

`targets_best/pocket_source.csv` records which set each conformation came from — needed by
`plot_auc_overview.py` to colour pockets by definition.

## Files

| File | Where | Role |
|------|-------|------|
| `run-validation.sh` | head node | **master**: prep → encode → score + enrich. Scopes `pilot\|all\|rescore\|enrich` |
| `prepare_validation_mols.py` | head node | pool leader SMILES → chunks + `pockets_index.csv` |
| `enrichment_validation.py` | cluster | **the analysis**: full-deck scoring → EF / AUC / BEDROC + controls |
| `score_validation.py` | cluster | owns `_load_pairs` / `_loader_row_order` (imported by everything); also legacy per-pocket `scores.csv` |
| `plot_enrichment.py` | laptop | stylia: matched vs mismatched ECDF, per-target AUC, EF vs ceiling |
| `plot_roc.py` | laptop | stylia: ROC curves, matched vs mismatched means, `--grid` per target |
| `crossreact_gradient.py` | laptop | is the mismatched control a null or real cross-reactivity? all-pairs cross-AUC vs target similarity — see [docs/05](../../../docs/05_drugclip_validation.md#what-this-does-and-does-not-show) |
| `pocket_rebuild/` | both | pocket-geometry investigation + true-ligand rebuild — see its README |
| `pocket_rebuild/merge_pocket_sets.py` | cluster | merge encoded pocket sets into `targets_best`, best definition per conformation; writes `pocket_source.csv` |
| `pocket_rebuild/make_restricted_index.py` | cluster | restrict `pockets_index.csv` to one pocket set — **required** for like-for-like comparisons, or target-level actives get inflated |
| `pocket_rebuild/run-enrich-restricted.sh` | cluster | run enrichment against an arbitrary index + pocket set |
| `pocket_rebuild/plot_auc_overview.py` | laptop | stylia: all pockets + all targets + AUC by pocket definition |

`compare_validation.py` and `plot_validation.py` are legacy from the absolute-score era; they
still run but measure the thing we abandoned.

## Workflow

**All DrugCLIP encoding runs on `gpu-queue`** — never propose a CPU fallback, since GPU uses
`--fp16` and mixing devices across arms of an A/B comparison adds an uncontrolled difference.
Scoring and enrichment are CPU-bound BLAS and do belong on `cpu-queue`.

```bash
# 0. one-time: ship the ground truth to the cluster
aws s3 sync /home/marina/Documents/AI2050/Targets/screen_results \
    s3://ai2050-ersilia-cluster/input/validation_leaders/screen_results/

# 1. sanity-check the deck BEFORE spending GPU — expect 339 pockets / 35,952 unique SMILES /
#    18 chunks / 2,264 conformation rows, and no "Skipped" lines
sudo chown ec2-user:ec2-user /fsx/input/validation_leaders
/shared/python39/bin/python3.9 \
    /shared/scripts/drugclip_scripts/validation/prepare_validation_mols.py \
    --screen-results-dir /fsx/input/validation_leaders/screen_results \
    --targets-base /fsx/input/targets --input-dir /fsx/input/validation_leaders \
    --library validation_leaders --scope all

# 2. encode + score + enrich, then run the per-fold audit (*Verify every encode*)
bash /shared/scripts/drugclip_scripts/validation/run-validation.sh all

# 3. iterate on the analysis without re-encoding (~3 min a turn)
bash /shared/scripts/drugclip_scripts/validation/run-validation.sh enrich
EF_FRACTIONS=0.005,0.01,0.02,0.05  bash ... enrich
CENTER_MOLECULES=1 VAL_TAG=centered  bash ... enrich      # conservative floor, over-corrects
TARGETS_BASE=/fsx/input/targets_best VAL_TAG=best  bash ... enrich   # coverage, diluted
# <- the headline arm:
DECOY_LIBRARY=chembl_decoys_200k TARGETS_BASE=/fsx/input/targets_ligand VAL_TAG=ligand_chembl \
    bash /shared/scripts/drugclip_scripts/validation/run-validation.sh enrich

# 4. laptop: download + plot. Results go in output/ (gitignored), never the repo root.
aws s3 sync s3://ai2050-ersilia-cluster/output/validation_leaders/enrichment_ligand_chembl/ \
    ./output/enrichment_out_ligand_chembl/
STYLIA_ENV=$(for e in $(conda env list | grep -v '#' | grep -v '^base' | awk '{print $1}'); do
    conda run -n $e python -c "import stylia" 2>/dev/null && echo $e && break; done)
conda run -n $STYLIA_ENV python scripts/drugclip_scripts/validation/plot_enrichment.py \
    ./output/enrichment_out_ligand_chembl/ --ef-col ef1pct_z
conda run -n $STYLIA_ENV python scripts/drugclip_scripts/validation/plot_roc.py \
    ./output/enrichment_out_ligand_chembl/
python scripts/drugclip_scripts/validation/crossreact_gradient.py \
    output/enrichment_out_ligand_chembl output/enrichment_out_ligand_chembl_centered
```


## Verify every encode

**Verify every new encode** — the per-fold audit must print `0 chunks incomplete`, and a
round-trip of ~200 re-encoded molecules must give median self-cosine ~1.0 (~0.03 means
misalignment, exactly 0.0 means zero vectors):

```bash
/shared/python39/bin/python3.9 - <<'PY'
import h5py, glob, numpy as np
bad = 0
for p in sorted(glob.glob('/fsx/output/<LIBRARY>/drugclip/*_drugclip_*.h5')):
    X = h5py.File(p, 'r')['mol_reps'][:].reshape(-1, 6, 128); n = len(X)
    ok = (np.linalg.norm(X, axis=2) > 0.9).sum(axis=0)
    if not (ok == n).all():
        bad += 1; print(f"  INCOMPLETE {p.split('/')[-1]}  {list(ok)} of {n}")
print(f"{bad} chunks incomplete")
PY
```

Scripts are deployed to the cluster per file, never as a directory sync:
`rsync -av scripts/drugclip_scripts/<file> ai2050cluster:/shared/scripts/drugclip_scripts/`

`VAL_TAG` suffixes the output dir and S3 keys, so arms never clobber each other. `pilot` scope
smoke-tests the encode path but skips enrichment — `enrichment_validation.py` refuses an index
covering fewer than `--min-targets` (10) targets.

## Outputs

Under `/fsx/output/validation_leaders/enrichment<_TAG>/`, mirrored to S3:

- `enrichment_pockets.csv` — 339 rows, **primary**. Keys + `n_conf,n_deck,n_act_listed,
  n_act_deck,active_frac`, then EF/AUC/BEDROC in both `_z` and `_cos`, plus `ef*_max`,
  `ef*_norm_z`, `spearman_paper_*`, `mad_min`, `status`
- `enrichment_targets.csv` — 66 rows, same metric block per UniProt
- `enrichment_controls.csv` — `*_shuffle_mean`, `*_shuffle_sd`, `*_mismatch`, `partner_key`
- `enrichment_summary.csv` — long format, `level ∈ {pocket, pocket_by_target, target}`
- `target_scores.npz` + `deck_smiles.txt` — full-deck z vectors. Enough to rebuild ROC curves,
  top-set overlaps and any new metric **entirely offline**; `plot_roc.py` reconstructs both
  matched and mismatched curves from them without touching the cluster.

## Gotchas

- Embeddings are **per-fold** unit-norm, fold-major (`M[:, f, :]` ↔ cols `f*128:(f+1)*128`).
  Never renormalize the full 768 vector.
- Conformations group into a pocket via `manifest.csv` (`uniprot,domain,pocket → pocket_key`),
  not by pkl name. `"2"` and `"pocket2"` both occur and must never be normalised.
- Leaders failing RDKit 3D generation are absent from the deck entirely — neither active nor
  decoy. `n_act_listed` vs `n_act_deck` reports attrition; >2% warns.
- `prepare_validation_mols.py` prints nothing until it finishes and does ~1,000 FSx opens.
  A couple of minutes on cold FSx is normal — watch `/proc/<pid>/io` before assuming it hung.
- Encoding large (true-ligand) pockets needs `POCKET_BATCH_SIZE`; the DataLoader batch of 32 in
  `encode_pockets_multi_folds` OOMs.
- **`gpu-queue` is a mixed fleet and the GRES label lies.** The `gpu-g6-4xl` compute resource
  lists `g6e.4xlarge` (L40S 48 GB), `g6.4xlarge` (L4 24 GB) and `g4dn.4xlarge` (T4 16 GB), and
  AWS picks by capacity at scale-up; Slurm reports `gpu:l40s:1` on every node regardless,
  because the label comes from the first entry and is never verified. DrugCLIP at the old
  hardcoded `--batch-size 256` allocates ~14.4 GB — fine on L40S/L4, **OOM on the T4**. Memory
  is flat in chunk size (10,000- and 2,000-molecule chunks both used ~14.4 GB), so re-chunking
  does not help; the batch is the only lever. Encode with `MOL_BATCH_SIZE=32`
  (`run-drugclip-job.sh`), which runs on all three. `--exclusive` is also set, so `MAX_CONCURRENT`
  now means *nodes*, not processes on one node. There is no runtime workaround —
  `AvailableFeatures` has no per-instance-type entry for `--constraint`. Durable fix: drop
  `g4dn.4xlarge` from `Instances` and `pcluster update-cluster` with the fleet stopped.
  This probably also re-explains the "5 of 18 chunks partial" bug, which was attributed
  to node packing — instance roulette gives the same signature.
- Metrics were cross-checked once against `rdkit.ML.Scoring.Scoring` inside `drugclip.sif`;
  redo only if the formulas change.
