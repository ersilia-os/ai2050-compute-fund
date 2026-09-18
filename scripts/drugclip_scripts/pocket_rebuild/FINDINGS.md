# Pocket rebuild — findings

---

# RESULT (2026-09-15): the pocket definition was the bottleneck

Two enrichment runs over the **same 155 pockets, same 573 conformations, same 35,931-molecule
deck, same actives** — only the pocket geometry differs.

| `pocket_by_target` | baseline (single point) | true ligand | null |
|---|---|---|---|
| AUC | 0.508 | **0.854** | 0.500 |
| EF@5% | 0.806 | **6.19** | 0.963 |
| EF@1% | 0.537 | **8.74** | 1.040 |

**The controls hold, which is what makes it real:**

| pocket level | matched | mismatched | beat own control |
|---|---|---|---|
| baseline AUC | 0.514 | 0.498 | 90/155 |
| true-ligand AUC | **0.840** | **0.530** | **151/155** |
| true-ligand EF@5% | 6.02 | 0.39 | 144/155 |
| true-ligand EF@1% | 7.90 | 0.00 | 134/155 |

The mismatched control stays at the null (0.530) while matched reaches 0.840. A generic
artefact — better pockets in the abstract, or leakage into the deck — would lift both. It
lifts only the matched arm, so the signal is **target-specific**.

- **55/57 targets** beat their own mismatched control, one-sided binomial **p = 1.1×10⁻¹⁴**
  (the original set managed 42/66, p = 0.03 — the number that never moved for hubness).
- Paired per-pocket AUC change: **+0.268 median, 146/155 improved**.
- Targets below AUC 0.5: **28/57 → 2/57**. Per-target range 0.182–0.873 → 0.407–0.993.
- The previously anti-predictive targets recover: O00329 0.328 → **0.898**,
  P04049 0.474 → **0.863**, Q9UBF8 0.268 → **0.670**.

## What this does and does not prove

**Does:** our DrugCLIP reproduction is now faithful. Every earlier weak result — matched AUC
0.566, EF@1% below its null, 42/66 — was an artefact of feeding the encoder a 6 Å ball around
a single point (7 residues) where the paper uses residues within 6 Å of a real ligand (27).
We were encoding 24% of the intended pocket, far outside the distribution the model was
trained on.

**Does not:** establish that DrugCLIP retrieves genuine binders. `leader.csv` *is* the output
of DrugCLIP applied to the authors' pocket, so reconstructing their pocket reproduces their
ranking. AUC 0.84 measures agreement with their pipeline, not biological validity. That still
needs the adversarial-deck test, or an external benchmark (DUD-E / LIT-PCBA), or experiment.

The residual gap from perfect agreement is expected: `cealign` is not TM-align, our ligand
choice can differ where a PDB entry has several, and our deck is 36k rather than 500M.

## PyMOL audit of the two targets still below 0.5 (2026-09-16)

Sessions and renders in `pymol_out/`; residue lists in `p06493.json`, `p17252.json`.

### P06493 (0.407) — the pocket is perfect; the deck is the problem

The 6 Å pocket from the 5ttu template is a **textbook CDK1 ATP site**: Gly-rich loop
I10/G11/E12/G13/V18, catalytic **Lys33**, gatekeeper **Phe80**, the complete hinge
E81-F82-L83-S84, and **DFG Asp146**. 23 residues, ligand fully enclosed in the cleft.

So the sub-chance AUC is not geometric. CDK1's ATP site is the most **generic** pocket in the
set, and the deck is ~35,700 molecules that are overwhelmingly *other kinases'* inhibitors —
all plausible CDK1 binders designed against the same conserved site. P06493 also has the most
actives of any pocket (240). This is the adversarial-deck problem in its purest form, and it
makes P06493 a sharp, falsifiable prediction for the ChEMBL decoy run: **CDK1 should recover
substantially once the deck is not kinase-saturated.**

### P17252 (0.449) — a target-level max-pooling artefact, not a failure

Its three pockets move in opposite directions:

