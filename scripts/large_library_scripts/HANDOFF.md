# Session handoff — Enamine REAL 1.4B pipeline

_Last updated: 2026-07-21. Read this first to resume context._

## TL;DR
We built and launched a billion-scale processing pipeline for **Enamine_Real_Sample_1.4B**
(1,364,304,490 molecules, 13,644 chunks of 100k). **Standardization (`eos4k4f_v1`) is
in its final stretch** via the wave orchestrator (`tmux` session `waves`, head node).
As of the last check: **~12,000 / 13,644 chunks done (waves 1–12)**, ~1h43m/wave, 0 failures.
Hit a wave-boundary hang after wave 12 (orchestrator bug #3, now fixed) — resumed for the
final ~1,644 chunks (waves 13–14). Should finish within a couple of hours of resume.
**If it's not done when you reconnect,** just re-run the launch cmd below (resumable).

## Pipeline (all scripts in this folder; cluster copies at `/shared/scripts/large_library_scripts/`)
Order: **01 ingest → 1.5 standardize (waves) → 2a tag ids → 2b dedup+map → promote**

| Step | Script | Where | Status |
|------|--------|-------|--------|
| 01 | `01_large_library_processing.py` | local | ✅ DONE |
| 1.5 | `submit-ersilia-waves.sh` + `run-ersilia-wave-job.sh` | cluster | ⏳ ~12000/13644 (final waves 13–14) |
| 2a | `submit-tag-ids.sh` + `run-tag-ids-job.sh` + `join_ids.py` | cluster | ⬜ not started |
| 2b | `dedup_and_map.py` | local | ⬜ not started |
| promote | `promote-standardized-library.sh` | local | ⬜ not started |
| repair | `submit-missing-bisect-large.sh` | cluster | ⬜ only if failures |

## Current state (as of 2026-07-21)
- **Ingest done:** 13,644 chunks in `s3://ai2050-ersilia-cluster/input/Enamine_Real_Sample_1.4B/`;
  gzip id-map shards in `s3://ai2050-ersilia-cluster/smiles_ids/Enamine_Real_Sample_1.4B/`.
  Local copy: `~/enamine_1.4B/` (~87 GB, redundant with S3 — deletable once comfortable).
- **Standardization running** in `tmux attach -t waves` on the head node. Launch cmd:
  ```
  S3_BUCKET=ai2050-ersilia-cluster /shared/scripts/large_library_scripts/submit-ersilia-waves.sh \
    eos4k4f_v1 Enamine_Real_Sample_1.4B 1000 cpu-queue
  ```
  Resumable — if it dies, re-run the exact same command (skips chunks already in S3).
- **Timing:** ~10 min/chunk, ~100 concurrent, ~1.9 h/wave (submit→submit), 14 waves.

### Check progress next session
```
aws s3 ls s3://ai2050-ersilia-cluster/output/Enamine_Real_Sample_1.4B/eos4k4f_v1/ | grep -c _results_   # target 13644
tmux attach -t waves                                                                                     # live orchestrator log
ls -la --time-style=full-iso /fsx/output/Enamine_Real_Sample_1.4B/eos4k4f_v1/_wave_work/wave_*.txt       # per-wave timing
cat /fsx/output/Enamine_Real_Sample_1.4B/eos4k4f_v1/_failed_chunks.txt 2>/dev/null                       # persistent failures (ideally empty)
```

## PENDING DECISION — job packing (not applied)
Measured on live nodes: **RAM is a non-issue** for `eos4k4f_v1` — ~190 MB/job, ~1 GB total for
4 jobs on a 61 GB node. Currently the **deployed** worker uses `--cpus-per-task=8` (4 jobs/node,
~100 concurrent). Since RAM is free, we can pack more; the limit is CPU (cores/job).
- **Still need:** `ssh <node> uptime` — load ≈ 4 on a 32-core node with 4 jobs ⇒ ~1 core/job.
- If ~1 core/job: **`cpus-per-task=2`** → 16 jobs/node, ~400 concurrent, remaining ~6 h (recommended,
  1 spare core/job); or `=1` → 32/node, ~3 h (aggressive).
- Apply by editing `--cpus-per-task` in `run-ersilia-wave-job.sh`, redeploy, effective next wave.
- NOTE: repo file currently says `cpus-per-task=10`; **deployed cluster copy is `8`** (drift). The
  edit to `2` was proposed but **NOT applied** (user deferred). Keep higher values (8–10) for future
  heavy descriptor/fingerprint models — this light setting is standardization-specific.

## Next steps after standardization finishes (all 13,644 in S3)
1. **If `_failed_chunks.txt` non-empty:** re-run the wave orchestrator (mops transient failures),
   then `submit-missing-bisect-large.sh eos4k4f_v1 Enamine_Real_Sample_1.4B` for poison chunks.
   (Wave 1 had 0 failures, so likely clean.) **Do bisect BEFORE promote** — it reads raw input from
   `/fsx/input/<lib>/`.
2. **Tag (2a):** deploy the 3 tag scripts if not already, then
   `S3_BUCKET=ai2050-ersilia-cluster /shared/scripts/large_library_scripts/submit-tag-ids.sh eos4k4f_v1 Enamine_Real_Sample_1.4B`
   → writes `s3://…/tagged/Enamine_Real_Sample_1.4B/eos4k4f_v1/` (standardized_smiles,collection_id).
3. **Dedup + map (2b, local):**
   `python3 dedup_and_map.py --library-name Enamine_Real_Sample_1.4B --model-id eos4k4f_v1 --dedup-library-name Enamine_Real_Sample_1.4B`
   → local `./dedup_work/dedup_chunks/` (100k, single `smiles` col) + `..._smiles_ids_dedup.csv.gz` (final map).
   Needs ~150–175 GB scratch. Do NOT `--upload-chunks-s3` (promote handles it).
4. **Promote (local):** `bash promote-standardized-library.sh Enamine_Real_Sample_1.4B ./dedup_work/dedup_chunks`
   → archives raw to `input/raw/Enamine_Real_Sample_1.4B/`, puts deduped set at `input/Enamine_Real_Sample_1.4B/`.
   Then on head node: `rm -rf /fsx/input/Enamine_Real_Sample_1.4B/*` (FSx is NEW_CHANGED, no delete propagation).

## Bugs fixed this session (in `submit-ersilia-waves.sh`)
Wave-completion detection needed **three** fixes (remaining-calc + `submit_and_wait` wait loop):
1. **"Nothing to do" on fresh run** — awk `NR==FNR` fails when the done-file is empty; fixed with an
   `if [ -s "$DONE" ]` branch.
2. **Premature wave completion → duplicate resubmit** — a single transient empty `squeue` ended the
   wait early; fixed to require **3 consecutive empty polls**.
3. **Hang at wave boundary → next wave never starts** — when an array completes, SLURM (accounting
   disabled) purges it, so `squeue -j <id>` returns "Invalid job id" (rc≠0). The #2 fix had treated
   ALL squeue errors as "still active" → infinite wait. Now: rc==0 & empty = done; rc≠0 with
   "invalid job id" = done (purged); other rc≠0 = transient → keep waiting.
   **Symptom:** results all in S3 but `/fsx` not evicted and no `Wave N done` line printed.
All fixed in the repo copy. **Redeploy `submit-ersilia-waves.sh` to
`/shared/scripts/large_library_scripts/` after each fix** — the deployed copy is what runs. Verify:
`grep -A12 'Robust wait' /shared/scripts/large_library_scripts/submit-ersilia-waves.sh`.

## Key facts / environment
- **`eos4k4f_v1` output = 7 cols:** `key, input, canonical_smiles, standardized_smiles,
  flattened_smiles, murcko_scaffold, generic_scaffold`. We keep **`standardized_smiles`** (col 4);
  `join_ids.py`/`dedup` select it by name. `input` (col 2, raw SMILES) is used to verify row alignment.
- **Cluster:** `cpu-queue` is **CR_CPU** (no memory accounting → `cpus-per-task` is the only packing
  lever). Nodes 32 vCPU; c6i/c7i/c5a = 61 GB, m6i = 128 GB. Max 25 nodes, Spot.
- **FSx** = 1.2 TB scratch, `AutoImportPolicy: NEW_CHANGED` (imports new/changed from S3 input/,
  does NOT delete). Wave orchestrator keeps `/fsx` bounded by evicting each wave after S3 sync.
- **S3 layout:** `input/<lib>/`, `smiles_ids/<lib>/`, `output/<lib>/<model>/`, `tagged/<lib>/<model>/`,
  `input/raw/<lib>/` (post-promote archive).
- **Deploy** cluster-side scripts:
  `aws s3 sync <repo>/scripts/large_library_scripts/ s3://ai2050-ersilia-cluster/scripts/large_library_scripts/ --exclude "__pycache__/*" --exclude "*.pyc"`
  then on head node sync into `/shared/scripts/large_library_scripts/` and `chmod +x *.sh`.

## Separate, non-blocking: small-library upload gaps
`verify-fsx-in-s3.sh` surfaced older results that are on `/fsx` but were never uploaded to S3
(bisect/resubmit jobs that lacked `S3_BUCKET`). Genuine gaps found: `eos3l5f_v1` (713, 732),
`eos4u6p_v1` Molport (13), `eos5axz_v2` (2), `eos8aa5_v1` (12), `eos4ex3_v1` (~33 + partials).
Fix = validate row count then `aws s3 cp` on the head node (or resubmit partials). Unrelated to the
1.4B run; do whenever.
