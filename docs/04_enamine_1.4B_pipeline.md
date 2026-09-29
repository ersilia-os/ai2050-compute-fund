# Enamine REAL 1.4B pipeline

## TL;DR

We ingested the Enamine REAL 1.4B sample (`2026.01_Enamine_REAL_DB_1.4B.cxsmiles.bz2`,
**1,364,304,490 molecules**) into 13,644 chunks of 100,000 molecules, and ran Ersilia's SMILES
standardization model (`eos4k4f_v1`) over all of them on the cluster. Standardization is
complete. Later steps (ID tagging, deduplication, promotion to the canonical input) are not
recorded here.

## Why a separate pipeline

The generic batch path submits one job per chunk and keeps every result on the cluster's
scratch filesystem. At this scale that breaks in two ways:

- **Scratch fills up.** FSx is 1.2 TB. Light outputs would fit, but fingerprints or embeddings
  for 1.4B molecules would not.
- **The scheduler floods.** ~14,000 chunks is far above Slurm's maximum array size of 1,000.

So the library is processed in **waves**: at most 1,000 chunks at a time. Each wave's results
are checked by row count, synced to S3, and then deleted from FSx before the next wave starts.
FSx never holds more than one wave, whatever the model's output size, and **S3 is the record of
what is done**. A rerun skips every chunk already in S3, so the pipeline can be restarted at any
point.

## Steps

| Step | What it does | Runs |
|---|---|---|
| 01 ingest | Streams the compressed file into 100k-molecule chunks, plus a sharded SMILES→vendor-ID map | locally |
| 1.5 standardize | Runs `eos4k4f_v1` in FSx-bounded waves; keeps the `standardized_smiles` column | cluster |
| 2a tag | Attaches the vendor ID to each standardized SMILES | cluster |
| 2b dedup | Removes duplicate standardized SMILES and builds the final SMILES→ID map | locally |
| promote | Archives the raw chunks and makes the deduplicated set the library's input | locally |

Scripts: [`scripts/library_processing/`](../scripts/library_processing/README.md) (ingest,
promote) and [`scripts/large_library_scripts/`](../scripts/large_library_scripts/README.md)
(waves, tagging, dedup), which also has the commands.

## Scale

- ~10 minutes per chunk, ~100 chunks running at once, ~1.9 hours per wave, 14 waves.
- Memory is not the limit for this model (~190 MB per job). Jobs are packed by CPU
  (`--cpus-per-task`), because the CPU queue does not account for memory.
- Wider models need smaller waves. The large-library README gives the sizing rule; roughly
  1,000 chunks per wave for light output, 30–40 for fingerprints or embeddings.

## Where things are

| S3 prefix (`s3://ai2050-ersilia-cluster/`) | Contents |
|---|---|
| `input/Enamine_Real_Sample_1.4B/` | input chunks |
| `smiles_ids/Enamine_Real_Sample_1.4B/` | SMILES→vendor-ID map, one gzip shard per chunk |
| `output/Enamine_Real_Sample_1.4B/<model>/` | model results |
| `tagged/Enamine_Real_Sample_1.4B/<model>/` | standardized SMILES with vendor IDs (step 2a) |
| `input/raw/Enamine_Real_Sample_1.4B/` | raw chunks, archived at promote |