| pocket | n_act | AUC base → lig | EF@5% |
|---|---|---|---|
| `_0_0` | 181 | 0.398 → **0.359** ↓ | 0.99 → 0.33 |
| `_0_3` | 113 | 0.674 → **0.841** ↑ | 3.89 → 7.61 |
| `_0_5` | 113 | 0.719 → **0.800** ↑ | 1.95 → 6.02 |
| target | 407 | 0.500 → **0.449** ↓ | |

- **`_0_3` is the canonical ATP site** — Gly-rich loop 345–353, catalytic Lys368, αC Glu387,
  hinge 417–421, **DFG D481-F482-G483**.
- **`_0_0` is that site smeared 7.2 Å** (Jaccard 0.381, 16/30 residues shared). It keeps D481
  but **loses F482/G483** and instead reaches into the C-terminus (A623–F630). The ATP site
  displaced out of the cleft.
- **`_0_5` is a genuinely distinct site** 22 Å away, **zero** residues shared with `_0_0` — and
  it works (0.800). So a *different* site is fine; a *displaced* one is not.

Target scores max-pool over all 13 conformations while actives are unioned (407), so `_0_0` —
which has the most actives — drags down two excellent pockets. **The pocket-level result for
this target is good; only the target-level aggregate is bad.** The "2/57 below 0.5" count
therefore overstates the remaining problem.

### A blind spot in the Phase 1 QC

`_0_0`'s centroid offsets are all small (1.4–4.0 Å) so it passed the `--max-offset` check.
**Centroid agreement does not constrain ligand orientation**: a 27-atom ligand with the right
centre but the wrong long axis selects a different residue set. Offset is necessary, not
sufficient. A stronger check would compare the ligand's principal axis, or the residue set,
against another conformation of the same pocket — conformations of one pocket should agree.

## Loose ends

- **P06493 stays at 0.407.** Pocket verified correct (above); the test is the ChEMBL deck.
- **Q14994 regressed, 0.819 → 0.590** — one of the few that got worse. It is a template pocket
  that already worked; worth understanding why the "better" geometry hurt it.
- The 182 GenPack-route pockets are untouched and still use the single-point definition. If
  the same gain applies there, the full 339-pocket result would change substantially — but
  their ligand is unrecoverable, so it needs a proxy (fpocket cavity, or a tuned probe),
  validated against the 155 pockets where we now know the truth.

---

Running log for the pocket-side investigation. Numbers here are measured, not assumed;
where something is still an inference it says so.

---

## Why we are looking at pockets at all

Hypothesis 1 (hubness, `CENTER_MOLECULES=1`) was tested and **does not rescue the result**.
Comparing `enrichment_out/` against `enrichment_out_centered/`:

| statistic (`pocket_by_target`) | baseline | centered | null |
|---|---|---|---|
| EF@5% matched | 0.925 | 1.054 | 0.988 |
| EF@5% mismatched | 0.576 | 0.492 | |
| AUC matched | 0.547 | 0.581 | 0.500 |
| AUC mismatched | 0.503 | 0.483 | |

It meets the letter of the prediction, but it is not a win:

- **Discrimination did not change at all.** Targets beating their own mismatched control:
  **42/66 before, 42/66 after**. Pocket level 225/339 → 224/339. Centering moved the location
  of the distribution without making more targets separable.
- **The widening gap is partly mechanical.** Centering subtracts each molecule's mean across
  the same 66 targets, making scores roughly zero-sum across targets: if a molecule rises in
  its own target it must fall in the others, which is where the mismatched control draws from.
- **EF@1% at pocket level is still below its null** (0.640 → 0.670 against a null of 0.943 →
  0.998). If hubness were what blocks the top of the ranking, removing it should have lifted
  EF@1% to at least the null. It moved 0.03.
- Per-target paired AUC delta is noise-sized: median **+0.005**, improved in 38/66.

Side effect worth keeping: centering **compressed both tails** (per-target AUC range
0.295–0.916 → 0.360–0.865; targets below 0.5 fell 25 → 21), and the outliers survive it,
which makes them more credible.

## Finding 1 — the pocket-detection route splits performance

The two pocket-token conventions are two different detection methods (paper p. 12), and the
bare-integer conformers carry the source PDB code in their filename
(`..._4_5orz_complex_refined.pdbgz`) while the `pocketN` ones do not:

| route | token | n pockets | median AUC | mismatched | median n_conf |
|---|---|---|---|---|---|
| Fpocket + GenPack | `pocketN` | 182 | **0.603** | 0.526 | 10 |
| template / PDBbind | bare int | 157 | **0.507** | 0.484 | 4 |

- Paired within-target (55 targets have both): **+0.091 AUC for GenPack, 40/55, sign test
  p = 5.1×10⁻⁴**.
- Not the `n_conf` confound: within n_conf 4–9, 0.601 vs 0.482.
- The worst targets are worst *specifically through their template pockets*:

  | target | target AUC | fpocket pockets | template pockets |
  |---|---|---|---|
  | P04049 | 0.459 | 0.669 (n=1) | **0.282** (n=3) |
  | P06493 | 0.328 | 0.427 (n=2) | **0.232** (n=1) |
  | Q9UBF8 | 0.295 | 0.469 (n=2) | **0.268** (n=1) |
  | P00519 | 0.916 | 0.890 (n=2) | — |

  Sub-0.3 AUC is an actively *inverted* ranking, not noise.
- Corroborating: all 5 single-point fallbacks in the cavity adapter fall on template pockets.

## Finding 2 — `--max-pocket-atoms 256` silently crops 28% of pockets

Production used the fpocket-cavity dummy ligand. Measured on the 570 staged `_LIG.pdb`,
applying upstream's hard-coded 6 Å rule (`encode_pockets.py:102`):

- dummy ligand: median **63** atoms (range 1–141; 5 single-point fallbacks, 0.9%)
- residues kept: median **28** (range 7–53)
- heavy atoms: median **225**, max **434**; **161/570 (28%) exceed 256**, none exceed 511

`run-drugclip-pocket-job.sh:109` passes **256**; upstream `encode_pocket.sh:16` uses **511**.
Above the limit `CroppingPocketDataset` (`cropping_dataset.py:45`) takes a seeded random
subsample weighted *toward the centroid*, so it preferentially discards the periphery.

> Correction to an earlier reading: the production pockets are **not** a bare centroid point.
> A single-point probe would give median 9 residues; the cavity dummy gives 28. The
> "pockets too small" framing was wrong — the crop is the real size problem.

## Finding 3 — the authors' true ligand is recoverable for the template route

582 of the 2,264 local refined conformers carry a source PDB code (**415 distinct RCSB
entries**), so the exact transposed PDBbind ligand can be recovered for **157 of 339 pockets
across 57 of 66 targets** — precisely the subset performing at chance.

