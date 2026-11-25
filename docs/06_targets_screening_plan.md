# Targets screening plan: DrugCLIP → Uni-Dock → Nesso-1

Plan and timeline for the targets work stream, written 2026-11-23, status updated 2026-11-25. Dates are targets, not
commitments. Update the status column and tick milestones as they finish.

## Goal

1. Re-run the **DrugCLIP screen** of five libraries against the final pocket set, using the
   re-encoded library embeddings.
2. **Dock** every molecule of the five libraries with Uni-Dock into the pocket DrugCLIP ranked
   highest for it.
3. **Select up to ~50k** molecules from the docking and run **Nesso-1** (co-folding: SMILES +
   protein structure) on them.

Libraries: Enamine Hit Locator 460K, Coconut 715K, Enamine Liquid Stock 2.5M, Molport 5.3M,
Enamine REAL 10.4M (~19.4M molecules in total).

## Decisions

| Decision | Value |
|---|---|
| Pocket set | `ai2050_targets`: 57 human (`targets_ligand`) + 10 Mtb (`targets_mtb_v2`) targets, 597 conformations. `sets.csv` keeps each target's original set, so validated (human) and unvalidated (Mtb) results stay separable |
| Old Mtb set `targets_mtb` | To be removed |
| DrugCLIP image | `drugclip.sif` unchanged (2026-04-28). Fixes live in the scripts. Do not rebuild it: its RDKit version decides the 3D conformers |
| Molecules too large for the encoder (≥512 heavy atoms) | Empty embedding, logged as `too_large` |
| Molecules with no heavy atoms (`[H][H]`, `[HH]`, `[H+]`) | Empty embedding, logged as `no_heavy_atoms` (decided 2026-11-25; they crashed Coconut chunks 000/017/029) |
| RDKit 3D generation | 60 s limit per molecule; slower ones get an empty embedding (`timeout`) |
| Device per library | GPU: Hit Locator, Liquid Stock. CPU: Coconut, Molport, REAL |
| CPU-vs-GPU embedding comparison | Not done (decided). Rankings within a library are unaffected; comparing raw scores across libraries carries that caveat |
| Docking scope | Full libraries, each molecule docked once into its best DrugCLIP pocket |
| Docking settings | Vina scoring, **fast search mode** (decided 2026-11-25; was balance, ~6× more search work per ligand), seed 42, box = reference ligand + 6 Å, **5 poses kept** |
| GPU quota | Not raised: 4 GPU nodes (T4) |
| Nesso-1 | Image built later, the same way as `unidock.sif` |

## Status (2026-11-25)

**Encoding and screening are finished: all 5 libraries, 19,281,524 molecules × 67 targets / 179 pockets, in `/fsx/output/<library>/screen_v2/`. Next block: docking.**

| Item | State |
|---|---|
| Pocket set `ai2050_targets` | ✅ Built in S3, imported to FSx, verified byte-identical; screen and docking code deployed |
| Encoding pipeline | ✅ Verified end to end, including chunks where RDKit dropped a molecule (round-trip: 200/200, median cosine 1.0, min 0.9995) |
| Hit Locator embeddings | ✅ 47/47 (GPU) |
| REAL 10.4M embeddings | ✅ 1036/1036 (CPU) |
| Molport embeddings | ✅ 533/533 (CPU). Chunk 448 re-ran at batch 8; audit passes on the 5 chunks re-run since 23 Nov |
| Liquid Stock embeddings | ✅ 250/250 (GPU, job 1252). Audit passes on all 65 new chunks (min block norm 0.9995) |
| Coconut embeddings | ✅ 72/72 (CPU). Chunks 000, 017, 029 failed on a zero-atom molecule each (see 2a) and re-ran with the fix (job 434694, 25 Nov): one `no_heavy_atoms` skip each, audit passes on all 72 |
| Screen memory fix (3a) | ✅ Deployed 25 Nov. Job 434772 peaked at 2.0 GiB for 460k molecules → ~45 GiB for REAL (64 GiB node) |
| Hit Locator screen (3b) | ✅ Job 434772 → `/fsx/output/Enamine_Hit_Locator_460K/screen_v2/`: 67 targets / 179 pockets × 460,157 molecules. Human rows **bit-identical** to 6 Oct (57 targets, 155 pockets, max \|Δz\| 0). Mtb vs 6 Oct: 5 new (O50442, P9WJV5, P9WKZ1, P9WNF9, P9WQ95), 6 gone (A6TC99, I6X8D2, P9WHN1, P9WKI7, P9WKL5, P9WPY3), 5 with redefined pockets |
| Screens, all 5 libraries | ✅ 25 Nov, `screen_v2/` per library, 67 targets / 179 pockets, 0 chunks skipped. Molecules: Hit Locator 460,157 · Coconut 657,480 · Liquid Stock 2,492,380 · Molport 5,319,204 · REAL 10,352,303 (total 19,281,524). Peak RSS 2.0 / 2.9 / 10.5 / 21.6 / 42.0 GiB |
| Docking redesign (4a) | Batched pipeline written, tested locally with Uni-Dock faked, **deployed 25 Nov** (checksums verified). Mechanics test 4a′ **running**: test dir built (179 pockets, 559 batches, every receptor has H), job 1319 docking tasks 1 (Mtb) + 3 (human). Steps 4–6 left |
| Mtb receptor hydrogens | ✅ 24/24 `targets_mtb_v2` conformations protonated with PDBFixer (pH 7.4), on FSx at `/fsx/input/targets/<U>/protonated/*_H.pdb` |

