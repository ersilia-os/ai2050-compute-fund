#!/usr/bin/env python3
"""
Chemical Database Processing Pipeline
======================================
Processes various chemical database files, extracts SMILES (+ collection ID),
and produces:
  1. <library_name>/<library_name>_chunk_NNN.csv   — SMILES only, 10K rows each
  2. <library_name>/<library_name>_smiles_ids.csv  — SMILES + collection ID (full)

Supported sources
-----------------
File                                              Library name
------------------------------------------------  ------------------------------------
Enamine_Hit_Locator_Library_plated.zip            Enamine_Hit_Locator_460K
Enamine_Liquid-Stock-Collection-US.zip            Enamine_Liquid_Stock_2.5M
Molport_Screening_Compound_Database.zip           Molport_Screening_Compounds_5.3M
coconut_csv-02-2026.zip                           Coconut_715K
2025.02_Enamine_REAL_DB_10.4M.cxsmiles.bz2        Enamine_Real_Sample_10.4M

Format notes (from file inspection)
-------------------------------------
Enamine Hit Locator  : TSV (.smiles)  →  SMILES | Catalog ID | ...
Enamine Liquid Stock : TSV (.smiles)  →  SMILES | CatalogId  | ...
Molport              : ZIP of .txt.gz shards, each TSV:
                         SMILES  SMILES_CANONICAL  MOLPORTID
                       → use SMILES_CANONICAL as canonical SMILES
Coconut              : CSV (.csv)     →  identifier | canonical_smiles | ...
Enamine REAL         : BZ2 TSV       →  smiles | id | ...

Usage
-----
  python process_chemical_libraries.py [--input-dir DIR] [--output-dir DIR] [--files FILE ...]

  Defaults: --input-dir .   --output-dir ./output
"""

import bz2
import csv
import gzip
import io
import logging
import argparse
import sys
import zipfile
from pathlib import Path

# Raise CSV field size limit — needed for Coconut which has very long InChI/SMILES fields
csv.field_size_limit(10 * 1024 * 1024)  # 10 MB per field

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CHUNK_SIZE = 10_000

LIBRARY_CONFIG = {
    "Enamine_Hit_Locator_Library_plated.zip": {
        "library_name": "Enamine_Hit_Locator_460K",
        "format":       "enamine_zip",
    },
    "Enamine_Liquid-Stock-Collection-US.zip": {
        "library_name": "Enamine_Liquid_Stock_2.5M",
        "format":       "enamine_zip",
    },
    "Molport_Screening_Compound_Database.zip": {
        "library_name": "Molport_Screening_Compounds_5.3M",
        "format":       "molport_zip",
    },
    "coconut_csv-02-2026.zip": {
        "library_name": "Coconut_715K",
        "format":       "coconut_zip",
    },
    "2025.02_Enamine_REAL_DB_10.4M.cxsmiles.bz2": {
        "library_name": "Enamine_Real_Sample_10.4M",
        "format":       "enamine_real_bz2",
    },
}

# (smiles_column, id_column, delimiter)
FORMAT_COLS = {
    "enamine_zip":       ("SMILES",           "Catalog ID",  ","),
    # Liquid Stock uses the same format entry but different ID col — handled via override below
    "enamine_liquid_zip": ("SMILES",           "CatalogId",   ","),
    "molport_zip":       ("SMILES_CANONICAL",  "MOLPORTID",   "\t"),
    "coconut_zip":       ("canonical_smiles",  "identifier",  ","),
    "enamine_real_bz2":  ("smiles",            "id",          "\t"),
}