The GenPack ligand is *not* recoverable: every `complex_refined.pdbgz` in the distributed
`screen_results.zip` has **0 HETATM** records (verified by extracting two directly from the
zip's central directory).

## Phase 1 result — 576/582 conformations recovered, and the mislocation hypothesis is dead

`recover_template_ligands.py` over the full set: **576 of 582** conformations, 57 targets,
157 pockets, 415 RCSB entries. **0 fetch failures, 0 alignment failures**, 6 conformations
with no ligand ≥10 heavy atoms. Not-clean fraction **11.7%**, under the 20% soundness bar.

| metric | median | q90 | max |
|---|---|---|---|
| centroid offset | **2.12 Å** | 4.30 | 48.28 (34/576 above 5 Å) |
| cealign RMSD | 3.71 Å | 4.85 | 7.14 |
| aligned residues | 240 | | min 72 |
| ligand heavy atoms | 26 | | 10–74, 398 distinct HET codes |

**The authors' template transposition is accurate, and pocket location does not explain the
AUC.** Spearman(centroid_offset, auc_z) = **−0.011** over 155 pockets. Pockets with offset
≤ 2 Å have AUC median 0.517; pockets with offset > 5 Å have 0.542 — no relationship. And the
worst pockets are among the best-localised:

| pocket | AUC | centroid offset | true residues |
|---|---|---|---|
| P04049 `_0_3` | 0.245 | 1.98 Å | 39 |
| P06493 `_0_0` | 0.232 | 2.56 Å | 26 |
| Q9UBF8 `_0_0` | 0.268 | 2.25 Å | 36 |
| O00329 `_0_0` | 0.328 | 1.57 Å | 25 |
| Q14994 `_0_8` (best) | 0.819 | 1.36 Å | 20 |

> This refutes the hypothesis the plan was built on. The template route's 0.507 is **not**
> caused by pockets on the wrong site. Sub-0.3 AUC at 2 Å localisation means the ranking is
> inverted for a pocket that is in the right place — which is a stranger and more interesting
> problem than a mislocation.

## CORRECTION (2026-09-15) — what the production pockets actually are

An earlier version of this file said production used the fpocket-cavity dummy ligand. **That
was wrong**, and it invalidated two results. Measured directly on the cluster:

```
head -1 /fsx/input/targets/P00519/pockets/manifest.csv
  -> 10 columns, no n_lig_atoms          => prepare_centers_for_drugclip.py
grep -c '^HETATM' <any>_LIG.pdb
  -> 1                                    => --probe-radius 0, a single point
```

Production is the **single-point centres** set. `/home/marina/fpocket_staging/targets_fpocket`
is a separate, never-evaluated experiment that produced none of our AUCs.

Everything computed against `fpocket_staging` as "current" is therefore **void**: the earlier
IoU/AUC correlation of −0.267 and the 77-pocket crop test both correlated cavity-pocket
geometry against AUCs produced by single-point pockets. The "wrong sign IoU" worry goes with
them.

## Phase 0 result — the crop never fired (clean null)

`verify_crop_control.py` over all 2,264 conformations:

```
UNDER (never cropped)  n=2264  cosine median 0.999998  min 0.999484
OVER  (was cropped)    n=   0
-> NO CROPPED POCKETS found above the threshold
```

Production pocket sizes: median **54 heavy atoms** (q25 44, q75 64, min 15, max 98).
**Nothing is within a factor of two of the 256 limit**, so `--max-pocket-atoms` was never
binding and could not have affected anything. Hypothesis eliminated for one small GPU run.

Bonus: the 0.999998 median cosine confirms the pocket encoder is reproducible under `--fp16`,
which is worth knowing independently.

## Phase 2 result (corrected) — our pockets are ~4× too small

Both definitions computed from the *same* file, so the receptor conformation is identical and
only the "ligand" differs — the true transposed PDBbind ligand, or the single grid-centre point:

| | median | q25–q75 |
|---|---|---|
| true-ligand residues | **27** | 23–32 |
| production residues | **7** | 6–8 |
| true-ligand heavy atoms | **211** | 184–251 |
| production heavy atoms | **53** | 43–64 |

- **IoU(production, true) = 0.238**
- **Our pocket captures 24% of the paper's pocket** — 7 residues of 27.

This is the clearest measured defect found so far, and it is a first-principles problem, not
just a correlation: ProFSA pretraining defines a pocket as residues within 6 Å of a real
fragment, and DrugCLIP fine-tuning as residues within 6 Å of a real ligand. A 6 Å ball around
a single point is **outside the distribution the encoder was ever trained on**.

### But IoU does not survive the size confound

| term | Spearman vs auc_z | n |
|---|---|---|
| centroid_offset | −0.011 | 155 |
| IoU(production, true) | **+0.141** | 155 |
| true pocket size (n_res) | **−0.230** | 155 |
| IoU vs true size | **−0.514** | 155 |
| **partial(IoU, AUC \| size)** | **+0.028** | 155 |
| partial(size, AUC \| IoU) | −0.185 | 155 |

The sign is now correct (+0.141, matching fig. S10A), and the top IoU bin looks dramatic —
AUC 0.735 for IoU > 0.4 (n=10) against 0.49–0.54 elsewhere. **But that is mostly the size
confound.** A 6 Å ball overlaps a *small* true pocket better by construction (ρ = −0.514), and
small pockets score better anyway. With size held fixed the IoU effect essentially vanishes
(+0.028). Stratified within size terciles the high-IoU advantage is consistently positive but
small: +0.052, +0.027, +0.016.

**What this does and does not license.** It does not license a claim that matching the paper's
pocket will improve AUC — that is not demonstrated. What is demonstrated is that we encode 24%
of the intended pocket, far off the encoder's training distribution. Whether fixing that helps
is genuinely unknown, because "big true pocket scores worse" has two incompatible readings and
the current data cannot separate them:

- a 7-residue ball is *proportionally worse* for a large site → the rebuild helps most there;
- large sites are intrinsically harder (promiscuous, flexible) → the rebuild helps little.

Only encoding the true-ligand pockets distinguishes these. That is Phase 4, it is cheap
(582 conformations), and the uncertainty is what makes it worth running rather than not.

## Smoke test — O00329, pocket `0` (3 conformations)

First real output of `recover_template_ligands.py`:

| conf | PDB | ligand | heavy atoms | align RMSD | aligned res | centroid offset |
|---|---|---|---|---|---|---|
| 0 | 6gvf | FE5 | 23 | 3.85 Å | 792 | **2.26 Å** |
| 1 | 2x38 | IC8 | 30 | 1.80 Å | 808 | **1.57 Å** |
| 2 | 4v0i | J82 | 26 | 2.52 Å | 600 | **1.54 Å** |

Real PI3K inhibitor co-crystals; the superposition is sound and the transposed ligand lands
1.5–2.3 Å from the authors' averaged grid centre.

Geometry against our production cavity pocket for the same conformation
(PyMOL and numpy implementations agree exactly):

```
residues: true 23, current 35, shared 22   ->  IoU 0.611
```

**Our pocket is a superset, not a mislocation** — it contains 22 of the paper's 23 residues
and adds 13 more. For this pocket the 8 Å alpha-sphere cavity over-selects rather than
misplaces. Note this pocket still has AUC 0.328 despite good localisation, which is evidence
*against* mislocation being the whole story — but n=1 pocket, so it settles nothing yet.

**Open until Phase 1 runs in full:** whether the bad template pockets (P04049, P06493,
Q9UBF8) show large centroid offsets. That is the discriminating measurement.

---

## Status

- [x] Scripts written and smoke-tested (`recover_template_ligands.py`,
      `compare_pocket_geometry.py`, `pymol_pocket_session.py`, and the three cluster scripts)
- [x] Phase 1 full run — 576/582 conformations recovered, 11.7% not-clean
- [x] Phase 2 — geometry vs AUC. **Mislocation ruled out.** IoU underpowered and
      pointing the wrong way
- [ ] Phase 3 — PyMOL audit of the AUC extremes (next; the remaining laptop-only step)
- [ ] Phase 0 — 256 → 511 re-encode *(cluster — Marina submits)*
- [ ] Phase 4 — encode + score the true-ligand pockets *(cluster — Marina submits)*

**Cluster work is run by Marina, never by Claude.** The laptop phases are done; the cluster
phases are handed over as commands.

## Where this leaves the investigation

The pocket-side story is now:

1. **Location is fine** — ruled out by direct measurement, not argument.
2. **Our pocket over-selects** relative to the paper's (31 vs 27 residues, IoU 0.52), and
   bigger pockets score worse (ρ = −0.230). Two mechanisms predict that — the 256 crop, and
   simple dilution by non-contact residues — and they are not yet separated.
3. **The route effect (+0.091, p = 5×10⁻⁴) is real but its mechanism is unexplained.** It is
   not location. It is not obviously size either: template pockets are only slightly larger
   (239 vs 221 median heavy atoms).

The honest reading is that the strongest *established* fact remains the route split, and we
still do not know why it exists. Phase 0 is worth running because it is nearly free and
settles the crop. Phase 4 is worth running because it is the only direct test of "does the
paper's own pocket definition score better than ours?" — but the prior for it is weaker than
when the plan was approved, and the negative IoU correlation is a genuine warning sign.

An alternative worth considering before spending more on pockets: the route split may not be
about geometry at all. Template pockets have ~4 conformations against GenPack's ~10, and each
template conformation is a *different PDBbind ligand's* structure rather than a resampling of
one pocket — so the max-pool over conformations is doing something structurally different in
the two routes. That is testable offline from `target_scores.npz` without touching a GPU.

## Caveat carried forward

IoU for the *full* template set needs the production `_LIG.pdb` files, which live on
`/fsx/input/targets`. Only 12 of 66 targets are on the laptop
(`/home/marina/fpocket_staging/targets_fpocket`). Until those are synced,
`compare_pocket_geometry.py` reports true-ligand geometry and centroid offset for every
pocket but leaves IoU blank outside those 12. The offset alone still answers the mislocation
question.