### What 25 Nov found

- **The dying CPU nodes were the spot outage, not memory.** `slurm_resume.log` shows
  `InsufficientInstanceCapacity` on 24 Nov (10:05) and 25 Nov (09:55–10:02, 26–28 nodes
  refused), and `slurmctld.log` shows ~10 running nodes going "not responding" on 24 Nov
  09:52–10:14, in the same window. No `Killed`/`MemoryError` in any log, and the chunks that
  "killed their node" (Molport 448, most of Coconut) finished on retry with no code change; a
  memory problem would have failed them again.
- **Coconut 000/017/029 were a data bug.** Each holds one molecule with no heavy atoms:
  `[H][H]` (000, row 8101), `[HH]` (017, row 3181), `[H+]` (029, row 4076). The encoder strips
  hydrogens, the molecule reaches Uni-Mol's tokenizer empty, and its `len(atoms) > 0`
  assertion kills the whole chunk. Chunk 000 failed identically three times. The size guard
  only checked the upper limit; `smiles_to_lmdb.py` now skips these as `no_heavy_atoms`.
  Finished chunks are unaffected: any such molecule would have crashed its chunk.
- **The encoder's logs hide its real errors.** Upstream `encode_mols_multi_folds` closes the
  h5 in `except` and flushes it again in `finally`, so every encoding failure ends in
  `RuntimeError: Unable to synchronously flush file`. The real cause is above
  "During handling of the above exception" in the `.err`. Left unpatched (cosmetic).
- **Slurm accounting is disabled on `ai2050cluster`**, so `sacct` returns nothing; use
  `squeue` and the logs.

### Jobs to check

| Job | Library | What | Cluster | Notes |
|---|---|---|---|---|
| 434694_[0-2] | Coconut | chunks 000, 017, 029 with the `no_heavy_atoms` fix | `ai2050cluster` (CPU) | Finished 25 Nov: `no_heavy_atoms 1` in each, audit 3/3 pass, `missing: none` |
| 434840 | Liquid Stock | screen → `screen_v2/` | `ai2050cluster` (CPU) | Finished 25 Nov: 250 chunks, 2,492,380 molecules, no `WARN`, peak 10.5 GiB |
| 434841 | Molport | screen → `screen_v2/` | `ai2050cluster` (CPU) | Finished 25 Nov: 533 chunks, 5,319,204 molecules, no `WARN`, peak 21.6 GiB |
| 434842 | REAL 10.4M | screen → `screen_v2/` | `ai2050cluster` (CPU) | Finished 25 Nov: 1036 chunks, 10,352,303 molecules, no `WARN`, peak **42.0 GiB** (predicted ~45) |
| 434843 | Coconut | screen → `screen_v2/` | `ai2050cluster` (CPU) | Finished 25 Nov: 72 chunks, 657,480 molecules, no `WARN`, peak 2.9 GiB |
| 1319_[1,3] | Hit Locator | docking mechanics test (4a′ step 3): task 1 Mtb I6X5C9, task 3 human O00329 | `ai2050cluster-large` (GPU) | Submitted 25 Nov. Each log should end `all assigned batches done`; then step 4 checks. Logs `unidock-batches-1319_{1,3}.out` |
| 434772 | Hit Locator | screen with `ai2050_targets` (3a + 3b) | `ai2050cluster` (CPU) | Finished 25 Nov: no errors, no chunks skipped, peak 2.0 GiB, human rows bit-identical to 6 Oct |
| 432121, 432122, 1252 | Molport, Coconut, Liquid Stock | encoding (23 Nov) | both | Finished |

