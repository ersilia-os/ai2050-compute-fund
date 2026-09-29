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

## Status (2026-09-18) — decoy-validated; pocket definition is everything

Three things are now settled. The reproduction is faithful; the result survives a realistic
200k decoy pool; and pockets built from a real ligand carry **all** of the signal — the rest
carry none.

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

### Headline: `targets_ligand` + ChEMBL decoys

Deck = 35,931 leaders + 199,930 ChEMBL decoys = **235,861** molecules. 155 pockets / 57
targets. `VAL_TAG=ligand_chembl`, uncentered — see *Controls* for why uncentered is the
honest arm.

| `pocket_by_target` | leaders only (36k) | **+ decoys (236k)** | + decoys, centered |
|---|---|---|---|
| EF@1% | 9.01 | **28.55** | 17.14 |
| EF@5% | 6.98 | **13.57** | 10.34 |
| AUC | 0.872 | **0.944** | 0.891 |
| BEDROC α20 | 0.317 | **0.553** | 0.414 |
| above null | 57/57 | **57/57** | 56/57 |

Pocket-level matched EF@1% **25.0 against a mismatched control of 0.52** and a shuffle null of
0.97; 144/155 pockets beat their own control. Target level: AUC 0.806 matched vs 0.702
mismatched, 47/57 targets beating their own control.

Adding decoys *raises* every metric because a larger haystack makes the same retrieval more
impressive, and because the 236k deck lifts the EF@1% ceiling from ~8.7 to ~100 — EF@1% is a
usable statistic again and is now the one to quote.

**This is no longer circular.** The decoys were never seen by DrugCLIP, so unlike `leader.csv`
they are not the model's own output.

### Pocket definition is the whole story

Split the single `best` run by how each pocket was defined — same deck, same decoys, same
labels, same molecules, geometry the only variable:

| | matched EF@1% | mismatched EF@1% | matched AUC | mismatched AUC |
|---|---|---|---|---|
| true-ligand rebuild (155 pockets) | **25.0** | 0.60 | **0.944** | 0.689 |
| older definitions (184 pockets) | **0.81** | 0.00 | **0.625** | 0.615 |

The 184 pockets on the old definitions score AUC 0.625 against **their own mismatched control
of 0.615** — a gap of 0.010. They do not beat the wrong pocket, and their EF@1% of 0.81 is
below the shuffle null. They contribute nothing; whatever AUC they show is the free baseline
any pocket gets from this deck (see *Controls*).

This supersedes the earlier "use `targets_best`" recommendation. Coverage is not free: the
`best` set's 339 pockets / 66 targets dilute a real result with 184 dead ones, dropping
`pocket_by_target` EF@1% from 28.55 to 7.44 and AUC from 0.944 to 0.798. **Report
`targets_ligand` (57 targets) as the headline and the split table as the finding.** Honest
coverage is 57 of 66 targets.

Reproduce the split from two local results dirs: rows whose `status == 'ok'` in the
`ligand_chembl` arm's `enrichment_pockets.csv` are the 155 with a true-ligand rebuild; the
remaining 184 `screen_dir`s in the `best_chembl` arm are the others.

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

**Caveat now discharged:** `leader.csv` is the *output* of DrugCLIP applied to the authors'
pocket, so on its own it only shows the reproduction is faithful. The ChEMBL decoy arm answers
the harder question — the decoys were never touched by DrugCLIP, and the signal survives them.
It remains a **lower bound**, because ChEMBL contains genuine binders for these kinases that we
labelled decoy.

### Route split — and the open limitation

The two pocket-detection routes perform differently, and the token tells you which:
bare integer = template/PDBbind, `pocketN` = Fpocket + GenPack.

| route | n pockets | pocket_by_target AUC (baseline) |
|---|---|---|
| GenPack (`pocketN`) | 182 | 0.599 |
| template (bare int) | 157 | 0.500 |

The 182 GenPack pockets have no recoverable ligand (0 HETATM in every distributed
`complex_refined.pdbgz`) and the cavity proxy doesn't help them, so they are still on the
single-point definition — and the split table above shows that means no target-specific signal
at all. **This is now the main open work: see *Next steps*.**

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
| **+ ChEMBL decoys** | `chembl_decoys_200k`: 199,950 staged → **235,861 deck** after merge |

`leader.csv` files are top-N leaderboards *additionally* floored at 4, not "everything above 4".

