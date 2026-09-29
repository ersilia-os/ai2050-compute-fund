# Library processing

Scripts that turn vendor compound libraries into model-ready SMILES chunks, re-chunk them after
standardization, and debug the chunks that fail on the cluster. Chunks go to
`s3://ai2050-ersilia-cluster/input/<library>/`, which FSx imports as `/fsx/input/<library>/`.

## Source libraries

| Library | Source file | Version | Source | Molecules |
|---|---|---|---|---|
| `Enamine_Hit_Locator_460K` | `Enamine_Hit_Locator_Library_plated.zip` | not recorded | [Enamine Hit Locator Library](https://enamine.net/compound-libraries/diversity-libraries/hit-locator-library-460) | ~460K |
| `Enamine_Liquid_Stock_2.5M` | `Enamine_Liquid-Stock-Collection-US.zip` | not recorded ¹ | [Enamine screening collection](https://enamine.net/compound-collections/screening-collection) | ~2.5M |
| `Molport_Screening_Compounds_5.3M` | `Molport_Screening_Compound_Database.zip` | not recorded | Molport (download page not verified) | ~5.3M |
| `Coconut_715K` | `coconut_csv-02-2026.zip` | 02-2026 | [COCONUT downloads](https://coconut.naturalproducts.net/download) | ~715K |
| `Enamine_Real_Sample_10.4M` | `2025.02_Enamine_REAL_DB_10.4M.cxsmiles.bz2` | 2025.02 | [Enamine REAL Database](https://enamine.net/compound-collections/real-compounds/real-database) | ~10.4M |
| `Enamine_Real_Sample_1.4B` | `2026.01_Enamine_REAL_DB_1.4B.cxsmiles.bz2` | 2026.01 | [Enamine REAL Database](https://enamine.net/compound-collections/real-compounds/real-database) | 1,364,304,490 |

Download dates were not recorded for any file. Record the date here when a library is next
downloaded.

¹ Enamine lists the US Liquid Stock collection at ~3.2M compounds today, so the 2.5M file is an
older snapshot.

### Columns used per source

| Library | SMILES column | ID column | Format |
|---|---|---|---|
| Enamine Hit Locator | `SMILES` | `Catalog ID` | CSV with an Excel `sep=,` first line (skipped) |
| Enamine Liquid Stock | `SMILES` | `CatalogId` | CSV with an Excel `sep=,` first line (skipped) |
| Molport | `SMILES_CANONICAL` | `MOLPORTID` | ZIP of `.txt.gz` TSV shards, streamed |
| Coconut | `canonical_smiles` | `identifier` | CSV; long InChI fields need a 10 MB field limit |
| Enamine REAL | `smiles` | `id` | bz2 TSV (cxsmiles), streamed |

Columns are resolved case-insensitively.

## Scripts

Usage and arguments are in each script's docstring.

### 01_chemical_libraries_processing.py
Extracts SMILES and collection IDs from the five small and mid-size libraries above. Writes
SMILES-only chunks plus one full `<library>_smiles_ids.csv`.
**Chunk size:** 10,000 rows, numbered with 3 digits. REAL 10.4M produces ~1,040 chunks, so
numbers above 999 get a fourth digit and text order no longer matches numeric order.

### 01_large_library_processing.py
The billion-scale counterpart, for a single giant compressed file (REAL 1.4B). Streams without
decompressing to disk, writes atomically, and resumes after an interruption. The SMILES-to-ID
map is sharded one gzip per chunk under `smiles_ids/`.
**Chunk size:** 100,000 rows, numbered with 6 digits. That gives ~14,000 files instead of
~140,000 at 10k, which keeps `ls *.csv` globs under ARG_MAX and the SLURM array batches
(MaxArraySize 1,000) manageable.

### 02_prepare_standardized_inputs.py
After the standardization model (`eos4k4f_v1`) has run, rebuilds input chunks from its
`standardized_smiles` column and uploads them over `s3://…/input/<library>/`.
**Molecules dropped:** rows with an empty `standardized_smiles` (failed standardization) are
left out; the script reports retention per library. Move the original chunks to
`s3://…/input/raw/<library>/` by hand before running.

### 03_check_standardized_inputs.py
Checks that every standardized result chunk has a matching input chunk in S3, and counts
molecules whose result columns are all empty. The five small libraries are hard-coded.

### 04_download_and_merge_standardized_library.py
Downloads a library's chunks from S3 and concatenates them into one `<library>.csv`.
Chunks are merged in text order of their names, so a library with ≥1,000 three-digit chunks is
not merged in input order.

### 05_debug_failing_chunks.py
Finds the molecules that make a chunk fail, by bisecting the chunk and running each half through
a local `.sif` until single failing SMILES remain.
**Timeout:** 120 s per SMILES by default, scaled by batch size.

### 06_run_chunk_one_by_one.py
Runs a failing chunk through a local `.sif` one molecule at a time, with a checkpoint to resume
from. The output has the same rows as the input, with empty result columns where a molecule
failed, so it can replace the normal result file.
**Timeout:** 120 s per SMILES by default.

### prepare-h3d-selected-library.sh
Ingests an already standardized and deduplicated selection (a `key,input` gzip) as its own
library, through `01_large_library_processing.py`. Standardization, tagging and dedup are not
rerun.
**Chunk size:** 50,000 rows.

### promote-standardized-library.sh
Makes the deduplicated, standardized chunks the canonical input of a large library: archives the
raw chunks to `s3://…/input/raw/<library>/`, uploads the new ones, and verifies the counts. It
refuses to overwrite an existing archive. Run `dedup_and_map.py`
([`../large_library_scripts/`](../large_library_scripts/)) first.

## Order

- **Small libraries:** `01_chemical_libraries_processing.py` → standardize on the cluster →
  `02` → `03` → `04`. Use `05` and `06` on chunks that keep failing.
- **Large libraries:** `01_large_library_processing.py` → the wave pipeline in
  [`../large_library_scripts/`](../large_library_scripts/README.md) → `promote-standardized-library.sh`.