# Per-file column overrides (when two files share the same format key but differ in ID col)
FILE_COL_OVERRIDES = {
    "Enamine_Liquid-Stock-Collection-US.zip": ("SMILES", "CatalogId", ","),
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Generic row iterator
# ---------------------------------------------------------------------------

def iter_rows(text_stream, smiles_col: str, id_col: str, delimiter: str):
    """Yield (smiles, compound_id) from a CSV/TSV text stream."""

    # Skip Excel-style 'sep=,' / 'sep=\t' directive emitted by some tools
    first_line = text_stream.readline()
    if first_line.strip().lower().startswith("sep="):
        log.info(f"    Skipping Excel sep= line: {first_line.strip()!r}")
    else:
        # Not a sep line — reconstruct stream with it prepended
        text_stream = io.StringIO(first_line + text_stream.read())

    reader = csv.DictReader(text_stream, delimiter=delimiter)

    # Force header read
    try:
        fields = reader.fieldnames or []
    except Exception as e:
        log.error(f"    Could not read header: {e}")
        return

    # Case-insensitive column resolution
    fields_norm = [f.strip() for f in fields]
    fields_lower = [f.lower() for f in fields_norm]

    def resolve(col_name):
        # exact
        if col_name in fields_norm:
            return col_name
        # case-insensitive
        low = col_name.lower()
        if low in fields_lower:
            return fields_norm[fields_lower.index(low)]
        return None

    smi_field = resolve(smiles_col)
    id_field  = resolve(id_col)

    if smi_field is None:
        log.error(f"    SMILES column '{smiles_col}' not found. Header: {fields_norm[:8]}")
        return
    if id_field is None:
        log.warning(f"    ID column '{id_col}' not found; IDs will be empty. Header: {fields_norm[:8]}")

    log.info(f"    Columns → smiles='{smi_field}'  id='{id_field or 'N/A'}'")

    for row in reader:
        smi = row.get(smi_field, "").strip()
        cid = row.get(id_field,  "").strip() if id_field else ""
        if smi:
            yield smi, cid


# ---------------------------------------------------------------------------
# Format-specific openers
# ---------------------------------------------------------------------------

def iter_enamine_zip(zip_path: Path, smiles_col, id_col, delimiter):
    """Single .smiles (TSV) file inside a zip archive."""
    EXTS = {".smiles", ".smi", ".csv", ".tsv", ".txt"}
    with zipfile.ZipFile(zip_path) as zf:
        candidates = [
            n for n in zf.namelist()
            if not n.startswith("__MACOSX") and not n.endswith("/")
            and Path(n).suffix.lower() in EXTS
        ]
        if not candidates:
            log.error(f"  No data file found inside {zip_path.name}")
            return
        # Prefer largest file
        candidates.sort(key=lambda n: zf.getinfo(n).file_size, reverse=True)
        chosen = candidates[0]
        log.info(f"  Inner file: {chosen}  ({zf.getinfo(chosen).file_size:,} bytes)")
        raw  = zf.read(chosen).decode("utf-8", errors="replace")
        yield from iter_rows(io.StringIO(raw), smiles_col, id_col, delimiter)


def iter_molport_zip(zip_path: Path, smiles_col, id_col, delimiter):
    """
    Molport ZIP: sub-folder full of .txt.gz shards.
    Each shard is a TSV: SMILES  SMILES_CANONICAL  MOLPORTID
    """
    with zipfile.ZipFile(zip_path) as zf:
        gz_files = sorted([
            n for n in zf.namelist()
            if not n.startswith("__MACOSX") and n.endswith(".txt.gz")
        ])
        if not gz_files:
            log.error(f"  No .txt.gz shards found inside {zip_path.name}")
            return
        log.info(f"  Found {len(gz_files)} .txt.gz shard(s)")
        for gz_name in gz_files:
            log.info(f"    Shard: {Path(gz_name).name}")
            gz_bytes = zf.read(gz_name)
            with gzip.open(io.BytesIO(gz_bytes), "rt", encoding="utf-8", errors="replace") as f:
                yield from iter_rows(f, smiles_col, id_col, delimiter)


def iter_coconut_zip(zip_path: Path, smiles_col, id_col, delimiter):
    """Coconut: single large CSV inside a zip."""
    with zipfile.ZipFile(zip_path) as zf:
        candidates = [
            n for n in zf.namelist()
            if not n.startswith("__MACOSX") and not n.endswith("/")
            and Path(n).suffix.lower() in {".csv", ".tsv", ".txt"}
        ]
        if not candidates:
            log.error(f"  No CSV found inside {zip_path.name}")
            return
        candidates.sort(key=lambda n: zf.getinfo(n).file_size, reverse=True)
        chosen = candidates[0]
        log.info(f"  Inner file: {chosen}  ({zf.getinfo(chosen).file_size:,} bytes)")
        raw  = zf.read(chosen).decode("utf-8", errors="replace")
        yield from iter_rows(io.StringIO(raw), smiles_col, id_col, delimiter)


def iter_enamine_real_bz2(bz2_path: Path, smiles_col, id_col, delimiter):
    """Enamine REAL: bz2-compressed TSV, streamed to avoid loading into RAM."""
    log.info("  Streaming bz2 — this may take several minutes for 10M rows ...")
    with bz2.open(bz2_path, "rt", encoding="utf-8", errors="replace") as f:
        yield from iter_rows(f, smiles_col, id_col, delimiter)


FORMAT_ITER = {
    "enamine_zip":      iter_enamine_zip,
    "molport_zip":      iter_molport_zip,
    "coconut_zip":      iter_coconut_zip,
    "enamine_real_bz2": iter_enamine_real_bz2,
}


# ---------------------------------------------------------------------------
# Writer — chunks + full smiles+ID file
# ---------------------------------------------------------------------------

def write_output(row_iter, library_name: str, output_dir: Path) -> int:
    """
    Consume (smiles, id) and write:
      - chunk CSVs  (smiles only, CHUNK_SIZE rows each)
      - one full CSV with smiles + collection_id
    Returns total row count.
    """
    output_dir.mkdir(parents=True, exist_ok=True)

    smiles_id_path = output_dir / f"{library_name}_smiles_ids.csv"

    with open(smiles_id_path, "w", newline="", encoding="utf-8") as id_fh:
        id_writer = csv.writer(id_fh)
        id_writer.writerow(["smiles", "collection_id"])

        chunk_idx = 0
        chunk_buf = []
        total     = 0

        def flush_chunk(buf, idx):
            p = output_dir / f"{library_name}_chunk_{idx:03d}.csv"
            with open(p, "w", newline="", encoding="utf-8") as cf:
                w = csv.writer(cf)
                w.writerow(["smiles"])
                w.writerows([[s] for s in buf])
            log.info(f"  Chunk {idx:03d} → {p.name}  ({len(buf):,} rows)")

        for smi, cid in row_iter:
            id_writer.writerow([smi, cid])
            chunk_buf.append(smi)
            total += 1

            if len(chunk_buf) == CHUNK_SIZE:
                flush_chunk(chunk_buf, chunk_idx)
                chunk_idx += 1
                chunk_buf = []

            if total % 500_000 == 0:
                log.info(f"  ... {total:,} rows processed")

        if chunk_buf:
            flush_chunk(chunk_buf, chunk_idx)

    n_chunks = -(-total // CHUNK_SIZE)  # ceiling division
    log.info(f"  Full SMILES+ID → {smiles_id_path.name}  ({total:,} rows)")
    log.info(f"  ✓ {total:,} SMILES written in {n_chunks} chunk file(s)")
    return total


# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------

def process_library(input_path: Path, fname: str, config: dict, output_dir: Path) -> int:
    library_name = config["library_name"]
    fmt          = config["format"]

    # Resolve column config (with per-file override)
    if fname in FILE_COL_OVERRIDES:
        smiles_col, id_col, delimiter = FILE_COL_OVERRIDES[fname]
    else:
        smiles_col, id_col, delimiter = FORMAT_COLS[fmt]

    lib_out = output_dir / library_name

    log.info(f"\n{'='*65}")
    log.info(f"File    : {input_path.name}")
    log.info(f"Library : {library_name}")
    log.info(f"Format  : {fmt}")
    log.info(f"Output  : {lib_out}")

    if not input_path.exists():
        log.error(f"  ✗ File not found: {input_path}")
        return 0

    iter_fn  = FORMAT_ITER[fmt]
    row_iter = iter_fn(input_path, smiles_col, id_col, delimiter)
    return write_output(row_iter, library_name, lib_out)


def main():
    parser = argparse.ArgumentParser(description="Chemical database SMILES extraction pipeline")
    parser.add_argument("--input-dir",  default=".",        help="Directory containing raw files")
    parser.add_argument("--output-dir", default="./output", help="Root output directory")
    parser.add_argument("--files", nargs="*",               help="Subset of filenames to process")
    args = parser.parse_args()

    input_dir  = Path(args.input_dir)
    output_dir = Path(args.output_dir)

    files_to_process = args.files or list(LIBRARY_CONFIG.keys())

    summary = []
    for fname in files_to_process:
        if fname not in LIBRARY_CONFIG:
            log.warning(f"No config for '{fname}' — skipping.")
            continue
        config = LIBRARY_CONFIG[fname]
        total  = process_library(input_dir / fname, fname, config, output_dir)
        chunks = -(-total // CHUNK_SIZE)
        summary.append((config["library_name"], total, chunks))

    # ---- Final summary table ----
    log.info(f"\n{'='*65}")
    log.info("FINAL SUMMARY")
    log.info(f"{'='*65}")
    for lib, total, chunks in summary:
        log.info(f"  {lib:<42}  {total:>10,} SMILES   {chunks:>5} chunks")
    log.info(f"{'='*65}")


if __name__ == "__main__":
    main()