Logs: `/shared/logs/drugclip-<job>_<task>.out` / `.err`, screen `drugclip-screen-<job>.out`.

### Docking mechanics test (4a′)

Checks the batched docking pipeline on the cluster before the 4b pilot. It uses the new Hit
Locator screen, which holds human and Mtb pockets, so the protonated receptors are covered
too. The test dir is separate from the real `docking_v2/`, because the number of batches
per task is fixed per directory and the test uses 2.

- [x] **0. Mtb receptors on FSx.** `ls /fsx/input/targets/*/protonated/*_H.pdb | wc -l` → 24
  (25 Nov)
- [x] **1. Build the test dir** (25 Nov): 179 pockets × 460,157 molecules → 559 batches;
  receptor prep `schrodinger_refined` 155 + `pdbfixer_pH7.40` 24, none missing; 52 pockets
  hold < 1,000 ligands (one small batch each). Run after job 434772 had finished (AL2 head node,
  `ai2050cluster`). In the output, `receptor prep:` must list only `schrodinger_refined` and
  `pdbfixer_pH7.40`, with no `none` and no `!!` line.

  ```bash
  /shared/python39/bin/python3.9 /shared/scripts/docking_scripts/make_docking_manifest.py \
      --screen-dir /fsx/output/Enamine_Hit_Locator_460K/screen_v2 \
      --out-dir /fsx/output/Enamine_Hit_Locator_460K/docking_v2_test \
      --targets-base /fsx/input/ai2050_targets --batch-size 1000
  ```

- [x] **2. Find a task on an Mtb pocket** (25 Nov): the Mtb pockets come first in the
  manifest, so task 1 is Mtb (I6X5C9_d0_p2rank1). Use `== 'schrodinger_refined'` in the
  same snippet to find a human task for step 3.

  ```bash
  D=/fsx/output/Enamine_Hit_Locator_460K/docking_v2_test
  /shared/python39/bin/python3.9 -c "
  import csv
  m=list(csv.DictReader(open('$D/docking_manifest.csv')))
  for b in csv.DictReader(open('$D/batches.csv')):
      r=m[int(b['manifest_row'])-1]
      if r['receptor_prep'].startswith('pdbfixer'):
          print('first Mtb batch', b['batch_id'], r['tag'], '-> task', (int(b['batch_id'])-1)//2+1); break"
  ```

- [x] **3. Submit** (25 Nov, job 1319) task 1 (Mtb, I6X5C9) and task 3 (first human task: batches 5–6, from
  O00329_d0_0) on the AL2023 head node (`ai2050cluster-large`):

  ```bash
  D=/fsx/output/Enamine_Hit_Locator_460K/docking_v2_test
  sbatch --array=1,3 /shared/scripts/docking_scripts/run-docking-batches.sh $D 2
  ```

- [ ] **4. Check** (either head node):

  ```bash
  /shared/scripts/docking_scripts/check-docking.sh $D --failed
  tail -20 /shared/logs/unidock-batches-<JOB>_1.out
  tail -20 /shared/logs/unidock-batches-<JOB>_3.out
  ```

  Pass:
  - each task ends with `all assigned batches done`
  - 3 files per finished batch, and one `receptors/<tag>.pdbqt` per pocket
  - no `errors/` folder
  - `dock` time per batch close to job 1318's ~440 s on a T4

  If the log shows a Uni-Dock error about the ligand list, resubmit with
  `LIGAND_INPUT=gpu_batch sbatch …`.

