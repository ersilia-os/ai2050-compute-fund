# DrugCLIP validation — enrichment

Does our DrugCLIP setup retrieve the right molecules for the 66 human targets whose pockets we
encoded? Ground truth = the paper's `screen_results/<screen_dir>/leader.csv`
(`screen_dir = AF-<uniprot>-F1-model_v4_<domain>_<pocket>`, columns `smiles,Name,oid,score`).

We do **not** try to reproduce the paper's absolute scores — their robust-z uses a ~500M
library, ours ~36k, so location and scale differ by construction. We reproduce the **ranking**.
That is legitimate because the background enters only as a per-conformation strictly increasing
affine map (`z_c = a_c·res_c + b_c`, `a_c > 0`), and every rank metric is invariant under it.
For a single-conformation pocket the background is *exactly* irrelevant; with several
conformations it matters only through which one wins the max-pool. `enrichment_validation.py`
asserts this: every `n_conf == 1` row must have identical `_z` and `_cos` metrics.

---

## Status (2026-09-17) — reproduction is faithful; pocket definition is the lever

The early weak result was a **pocket-geometry artefact**. `/fsx/input/targets` was built with
`--probe-radius 0`: a single dummy atom at the Glide grid centre, giving a 6 Å ball of
**7 residues / 54 heavy atoms**, against the paper's definition of residues within 6 Å of a
*real ligand* — **27 residues / 211 heavy atoms** (IoU 0.238). Rebuilding the 157
template-route pockets from the authors' actual ligand (`pocket_rebuild/`):

| `pocket_by_target` | single point | **true ligand** |
|---|---|---|
| AUC | 0.508 | **0.854** |
| EF@5% | 0.81 | **6.19** |
| EF@1% | 0.54 | **8.74** |
| targets beating own control | 42/66, p = 0.03 | **55/57, p = 1.1×10⁻¹⁴** |

Mismatched control stays at the null (0.530 vs matched 0.840): target-specific, not a
generic lift.

### Best-available set — the current headline

Only 157 of 339 pockets have a recoverable ligand, so `merge_pocket_sets.py` builds
`targets_best`: each conformation taken from the best definition that has it (true ligand →
fpocket cavity → 1-atom baseline). All three were already encoded and share `pocket_key`, so
merging needs no GPU. Composition: **573 true-ligand + 470 fpocket + 1,221 baseline = 2,264**.

Scoring it (`VAL_TAG=best`, all 339 pockets / 66 targets):

| | pocket | pocket_by_target | target |
|---|---|---|---|
| AUC | 0.704 | **0.713** | 0.585 |
| EF@1% | 2.449 | 2.252 | 2.562 |
| EF@5% | 2.385 | 2.258 | 1.871 |
| BEDROC α20 | 0.122 | 0.120 | 0.109 |
| above null | 281/339 | **60/66** | 56/66 |

Nulls: EF 1.008, AUC 0.500, BEDROC 0.052. **This is the first run where EF sits clearly above
its null** — genuine enrichment, not just the relative discrimination the baseline showed.

### The fpocket cavity proxy does not work — do not extend it

Tested like-for-like on the 77 pockets / 12 targets where both definitions exist (same
actives, same deck, only geometry differs):

| | median pocket AUC | pocket_by_target | EF@5% |
|---|---|---|---|
| 1-atom baseline | 0.579 | 0.589 | 0.95 |
| 88-atom cavity | 0.572 | 0.591 | **0.56** |

Flat on AUC (differences are noise at n=77) and *worse* on early enrichment. **Do not spend
GPU extending the cavity proxy to the remaining 54 targets.**

This also rules out the obvious mechanism for the true-ligand lift: the cavity carries
**88 atoms against the true ligand's 29** and gains nothing, so it is **not pocket size**.
Together with location being fine (centroid offset 2.12 Å, ρ = −0.011 vs AUC) and bigger
pockets scoring *worse* (ρ = −0.230), neither size nor position explains it. What remains is
the **shape** of the residue selection — a real ligand selects an elongated,
contact-complementary set; a cavity blob selects a spherical one of similar bulk.

Also closed: hubness does not explain the weak result; `--max-pocket-atoms 256` never bound on
the old set (max 98 atoms).

**Caveat that governs everything above:** `leader.csv` is the *output* of DrugCLIP applied to
the authors' pocket. All of this shows **our reproduction is faithful** — not that DrugCLIP
finds real binders. That needs the decoy test (see *Next steps*).

