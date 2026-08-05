# Large Library Processing (billion-scale)

Dedicated pipeline for ingesting a **single, very large compressed library file**
(built for the ~**1.41 billion** molecule Enamine REAL sample — ~135× the 10.4M
sample). It mirrors the top-level `scripts/01–03` pipeline but is re-engineered so
a billion rows are actually processable. The original `scripts/01–03` are left
untouched and still handle the five smaller libraries.

| Step | Script | Role |
|------|--------|------|
| 01 | `01_large_library_processing.py` | Stream the giant file → 100k-row SMILES chunks + sharded gzip raw-SMILES→ID map |
| 1.5 | `submit-ersilia-waves.sh` + `run-ersilia-wave-job.sh` | Run the standardization model over all ~14,100 chunks in FSx-bounded waves; results → S3 |
| 2a | `submit-tag-ids.sh` + `run-tag-ids-job.sh` + `join_ids.py` | **On cluster**: re-attach the collection id to each standardized SMILES → gzip *tagged* shards in S3 |
| 2b | `dedup_and_map.py` | **Local**: dedup standardized SMILES (keep first) → **final `standardized_smiles→id` map** + deduped input chunks |
| 01b | `prepare-h3d-selected-library.sh` | Ingest a *selected* subset (`key,input` gzip) as its own library — step 01 only, no restandardization |

The end-to-end path is **01 → 1.5 (standardize) → 2a (tag) → 2b (dedup + map)**, then
run downstream models on the deduplicated set. Standardization runs via the **wave
orchestrator** (step 1.5) rather than the generic `submit-ersilia-batch.sh`, because at
~14,100 chunks the generic path floods the scheduler and lets `/fsx/output` accumulate
past the 1.2 TB limit.

### Why the id map is a downstream product

The standardization model **strips the collection id** (its output is
`key,input,standardized_smiles`). The id only survives in step 01's per-chunk id shard,
which is **row-aligned** with the raw chunk — and therefore with the model result for
that chunk. So the id is re-attached by a **positional join** (result row *i* ↔ id-shard
row *i*, cross-checked on the raw SMILES), done **before** dedup so the id rides through
it. The deduplicated `standardized_smiles,collection_id` set *is* the final map.

## Why a separate pipeline?

Scaling 10.4M → 1.41B breaks several assumptions in the original scripts:

| Problem at 1.41B | Fix here |
|------------------|----------|
| 10k/chunk → **141,000 files** in one dir (breaks `ls *.csv` globs, floods SLURM) | **100k/chunk → ~14,100 files**; keeps `ls` under ARG_MAX and array-job batching at ~15 |
| Single `_smiles_ids.csv` ≈ **150 GB** | **Sharded gzip** map, one shard per chunk, in a separate `smiles_ids/` subdir |
| `csv.DictReader` over 1.41B rows is slow | **Fast manual TSV split** in the hot loop (columns resolved once from the header) |
| A multi-hour run that dies restarts from zero | **Atomic writes + resume**: committed chunks are skipped, the stream fast-forwards |
| Thousands of per-chunk `aws s3 cp` uploads | **One `aws s3 sync`** (dedup chunk upload; tagged shards) |
| Per-chunk downloads just to compare/verify | **`aws s3 ls` set comparison** (tag-step resume, wave verify) |
| 3-digit chunk numbers (`%03d`) sort wrong past 999 | **6-digit zero-padded** (`%06d`) — lexical and numeric sort agree |

## Cluster constraints to respect

- **FSx Lustre is only 1.2 TB scratch** (`AWS_templates/cluster-config.yaml`). 1.41B
  SMILES-only chunks are ~60–70 GB, which fits; **model outputs with fingerprints
  or embeddings will not** — process in waves and export results to S3, or grow FSx.
- **SLURM `MaxArraySize = 1000`** — the existing `submit-ersilia-batch.sh` already
  batches in groups of 1000; ~14,100 chunks ≈ 15 batches.
- **cpu-queue max 25 nodes**, Spot. For slow models use
  `AWS_templates/split-ersilia-library.sh`, which sub-splits each chunk, throttles
  submission (`MAX_PENDING`), and skips already-complete chunks by row count.

## Step 01 — ingest the giant file

Runs wherever the raw file lives (local box or head node). Streams the file, never
loads it into RAM, never fully decompresses to disk.

```bash
python 01_large_library_processing.py \
  --input  /path/2026.01_Enamine_REAL_DB_1.4B.cxsmiles.bz2 \
  --output-dir ./output \
  --library-name Enamine_Real_Sample_1.4B \
  --upload-s3       s3://ai2050-ersilia-cluster/input/Enamine_Real_Sample_1.4B/ \
  --upload-idmap-s3 s3://ai2050-ersilia-cluster/smiles_ids/Enamine_Real_Sample_1.4B/
```