- [ ] **5. Resume test.** Submit task 4 (untouched by step 3), cancel it once its log shows
  the first batch line (`b0000NN … dock … s`), then resubmit. The second log must say
  `1 already done, 1 to do`.

  ```bash
  sbatch --array=4 /shared/scripts/docking_scripts/run-docking-batches.sh $D 2
  scancel <JOB>_4
  sbatch --array=4 /shared/scripts/docking_scripts/run-docking-batches.sh $D 2
  ```

- [ ] **6. Tick 4a and 4a′** in the timeline. `docking_v2_test/` can be deleted after the
  4b pilot (ask first).

## Timeline

| # | Milestone | Target date | Done when | ✓ |
|---|---|---|---|---|
| 0a | FSx cleanup (Marina) | ongoing | No blocker. Optional: archive the 920k Hit Locator docking files to S3. *Done (25 Nov)* | ✅ |
| 0b | New way of delivering model images (other agent) | before 8 Dec | Image paths used by DrugCLIP/docking scripts unchanged, or scripts updated in the same change. *Done (25 Nov)* | ✅ |
| 1 | Molecule-prep fix (size limit, timeout, parallel 3D, skip log) | 23 Nov | Code deployed, round-trip passed | ✅ |
| **2** | **Finish encoding** | **Sun 29 Nov** | All 5 libraries `missing: none`, audit passes. *Done 25 Nov. The screen loader's norm check also passed on every chunk of the four screened libraries* | ✅ |
| 2a | Diagnose CPU nodes dying in encoding (Coconut, Molport 448) | Thu 26 Nov | Cause found and fix agreed. *25 Nov: spot outage + zero-atom molecules, fixed* | ✅ |
| 3a | Screen code: memory fix so REAL fits on a 64 GB node | Thu 26 Nov | Deployed, and the measured Hit Locator peak scales to < ~55 GiB for REAL. *25 Nov, job 434772: peak 2.0 GiB for 460,157 molecules → ~45 GiB for REAL* | ✅ |
| 3b | Hit Locator screen with `ai2050_targets` | Sun 29 Nov | Human-target scores identical to the 6 Oct run; every row labelled `targets_ligand` or `targets_mtb_v2`. *25 Nov (434772 + `compare-screens.py`): 57/57 targets and 155/155 pockets bit-identical; labels 57 + 10* | ✅ |
| **3** | **Screen all 5 libraries** (CPU, in parallel) | **Thu 3 Dec** | `screen_v2/` per library; the loader skipped no chunks. *Done 25 Nov: 19,281,524 molecules, 0 chunks skipped (jobs 434772, 434840–434843)* | ✅ |
| 4a | Docking redesign: per-batch files on node-local disk, 5 poses | Tue 8 Dec | Deployed and 4a′ passes. *Node-local write path proven by job 1318; code + Mtb receptors deployed 25 Nov* | ☐ |
| 4a′ | **Docking mechanics test** in `Enamine_Hit_Locator_460K/docking_v2_test` | Thu 26 Nov | All 6 steps of [the test](#docking-mechanics-test-4a) pass. *Steps 0–3 done 25 Nov; job 1319 running* | ☐ |
| 4b | Docking pilot in `fast` mode (no comparison with the 7 Oct run, decided 25 Nov) | Fri 11 Dec | Prep + docking timed in `fast` mode; docking dates re-estimated from the measured rate. **Go/no-go** | ☐ |
| 4c | Dock Hit Locator (~14 h) | Tue 15 Dec | Score table complete | ☐ |
| 4d | Dock Coconut (~1–1.5 days) | Fri 18 Dec | Score table complete | ☐ |
| 4e | Dock Liquid Stock (~3.5 days) | Thu 24 Dec | Score table complete | ☐ |
| 4f | Dock Molport (~7 days) | Sat 2 Jan | Score table complete | ☐ |
| **4** | **Dock REAL 10.4M (~13.5 days)** | **18 – 26 Jan** | Score table complete | ☐ |
| 5a | Choose the ≤50k selection rule | ~Tue 5 Jan | Rule decided from the first four libraries' docking | ☐ |
| 5b | Nesso-1 image built and smoke-tested | December – early January | One target end to end | ☐ |
| **5** | **Nesso-1 on the selection** | **February** | Depends on Nesso-1 throughput (unknown) | ☐ |

**Basis for the docking dates:** **re-measured 25 Nov (job 1318) and the October figure
holds.** One pocket, `P00533_d1_1` (EGFR), on a Tesla T4, with ligands prepared in October so
this is docking only:

| setting | 1,000 ligands | per GPU | 4 GPUs |
|---|---|---|---|
| `num_modes=9` (the October setting) | 468 s | 7,692/h | 30,769/h |
| `num_modes=5` (production) | 439 s | 8,200/h | **32,802/h** |

All five libraries (~19.4M) on 4 GPUs: **24.6 days**, against the 25 days assumed. The two
production chunks came in at 440 s and 438 s, a 0.5% spread, so the measurement is stable
rather than a lucky draw. `proteinprep` costs 6 s per pocket, paid once.

Coconut is still assumed 1.5× slower (larger, more flexible molecules) — that assumption is
**not** measured. All five libraries together need ~600 GPU-hours.

Three things the measurement settled:

- **Dropping 9 → 5 poses buys only ~6% speed** (468 s → 439 s). Vina's cost is in the
  conformational search, not in writing the extra poses. It still cuts pose storage ~44%,
  which is the reason that matters given the inode pressure.
- **Node-local pose writing works.** 3,000 poses went to `/tmp` on the GPU node, zero FSx
  inodes — the part of milestone 4a that was least certain, confirmed before the pilot.
- **The queue label lies, as expected.** The node was `gpu-queue-dy-gpu-g6-4xl-1`, advertised
  as `gpu:l40s:1`, physically a T4. Any future timing run must report the real GPU or the
  number is not comparable.

**Caveat on the 24.6 days:** it is one pocket at the *median* box volume (7,898 Å³). Vina's
cost scales with grid size, and across the 113 production-representative pockets the box runs
3,879–15,063 Å³, slightly right-skewed. The true total depends on whether the large-box
pockets also hold many ligands, and the ligand distribution is very uneven (O75469 alone took
18,423). Re-running `time-docking.sh` on a p75 or maximum-box pocket would turn the single
number into a range for ~25 min of GPU. Ligand prep is **not** included — it is CPU and gets
measured when 4a is built.

Script: `scripts/docking_scripts/time-docking.sh`. Summary CSV:
`/fsx/output/docking_timing/timing_1318_P00533_d1_1.csv`.

**Every step also carries 2 extra days** (added 2026-11-23), and the steps run in sequence,
so the margins accumulate: the end of docking is ~3 weeks later than the bare estimates.
Dates are calendar days; a step that needs Marina and lands on a weekend moves to the Monday.

## Review points

| When | What Marina reviews |
|---|---|
| ~~Thu 26 Nov~~ | ~~Cause and fix for the CPU encoding failures~~ (done 25 Nov: spot outage; `no_heavy_atoms` skip approved) |
| Mon 30 Nov | Phase 2 completeness check; Hit Locator screen comparison |
| Fri 11 Dec | Docking pilot, go/no-go for the month-long run |
| ~5 Jan | ≤50k selection rule |
| When ready | Nesso-1 source, weights, licence, GPU memory needs |

## Risks

- **AWS capacity (the main open risk).** Both the GPU (eu-north-1a, all three types) and CPU
  spot pools ran short on 23 Nov, and the CPU pool again on 24–25 Nov. A short pool does not
  only delay jobs: it took running nodes away mid-job (24 Nov). Every gap during docking
  pushes later dates back by the same amount. Adding a second availability zone to the queues
  would reduce this.
- **One bad molecule kills a whole chunk.** Uni-Mol's tokenizer asserts on each molecule
  (`0 < atoms < 512`) and the assertion ends the chunk, not the molecule. Both limits are now
  guarded (`too_large`, `no_heavy_atoms`), but any new failure mode inside the encoder will
  behave the same way.
- **Screen memory for REAL (3a)**: measured 2.0 GiB peak on Hit Locator (460,157 molecules,
  179 pockets), which scales linearly to ~45 GiB for REAL, against 64 GiB on a c6i.8xlarge.
  Resolved unless the pocket set grows a lot (each extra 100 pockets adds ~4 GB for REAL).
- **Holidays.** Liquid Stock and Molport docking run through 24 Dec – 2 Jan; failed tasks
  need someone to resubmit them, or the GPUs sit idle until someone does.
- **Docking ligand prep at scale** is not measured yet; the pilot measures it.
- ~~**Image change (0b)**~~ done 25 Nov. Model SIFs now come from `s3://models-sif`;
  `drugclip.sif` and `unidock.sif` stay in `/shared/sif-files/` (non-model images), the paths
  the DrugCLIP and docking scripts use.
- **Nesso-1 GPU memory.** Co-folding models often need more than a T4's 16 GB; the 48 GB GPUs in
  the fleet cannot be requested by type.

## Caveats to carry into any result

- **Coconut loses ~8% of molecules** before encoding (RDKit cannot build them in 3D, or takes
  over 60 s). Other libraries lose well under 1%.
- **Mtb targets have no measured enrichment.** Only the 57 human targets carry the validated
  figure (EF@1% 28.6, AUC 0.944). Report the two sets separately.
- **Devices differ across libraries** (GPU half precision vs CPU full precision, effect not
  measured): compare rankings within a library, not raw scores across libraries.
- **The 60 s timeout applies only to chunks encoded from 23 Nov.** Earlier chunks embedded slow
  molecules too. Affects tens of molecules.
- **Which borderline molecules get embedded varies between runs.** The `timeout` and
  `embed_failed` counts move with node load: Coconut chunk 000 wrote 9,239, 9,245 and 9,264
  molecules in three runs on 23 Nov. Tens of molecules per chunk, inside the ~8% Coconut loss.
- **3 molecules are dropped as `no_heavy_atoms`** (Coconut: two H₂, one H⁺). Not drug-like;
  listed for completeness.

## Monitoring commands

Encoding completeness (any head node; fast, lists files only):

```bash
for L in Enamine_Hit_Locator_460K Coconut_715K Enamine_Liquid_Stock_2.5M Molport_Screening_Compounds_5.3M Enamine_Real_Sample_10.4M; do
  D=/fsx/output/$L/drugclip
  missing=$(for f in /fsx/input/$L/*_chunk_*.csv; do n=$(basename $f .csv | grep -oP '\d+$'); [ -f $D/${L}_drugclip_${n}.csv ] && [ -f $D/${L}_drugclip_${n}.h5 ] || printf "%s " $n; done)
  printf "%-34s chunks %5s | bisect dirs %s | missing: %s\n" $L "$(ls /fsx/input/$L/*_chunk_*.csv | wc -l)" "$(ls -d $D/bisect_* 2>/dev/null | wc -l)" "${missing:-none}"
done
```

Embedding audit, before calling a library done (opens every file: h5 fold masks and
per-fold norms, h5 vs SMILES index, encoded + skipped vs input, CSV row count and last line):

```bash
/shared/python39/bin/python3.9 /shared/scripts/drugclip_scripts/audit-drugclip-embeddings.py Coconut_715K Enamine_Liquid_Stock_2.5M Molport_Screening_Compounds_5.3M --since 2026-11-23
```

Last run 25 Nov: all chunks written since 23 Nov pass (Coconut 69/69, Liquid Stock 65/65,
Molport 5/5). Still to audit: Coconut `--chunks 000,017,029` once they finish. Hit Locator
and REAL predate the audit (checked only by the job's own norm test when written).

Screen progress:

```bash
squeue -j <job>; tail -f /shared/logs/drugclip-screen-<job>.out
```

Node health, when jobs stall (on the cluster that owns the queue):

```bash
sinfo -p cpu-queue -o "%T %D %E"        # or gpu-queue on the AL2023 cluster
sudo grep -iE "InsufficientInstanceCapacity|VcpuLimitExceeded|Failed to launch" /var/log/parallelcluster/slurm_resume.log | tail -5
```

Clusters: `ai2050cluster` (AL2, owns `cpu-queue`), `ai2050cluster-large` (AL2023, owns `gpu-queue`).
Both share `/fsx` and `/shared`.