### Route split

The two pocket-detection routes perform differently at baseline, and the token tells you which:
bare integer = template/PDBbind, `pocketN` = Fpocket + GenPack.

| route | n pockets | pocket_by_target AUC (baseline) |
|---|---|---|
| GenPack (`pocketN`) | 182 | 0.599 |
| template (bare int) | 157 | 0.500 |

The 182 GenPack pockets have no recoverable ligand (0 HETATM in every distributed
`complex_refined.pdbgz`) and the cavity proxy doesn't help them, so they remain on the
baseline definition. That is the main open limitation.

## Pocket sets on `/fsx/input/`

Five `targets*` directories exist and they are easy to confuse:

| dir | definition | atoms/lig | conf | targets | encoded | use |
|---|---|---|---|---|---|---|
| `targets` | 1-atom probe at grid centre | 1 | 2,264 | 66 | yes | production baseline |
| `targets_best` | **best available per conformation** | mixed | 2,264 | 66 | yes | **use this** |
| `targets_ligand` | true PDBbind ligand, 6 Å | 29 | 573 | 57 | yes | template route only, 0 genpack |
| `targets_fpocket` | fpocket cavity pseudo-ligand | 88 | 570 | 12 | yes | tested, no benefit |
| `targets_a511` | same geometry as `targets`, re-encoded at `--max-pocket-atoms 511` | 1 | 2,264 | 66 | yes | crop control; crop never bound |
| `targets_probe` | grown probe | 33 | 377 | 10 | 6 only | partial/abandoned |

`targets_best/pocket_source.csv` records which set each conformation came from — needed by
`plot_auc_overview.py` to colour pockets by definition.