**The decoy library** lives at `/fsx/input/chembl_decoys_200k` (100 × 2,000 molecule chunks) and
`/fsx/output/chembl_decoys_200k/drugclip`. It is drug-like — p50 27, p99 45, max 51 heavy atoms,
nothing above 60 — so decoys are not separable from leaders on size. Decoys are appended after
the leaders, never labelled active, and any decoy whose SMILES string-equals a leader's is
dropped automatically.

Reported per pocket (primary — `leader.csv` is itself a per-pocket list, and within-target
leader sets are near-disjoint so the labels are clean) and per target. **`pocket_by_target`,
the median of per-target medians, is the headline statistic**: the 339 pockets are not
independent, so a plain median over them over-weights heavily-pocketed targets.

## Metrics and nulls

EF@1/5/10%, ROC-AUC, BEDROC at α=20 and α=80.5 (upstream `cal_metrics()` uses 80.5 — both are
emitted so the conventions are never silently compared). Plain numpy, because **rdkit is not
available to `/shared/python39`** and that interpreter must not be modified. Stable descending
sort, tie-aware mid-ranks, fractional credit at the EF cut, float64 before ranking.

- **EF** null = 1. On the old 36k leaders-only deck **EF@1% was unusable** — ~127 actives meant
  the top 1% was 360 slots with a null expectation of 1.27 hits, i.e. 0–3 events of counting
  noise — so EF@5% and AUC were the metrics to quote. **The 236k decoy deck removes that
  limit**: the top 1% is ~2,360 slots and the ceiling rises to the full 100. On any decoy arm,
  **EF@1% is now the sharpest statistic and the one to report** (`--ef-col ef1pct_z`).
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

### ⚠ The mismatched control is a HARD control, not a null

Most of these 66 targets are kinases. Scoring a target's actives against *another kinase's*
pocket is not a neutral comparison — ATP-site inhibitors genuinely bind related kinases, so an
elevated mismatched score can be correct pharmacology. Do not read mismatched > 0.5 as
contamination by default.

`crossreact_gradient.py` separates the two explanations. Cross-reactivity depends on *which*
partner you are scored against; a leaders-vs-decoy population artefact is flat across partners.
Scoring every target's actives against all 56 other pockets (uncentered, `ligand_chembl`):

| partner similarity | n pairs | median mismatched AUC |
|---|---|---|
| least similar third | 1064 | 0.563 |
| middle third | 1064 | 0.689 |
| most similar third | 1064 | 0.763 |

**r = 0.70** between partner similarity and mismatched AUC, and each target's *worst* partner
gives a median AUC of **0.327** — below chance, which a population artefact cannot produce.
So the elevated control is mostly real cross-reactivity, with only a small flat residue
(0.563 rather than 0.500 for unrelated partners).

Consequences:

- **The honest target-specificity comparison is matched vs *unrelated* partners**: AUC 0.806
  vs 0.563, not vs the pooled 0.749.
- **`CENTER_MOLECULES=1` over-corrects.** It cannot tell "scores well against everything
  because it is a popular molecule" from "scores well against many kinases because it is a
  kinase inhibitor", and it deletes both: the gradient collapses (r 0.70 → 0.40, most-similar
  tertile 0.763 → 0.570). Treat centered numbers as a **conservative floor**, not the corrected
  truth, and report uncentered as primary.
- A target failing against a close relative may be failing a genuinely hard discrimination,
  not failing outright. Check the partner before writing a target off.

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

   **1b. The first version of that guard was itself wrong (fixed 2026-09-18).** It rebuilt the
   LMDB keys as `str(input row index)`, but `smiles_to_lmdb.py:155` writes `key = str(n_ok)`, a
   counter over **successful** molecules. The two agree only for a chunk with zero RDKit
   failures; one failure leaves a hole that shifts every lexicographic position after it. On a
   2,000-row chunk a failure at input 1500 mispairs 102 rows, one at input 5 mispairs 1997 of
   1999. Both readers now derive the permutation from the success count alone
   (`sorted(range(n), key=str)`), which needs no input CSV. Effect on results was small — the
   leaders deck's 21 failures were concentrated — but real: `pocket_by_target` AUC 0.854 → 0.872,
   EF@1% 8.74 → 9.01.
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
| `crossreact_gradient.py` | laptop | is the mismatched control a null or real cross-reactivity? all-pairs cross-AUC vs target similarity — see *Controls* |
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

## Next steps — the GenPack route