- `--upload-s3` syncs the **chunk CSVs** to the S3 *input* prefix (FSx auto-imports).
- `--upload-idmap-s3` syncs the **gzip id-map shards** to a separate `smiles_ids/`
  prefix — **required** for on-cluster tagging (step 2a). The two never share a prefix,
  so id shards are never mistaken for model input.

Handy flags: `--limit N` (smoke-test on the first N molecules — use a throwaway
`--output-dir`), `--no-id-map`, `--chunk-size`, `--smiles-col/--id-col/--delimiter`
(defaults `smiles` / `id` / tab match the Enamine `.cxsmiles` format).
**Re-running the same command resumes** from the last committed chunk.

Output layout:

```
output/Enamine_Real_Sample_1.4B/
├── Enamine_Real_Sample_1.4B_chunk_000000.csv      # smiles only, 100k rows
├── ...  (~14,100 files)
├── smiles_ids/
│   └── Enamine_Real_Sample_1.4B_smiles_ids_000000.csv.gz   # raw smiles,collection_id
└── _manifest.json
```

Decompression prefers `lbzip2`/`pbzip2` (parallel) then `bzip2`, falling back to
Python `bz2`. Installing `lbzip2` on the ingest box is the single biggest speedup
for a `.bz2` source — worth doing before a full run.

## Step 1.5 — run the model in FSx-bounded waves

`submit-ersilia-waves.sh` runs any Ersilia model over the whole library while keeping
FSx bounded and treating S3 as the durable store. It builds the chunk manifest from
`aws s3 ls` (no `ls *.csv` ARG_MAX risk), **skips chunks already in S3** (resumable),
and processes the ~14,100 chunks in **sequential waves of ≤1000** (SLURM's
`MaxArraySize`). Per wave it: submits one array job → waits → verifies row counts
(+one resubmit of failures) → `aws s3 sync` (safety net) → **`rm`s the wave's outputs
from `/fsx`**. So `/fsx/output` never holds more than one wave.

Deploy both scripts to the head node once (they are dedicated; the generic
`/shared/scripts/*` are untouched):

```bash
# from your machine
aws s3 cp scripts/large_library_scripts/submit-ersilia-waves.sh  s3://ai2050-ersilia-cluster/scripts/
aws s3 cp scripts/large_library_scripts/run-ersilia-wave-job.sh  s3://ai2050-ersilia-cluster/scripts/
# on the head node
aws s3 cp s3://ai2050-ersilia-cluster/scripts/submit-ersilia-waves.sh  /shared/scripts/ && chmod +x /shared/scripts/submit-ersilia-waves.sh
aws s3 cp s3://ai2050-ersilia-cluster/scripts/run-ersilia-wave-job.sh  /shared/scripts/ && chmod +x /shared/scripts/run-ersilia-wave-job.sh
```

Run it inside `tmux` (a full 1.41B pass can take days; the orchestrator babysits the
whole run):

```bash
tmux new -s waves
S3_BUCKET=ai2050-ersilia-cluster \
  /shared/scripts/submit-ersilia-waves.sh eos4k4f_v1 Enamine_Real_Sample_1.4B 1000 cpu-queue
# detach: Ctrl-b d   |   reattach: tmux attach -t waves
# watch FSx stay bounded: watch -n 30 'df -h /fsx; du -sh /fsx/output'
```

**Resume**: just re-run the same command — done chunks (already in S3) are skipped.

**Wave sizing** (`wave_size`, the 3rd arg) must keep one wave's output inside FSx:
`wave_size ≈ 0.6 × FSx_free_GB / (0.1M × bytes_per_output_row / 1e9)`.
- Standardization (~80 B/row): **1000** (≈8 GB/wave) — the default.
- 2048-bit fingerprint (~20 KB/row, ~2 GB/chunk): **~30–40**.
The orchestrator samples the first wave's output and warns if a wave risks >60% of
free FSx.

**Persistent per-chunk failures** are logged to
`/fsx/output/<lib>/<model>/_failed_chunks.txt` (one bad molecule never blocks the run);
isolate them afterwards with `AWS_templates/split-ersilia-chunk.sh`.

## Step 2a — tag ids on the cluster

Re-attaches the collection id to each standardized SMILES, per chunk, and writes
compact gzip *tagged* shards (`standardized_smiles,collection_id`) to
`s3://<bucket>/tagged/<lib>/<model>/`. Runs on the cluster (S3 in → `/tmp` → S3 out,
so **`/fsx` is untouched**). Because the join is cheap, each array task does many
chunks. Deploy the three files once, then run on the head node:

```bash
# deploy (from your machine)
for f in submit-tag-ids.sh run-tag-ids-job.sh join_ids.py; do
  aws s3 cp scripts/large_library_scripts/$f s3://ai2050-ersilia-cluster/scripts/; done
# on the head node
for f in submit-tag-ids.sh run-tag-ids-job.sh join_ids.py; do
  aws s3 cp s3://ai2050-ersilia-cluster/scripts/$f /shared/scripts/ && chmod +x /shared/scripts/$f; done

# run (needs the id shards in S3 from step 01's --upload-idmap-s3)
S3_BUCKET=ai2050-ersilia-cluster \
  /shared/scripts/submit-tag-ids.sh eos4k4f_v1 Enamine_Real_Sample_1.4B
```

`join_ids.py` **verifies** `result.input == idshard.smiles` per row and fails loudly if
the positional alignment ever breaks (so a wrong map can't be produced silently).
Resumable — re-run to fill any gaps.

## Step 2b — deduplicate + build the final map (local)

```bash
python3 dedup_and_map.py \
  --library-name Enamine_Real_Sample_1.4B --model-id eos4k4f_v1 \
  --upload-chunks-s3 s3://ai2050-ersilia-cluster/input/Enamine_Real_Sample_1.4B_std/
```

Downloads the tagged shards (~30 GB gz), deduplicates standardized SMILES **keeping the
first appearance** (hash-sharded → memory-bounded at 1.4B), and writes:

- `dedup_work/Enamine_Real_Sample_1.4B_smiles_ids_dedup.csv.gz` — the **final
  `standardized_smiles,collection_id` map**, from the deduplicated set;
- `dedup_work/dedup_chunks/<lib>_std_chunk_NNNNNN.csv` — deduped SMILES-only chunks,
  optionally synced to S3 as a new input library (`<lib>_std`) for downstream models.

Tune with `--buckets` (RAM vs open files) and `--chunk-size`; `--no-download` if the
tagged shards are already local. Downstream models then run via the wave orchestrator on
library `Enamine_Real_Sample_1.4B_std`.

## Step 01b — ingest a *selected* subset as a new library

`prepare-h3d-selected-library.sh` turns a single gzip file of already-selected,
already-standardized molecules into a normal input library. It is **step 01 only** —
the molecules came out of the standardized+deduped 1.4B set, so steps 1.5 / 2a / 2b are
**not** rerun; the id map is written directly, row-aligned per chunk.

Input schema: two columns, `key` (32-char hex molecule key → stored as `collection_id`)
and `input` (standardized SMILES → the chunk `smiles`). Delimiter is auto-detected from
the header; the run aborts early if the header can't be read.

```bash
# smoke test first (throwaway output dir, no upload, works on a partial download)
LIMIT=200000 ./prepare-h3d-selected-library.sh ~/h3d_selected_100M.csv.gz ./smoke

# full run — 100M @ 50k/chunk = ~2,000 chunks, uploads chunks + id shards to S3
./prepare-h3d-selected-library.sh ~/h3d_selected_100M.csv.gz ./output
```

Defaults: `LIB=Enamine_Real_h3d_selected`, `CHUNK_SIZE=50000`. Override any of
`LIB CHUNK_SIZE S3_BUCKET SMILES_COL ID_COL DELIM LIMIT NO_UPLOAD` via env.
A full run first does `gzip -t` (guards against ingesting a still-downloading file);
skip with `SKIP_INTEGRITY_CHECK=1`. Re-running the same command **resumes**.

**Wave sizing differs here**: chunks are 50k rows, half the 100k used for the 1.4B
library, so a given wave holds half the output — the sizing formula in step 1.5 can be
read with `0.05M` instead of `0.1M` rows/chunk.

To map results back to the original Enamine catalogue ids, join this library's
`collection_id` (the hex key) against the 1.4B final map
(`Enamine_Real_Sample_1.4B_smiles_ids_dedup.csv.gz`) on the standardized SMILES.

## Notes / assumptions

- Assumes the 1.4B file has the same schema as the 10.4M sample: a tab-separated
  `.cxsmiles` with `smiles` (col 0) and `id` (col 1). Override with
  `--smiles-col/--id-col/--delimiter` if it differs.
- Keep `--library-name` identical across steps 01, 1.5, 2a, 2b.
- Positional-alignment assumption (result row *i* ↔ id-shard row *i*) is the same 1:1
  row invariant `check-results.sh` already relies on; `join_ids.py` cross-checks it.