> Note for `pocket_rebuild/FINDINGS.md`: its Finding 2 ("production used the fpocket-cavity
> dummy ligand, median 63 atoms") measured **`targets_fpocket`** (570 files), not production.
> Production is 1 atom, confirmed across all 2,264 `_LIG.pdb`. Its "Correction to an earlier
> reading" is wrong as applied to the scored run.

---

## The benchmark

One screening **deck** = the union of every `leader.csv` SMILES, encoded once. For each pocket
the whole deck is scored; molecule *m* is **active** for pocket *p* iff *m* is in *p*'s
`leader.csv`, and stays a decoy everywhere else (promiscuous molecules are active wherever
genuinely listed).

| quantity | value |
|---|---|
| pockets / targets / conformations | 339 / 66 / 2,264 |
| pockets per target | 1 – 11 (median 5) |
| deck | 35,952 pooled → **35,931 encoded** (21 RDKit 3D failures) in 18 × 2,000 chunks |
| actives per pocket | 10 – 241 (median 127) → prevalence 0.35% |
| actives per target (union) | 150 – 1334 (median 554) → prevalence 1.54% |
| molecules listed by >1 target | 3,511 (max 25) |

`leader.csv` files are top-N leaderboards *additionally* floored at 4, not "everything above 4".

Reported per pocket (primary — `leader.csv` is itself a per-pocket list, and within-target
leader sets are near-disjoint so the labels are clean) and per target. **`pocket_by_target`,
the median of per-target medians, is the headline statistic**: the 339 pockets are not
independent, so a plain median over them over-weights heavily-pocketed targets.

## Metrics and nulls

EF@1/5/10%, ROC-AUC, BEDROC at α=20 and α=80.5 (upstream `cal_metrics()` uses 80.5 — both are
emitted so the conventions are never silently compared). Plain numpy, because **rdkit is not
available to `/shared/python39`** and that interpreter must not be modified. Stable descending
sort, tie-aware mid-ranks, fractional credit at the EF cut, float64 before ranking.

- **EF** null = 1, but **use EF@5% and AUC, not EF@1%** on a 36k deck: with ~127 actives the
  top 1% is 360 slots and the null expectation is 1.27 hits, so EF@1% is estimated from 0–3
  events and is mostly counting noise. A bigger deck (see *Next steps*) removes this limit.
- **ROC-AUC** null = 0.5.
- **BEDROC** null ≈ **1/α** (≈0.05 at α=20), **not 0**, and only comparable across rows at
  similar prevalence — read it next to `n_act_deck`.
- EF is ceiling-limited by `EF_max = min(n_act, χN)/(χN) · N/n_act`. Never binding at pocket
  level; it does bind at target level, so use `*_norm_z` there.

Empirical nulls come from the shuffle control, not the algebra — `enrichment_summary.csv`
column `null_median`.

## Controls

The deck is **not** a neutral decoy set: every molecule in it is somebody's top hit. So
`EF > 1` proves nothing on its own.

| control | what it does |
|---|---|
| **Mismatched target** | Same label vector, a *different* target's pocket (deterministic cyclic shift). Holds the actives — and the EF ceiling — fixed, so it is directly comparable. **The claim is matched ≫ mismatched.** |
| **Label shuffle** | `--n-shuffles 5`, fixed seed; empirical null at the row's real prevalence. |
| **`n_conf == 1` identity** | z and cos metrics must agree to 1e-12 — a free end-to-end test of the max-pool and labelling. |

## ⚠ Encoder bugs — every embedding made before 2026-09-14 is void

Two silent, compounding bugs made the first run produce matched AUC 0.516 vs mismatched 0.562,
i.e. the control beating the real thing. Both are fixed and guarded; the guards matter more
than the fixes, because each bug was undetectable from the output file alone.

1. **h5 rows are in lexicographic, not input, order.** `drugclip.py:498` does
   `sorted(list(set(keys)))` on LMDB keys that `smiles_to_lmdb.py:155` writes as *unpadded
   strings*, so the dataset runs `"0","1","10","100",…` while `.smiles.txt` is in input order.
   `mol_reps` carries no molecule identity, so positional pairing is wrong and invisible.
   Undone by `_loader_row_order()` (`score_validation.py`) and `loader_row_order()`
   (`h5_to_csv.py`, which also takes `--row-order {lexicographic,input}`).
   *Durable fix, not done:* zero-pad the key in `smiles_to_lmdb.py` (bind-mountable over the
   sif copy, no rebuild) and emit `<chunk>.rowsmiles.txt` at encode time. **If you do that,
   switch readers to `--row-order input` or you double-correct.**
2. **Partial encodes passed as complete.** `require_dataset` pre-allocates zeros and the loop
   fills fold-major, so a job dying part-way leaves a correctly-shaped, mostly-zero h5 — and a
   row with only fold 0 written isn't all-zero, so no shape or zero-row test catches it. Five
   of 18 chunks had 256 rows of fold 0 only. Caused by GPU OOM from ~8 encoders packed onto one
   node, plus no `set -e`. Now: per-fold completeness checks in `run-drugclip-job.sh` and
   `h5_to_csv.py`, exit-code capture, and `MAX_CONCURRENT` (default 4) on the array.

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

## Files

| File | Where | Role |
|------|-------|------|
| `run-validation.sh` | head node | **master**: prep → encode → score + enrich. Scopes `pilot\|all\|rescore\|enrich` |
| `prepare_validation_mols.py` | head node | pool leader SMILES → chunks + `pockets_index.csv` |
| `enrichment_validation.py` | cluster | **the analysis**: full-deck scoring → EF / AUC / BEDROC + controls |
| `score_validation.py` | cluster | owns `_load_pairs` / `_loader_row_order` (imported by everything); also legacy per-pocket `scores.csv` |
| `plot_enrichment.py` | laptop | stylia: matched vs mismatched ECDF, per-target AUC, EF vs ceiling |
| `plot_roc.py` | laptop | stylia: ROC curves, matched vs mismatched means, `--grid` per target |
| `pocket_rebuild/` | both | pocket-geometry investigation + true-ligand rebuild — see its README/FINDINGS |
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

# 2. encode + score + enrich, then run the per-fold audit above
bash /shared/scripts/drugclip_scripts/validation/run-validation.sh all

# 3. iterate on the analysis without re-encoding (~3 min a turn)
bash /shared/scripts/drugclip_scripts/validation/run-validation.sh enrich
EF_FRACTIONS=0.005,0.01,0.02,0.05  bash ... enrich
CENTER_MOLECULES=1 VAL_TAG=centered  bash ... enrich      # hubness correction
TARGETS_BASE=/fsx/input/targets_best VAL_TAG=best  bash ... enrich cpu-queue   # <- the good one
DECOY_LIBRARY=<encoded_lib> VAL_TAG=decoys  bash ... enrich              # added decoys

# 4. laptop: download + plot
aws s3 sync s3://ai2050-ersilia-cluster/output/validation_leaders/enrichment/ ./enrichment_out/
STYLIA_ENV=$(for e in $(conda env list | grep -v '#' | grep -v '^base' | awk '{print $1}'); do
    conda run -n $e python -c "import stylia" 2>/dev/null && echo $e && break; done)
conda run -n $STYLIA_ENV python scripts/drugclip_scripts/validation/plot_enrichment.py \
    ./enrichment_out/ --ef-col ef5pct_z
conda run -n $STYLIA_ENV python scripts/drugclip_scripts/validation/plot_roc.py ./enrichment_out/
```

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

## Next steps — ChEMBL decoys

The open scientific question is the one the caveat above names: our reproduction is faithful,
but `leader.csv` is DrugCLIP's own output, so this cannot show DrugCLIP finds *real* binders.
The test is a realistic decoy pool.

**The analysis side is already built** — `enrichment_validation.py` takes `--decoy-emb-dir` /
`--decoy-library` / `--decoy-input-dir`, exposed as `DECOY_LIBRARY=<name>` in
`run-validation.sh`. Decoys are appended after the leaders, never labelled active, and a decoy
whose SMILES string-equals a leader's is dropped automatically. A 1.35M deck is a ~4 GB `Mf`;
`centering_offsets()` is memory-flat for exactly this reason.

**What is missing is the encoded decoy library.** `/fsx/input/chembl_decoys_200k` is staged as
raw SMILES; it has **not** been DrugCLIP-encoded (`/fsx/output/chembl_decoys_200k/drugclip/`
does not exist). In order:

1. **Encode it** on `gpu-queue` — files must be named `<lib>_chunk_NNN.csv` since
   `submit-drugclip.sh` globs `*_chunk_*.csv`. 200k also lifts the EF@1% ceiling to the full
   100, so EF@1% becomes usable again (on the 36k leader deck it was ~1.3 expected hits).
2. **Verify the embeddings before using them** — the per-fold audit plus the round-trip
   self-cosine check above. Both encoder bugs are silent, and a scrambled decoy pool would look
   like a null result rather than an error.
3. **Re-run the EF validation with the decoys added, on `targets_best`:**
   ```bash
   DECOY_LIBRARY=chembl_decoys_200k TARGETS_BASE=/fsx/input/targets_best VAL_TAG=best_chembl \
       bash /shared/scripts/drugclip_scripts/validation/run-validation.sh enrich cpu-queue
   ```
   Compare against the `best` arm (AUC 0.713, EF@1% 2.25). **Prediction if DrugCLIP genuinely
   retrieves binders:** EF@1% rises well above that, with mismatched still at the null.

One cheap pocket-side question is still open and worth settling first, because it is minutes on
`cpu-queue` and decides whether anything more should be spent on pocket geometry: **is the
true-ligand lift about the ligand specifically, or about route/target composition?** Run the
103 template conformations present in both `targets_fpocket` and `targets_ligand` three ways —
same pockets, same route, three definitions:

```bash
cd /shared/scripts/drugclip_scripts/pocket_rebuild ; IDX=/fsx/input/validation_leaders
/shared/python39/bin/python3.9 make_restricted_index.py --index $IDX/pockets_index_fp.csv \
    --targets-base /fsx/input/targets_ligand --out $IDX/pockets_index_shared.csv
for t in base cav lig; do
  case $t in base) B=targets;; cav) B=targets_fpocket;; lig) B=targets_ligand;; esac
  bash run-enrich-restricted.sh /fsx/input/$B $IDX/pockets_index_shared.csv cal_$t cpu-queue
done
```

ligand ≫ cavity ≈ baseline ⇒ it is specifically the real ligand, and the 182 GenPack pockets
stay at baseline unless a ligand is transplanted from a homologous pocket. ligand ≈ cavity ⇒
the 0.854 was driven by route or target composition, and the story changes.

**ChEMBL is bioactive, not neutral** — it contains thousands of genuine binders for these exact
kinases, which will be labelled decoys and rank where they belong. It therefore gives a **lower
bound**. For an unbiased complement use property-matched decoys or a random Enamine REAL slice
(mostly virtual, uncharacterised); the two together bracket the answer.

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
- Metrics were cross-checked once against `rdkit.ML.Scoring.Scoring` inside `drugclip.sif`;
  redo only if the formulas change.