The decoy question is answered. The open work is the **182 GenPack pockets** (`pocketN` token),
which are stuck on the single-point definition and, per the split table in *Status*, carry
**no target-specific signal at all** — matched AUC 0.625 against their own mismatched control
of 0.615. Fixing them would take honest coverage from 57 to 66 targets and roughly double the
usable pocket count.

**Why they are stuck:** their ligand is unrecoverable — 0 HETATM in every distributed
`complex_refined.pdbgz`. See `pocket_rebuild/FINDINGS.md`.

**What is already ruled out, so don't redo it:**

- **The fpocket cavity proxy.** Tested like-for-like on the 77 pockets / 12 targets where both
  definitions exist: flat on AUC (0.572 vs 0.579) and *worse* on early enrichment (EF@5% 0.56
  vs 0.95). **Do not spend GPU extending it.**
- **Pocket size.** The cavity carries 88 atoms against the true ligand's 29 and gains nothing;
  bigger pockets score *worse* (ρ = −0.230).
- **Pocket location.** Centroid offset median 2.12 Å, ρ = −0.011 vs AUC.
- **Atom cropping.** `--max-pocket-atoms 256` never bound on the old set (max 98 atoms).

What remains is the **shape** of the residue selection: a real ligand picks an elongated,
contact-complementary set; a cavity blob or a point picks a spherical one. Any fix has to
reproduce that, not just add atoms.

Note the route confound runs *against* the ligand explanation, which strengthens it: at
baseline the GenPack route scored **better** than the template route (AUC 0.599 vs 0.500), yet
the template route with a true ligand reaches 0.944. The lift is the ligand, not the route.

**Approaches worth trying, most promising first:**

1. **Transplant a ligand from a homologous pocket.** For each GenPack pocket find a structurally
   similar site with a known ligand (template-route pocket or PDBbind entry), align, transfer
   the ligand pose, and rebuild the 6 Å selection from it. The only approach that reproduces the
   shape property directly. Most of these targets are kinases with well-populated ATP sites, so
   homologues should be easy to find.
2. **Dock a pseudo-ligand.** Dock a known binder into the GenPack site and use the pose to
   define the pocket. Cheaper than (1). **Do not dock a molecule from `leader.csv`** — that
   reintroduces the circularity the decoy arm just removed. Use an external binder.
3. **Recover the ligand upstream.** The distributed `complex_refined.pdbgz` has no HETATM, but
   the authors' pipeline must have had a ligand somewhere. Worth one pass over the other
   distributed files before building anything.

**How to evaluate — the benchmark is ready, change nothing about it.** Rebuild into a new
`targets_genpack_<method>`, encode on `gpu-queue` (`MOL_BATCH_SIZE`, see *Gotchas*), then:

```bash
DECOY_LIBRARY=chembl_decoys_200k TARGETS_BASE=/fsx/input/targets_genpack_<method> \
    VAL_TAG=genpack_<method> \
    bash /shared/scripts/drugclip_scripts/validation/run-validation.sh enrich
```

Use `pocket_rebuild/make_restricted_index.py` to restrict the index to the rebuilt pockets, or
target-level actives get inflated and the comparison is not like-for-like.

**The bar is low and unambiguous: beat your own mismatched control.** The current 184 do not
(0.625 vs 0.615). A rebuild that reaches even AUC 0.75 against a ~0.65 control is a real win.
Compare against the true-ligand pockets (EF@1% 25.0, AUC 0.944) as the ceiling.

### Smaller open items

- **ChEMBL is bioactive, not neutral** — it contains genuine binders for these exact kinases,
  labelled decoy and ranking where they belong, so every decoy number is a **lower bound**. For
  an unbiased complement use property-matched decoys or a random Enamine REAL slice (mostly
  virtual, uncharacterised); the two together bracket the answer.
- **Batch-size equivalence was never measured.** Leaders were encoded at batch 256, the ChEMBL
  decoys at 32 (the T4 made 256 impossible). Inference is deterministic and attention masks
  handle padding, so they should agree to fp16 rounding — but it is an assumption. Re-encode
  ~200 leader molecules at `MOL_BATCH_SIZE=32` and check median self-cosine ≈ 1.0 against their
  existing rows.
- **The 9 targets absent from `targets_ligand`** are only reachable through the GenPack work
  above.

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
  This probably also re-explains the "5 of 18 chunks partial" bug above, which was attributed
  to node packing — instance roulette gives the same signature.
- Metrics were cross-checked once against `rdkit.ML.Scoring.Scoring` inside `drugclip.sif`;
  redo only if the formulas change.
