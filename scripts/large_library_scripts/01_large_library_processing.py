#!/usr/bin/env python3
"""
Large single-file chemical library processing (billion-scale).
==============================================================
Dedicated ingestion step for a VERY large single compressed library file
(e.g. the 1.41B-molecule Enamine REAL sample), sized ~135x the 10.4M sample.

It is the billion-scale counterpart of ../01_chemical_libraries_processing.py.
The original script is left untouched and still handles the 5 smaller libraries.

What it does
------------
Streams one giant compressed TSV (never loaded into RAM, never fully
decompressed to disk) and writes, for a chosen library:

  <output-dir>/<library>/<library>_chunk_NNNNNN.csv          SMILES-only, CHUNK_SIZE rows
  <output-dir>/<library>/smiles_ids/<library>_smiles_ids_NNNNNN.csv.gz
                                                              smiles + collection_id (gzip), one per chunk

Design choices for billion-scale (see large_library_scripts/README.md)
----------------------------------------------------------------------
  * Streaming decompression. Prefers an external decompressor (lbzip2 / pbzip2
    / bzip2 for .bz2; pigz / gzip for .gz) piped via subprocess so decompression
    runs in C in its own process; falls back to Python's bz2 / gzip module.
  * Fast TSV parsing. The Enamine cxsmiles TSV has no embedded tabs/quotes in the
    smiles/id fields, so the hot loop uses str.split(delimiter) instead of
    csv.DictReader (several times faster over 1.41B rows).
  * 100k rows/chunk by default -> ~14,100 files (vs ~141,000 at 10k). Keeps the
    file count under ARG_MAX for the cluster submit scripts' `ls *.csv` globs and
    the SLURM MaxArraySize=1000 batching manageable (~15 array batches).
  * 6-digit zero-padded chunk numbers so both glob/lexical sort (shell submit
    scripts) and numeric sort agree.
  * Sharded, gzipped SMILES->ID map (one shard per chunk) instead of a single
    ~150 GB file. Kept in a separate smiles_ids/ subdir so a single
    `aws s3 sync ... --include "*_chunk_*.csv"` uploads only the model inputs.
  * Atomic, resumable writing. Each chunk is written to <name>.tmp then renamed;
    a final-named chunk file is therefore always complete. On restart the script
    skips already-committed chunks and resumes the stream, so an interrupted
    multi-hour run continues instead of starting over.

Usage
-----
  # Full run (bz2 auto-detected from extension)
  python 01_large_library_processing.py \
      --input /path/2025.02_Enamine_REAL_DB_1.41B.cxsmiles.bz2 \
      --output-dir ./output \
      --library-name Enamine_Real_Sample_1.41B

  # Quick sanity test on the first 500k molecules only
  python 01_large_library_processing.py --input FILE --limit 500000

  # Upload chunk inputs to S3 when done (id-map shards are NOT uploaded here)
  python 01_large_library_processing.py --input FILE \
      --upload-s3 s3://ai2050-ersilia-cluster/input/Enamine_Real_Sample_1.41B/

Re-running the same command after an interruption resumes automatically.
"""

import argparse
import csv
import gzip
import io
import json
import logging
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# Long InChI/cxsmiles fields -> keep the CSV writer happy on output.
csv.field_size_limit(10 * 1024 * 1024)

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
DEFAULT_LIBRARY = "Enamine_Real_Sample_1.4B"
DEFAULT_CHUNK_SIZE = 100_000
DEFAULT_PAD = 6           # 6 digits -> up to 999,999 chunks
DEFAULT_SMILES_COL = "smiles"
DEFAULT_ID_COL = "id"
DEFAULT_DELIM = "\t"
PROGRESS_EVERY = 5_000_000

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)


# --------------------------------------------------------------------------- #
# Streaming decompression
# --------------------------------------------------------------------------- #
def open_text_stream(path: Path):
    """
    Return (text_stream, closer) for a possibly-compressed file, streamed.

    Prefers an external decompressor (parallel if available) piped via
    subprocess; falls back to the Python bz2/gzip modules. `closer()` must be
    called when done to release the subprocess / file handle.
    """
    suffix = path.suffix.lower()

    def _external(cmd_candidates):
        for cmd in cmd_candidates:
            exe = shutil.which(cmd[0])
            if exe:
                log.info(f"  Decompressing with external tool: {cmd[0]}")
                proc = subprocess.Popen(
                    [exe] + cmd[1:] + [str(path)],
                    stdout=subprocess.PIPE,
                )
                stream = io.TextIOWrapper(proc.stdout, encoding="utf-8", errors="replace")

                def closer():
                    try:
                        stream.close()
                    finally:
                        if proc.poll() is None:
                            proc.terminate()
                        proc.wait()
                return stream, closer
        return None

    if suffix == ".bz2":
        ext = _external([["lbzip2", "-dc"], ["pbzip2", "-dc"], ["bzip2", "-dc"]])
        if ext:
            return ext
        import bz2
        log.info("  Decompressing with Python bz2 module (no external tool found)")
        fh = bz2.open(path, "rt", encoding="utf-8", errors="replace")
        return fh, fh.close

    if suffix == ".gz":
        ext = _external([["pigz", "-dc"], ["gzip", "-dc"]])
        if ext:
            return ext
        log.info("  Decompressing with Python gzip module (no external tool found)")
        fh = gzip.open(path, "rt", encoding="utf-8", errors="replace")
        return fh, fh.close

    # Plain text (.cxsmiles / .smi / .csv / .tsv / .txt)
    log.info("  Reading uncompressed file")
    fh = open(path, "rt", encoding="utf-8", errors="replace")
    return fh, fh.close


# --------------------------------------------------------------------------- #
# Header + fast record iterator
# --------------------------------------------------------------------------- #
def resolve_columns(header_line: str, delimiter: str, smiles_col: str, id_col: str):
    """Return (smiles_idx, id_idx, headers) resolving columns case-insensitively."""
    headers = [h.strip() for h in header_line.rstrip("\n").rstrip("\r").split(delimiter)]
    lower = [h.lower() for h in headers]

    def idx_of(name):
        if name in headers:
            return headers.index(name)
        if name.lower() in lower:
            return lower.index(name.lower())
        return None

    return idx_of(smiles_col), idx_of(id_col), headers


def iter_records(stream, smiles_idx: int, id_idx, delimiter: str):
    """
    Yield (smiles, collection_id) from a TSV/CSV text stream (header already read).

    Fast path: manual split, no csv module. Rows with an empty SMILES are skipped
    (mirrors the original pipeline's behaviour).
    """
    need = smiles_idx if id_idx is None else max(smiles_idx, id_idx)
    for line in stream:
        parts = line.rstrip("\n").rstrip("\r").split(delimiter)
        if len(parts) <= need:
            continue
        smi = parts[smiles_idx].strip()
        if not smi:
            continue
        cid = parts[id_idx].strip() if id_idx is not None else ""
        yield smi, cid


# --------------------------------------------------------------------------- #
# Resume: inspect what's already been committed
# --------------------------------------------------------------------------- #
def existing_chunk_indices(lib_dir: Path, library_name: str):
    """Return the sorted list of committed chunk indices found in lib_dir."""
    idxs = []
    prefix = f"{library_name}_chunk_"
    for p in lib_dir.glob(f"{prefix}*.csv"):
        stem = p.stem[len(prefix):]
        if stem.isdigit():
            idxs.append(int(stem))
    return sorted(idxs)


def count_data_rows(path: Path) -> int:
    """Count data rows (lines minus header) of a plain CSV chunk."""
    n = 0
    with open(path, "rt", encoding="utf-8", errors="replace") as f:
        for _ in f:
            n += 1
    return max(0, n - 1)


def cleanup_and_plan_resume(lib_dir: Path, ids_dir: Path, library_name: str,
                            chunk_size: int, pad: int):
    """
    Clean stray *.tmp files and orphan id-map shards, then decide where to resume.

    Returns (start_index, rows_to_skip, already_done). `already_done` is True when
    the previous run had already reached EOF (its last chunk is a short EOF flush).
    """
    # Remove any half-written temp files from a crashed flush.
    for pattern_dir, pat in ((lib_dir, "*.tmp"), (ids_dir, "*.tmp")):
        if pattern_dir.exists():
            for tmp in pattern_dir.glob(pat):
                log.info(f"  Removing stray temp file: {tmp.name}")
                tmp.unlink()

    idxs = existing_chunk_indices(lib_dir, library_name)
    if not idxs:
        return 0, 0, False

    # Sequential single-stream writing must produce a contiguous 0..N-1 set.
    expected = list(range(idxs[-1] + 1))
    if idxs != expected:
        missing = sorted(set(expected) - set(idxs))
        raise SystemExit(
            f"ERROR: chunk files are not contiguous (missing {missing[:10]}"
            f"{' ...' if len(missing) > 10 else ''}). Refusing to resume into a "
            f"corrupt state. Inspect {lib_dir} and remove partial output before rerunning."
        )

    last = idxs[-1]
    last_rows = count_data_rows(lib_dir / f"{library_name}_chunk_{last:0{pad}d}.csv")

    # Drop id-map shards that have no matching committed chunk (crash between renames).
    if ids_dir.exists():
        for p in ids_dir.glob(f"{library_name}_smiles_ids_*.csv.gz"):
            stem = p.name[len(f"{library_name}_smiles_ids_"):-len(".csv.gz")]
            if stem.isdigit() and int(stem) not in set(idxs):
                log.info(f"  Removing orphan id-map shard: {p.name}")
                p.unlink()

    if last_rows < chunk_size:
        # The last committed chunk is a short EOF flush -> the run had finished.
        log.info(f"  Found {len(idxs)} committed chunks; last chunk has {last_rows:,} rows "
                 f"(< {chunk_size:,}) -> previous run already completed.")
        return last + 1, (last * chunk_size + last_rows), True

    # All committed chunks are full -> resume after them.
    rows_to_skip = (last + 1) * chunk_size
    log.info(f"  Found {len(idxs)} committed full chunks -> resuming at chunk "
             f"{last + 1} (skipping {rows_to_skip:,} already-written molecules).")
    return last + 1, rows_to_skip, False


# --------------------------------------------------------------------------- #
# Writer
# --------------------------------------------------------------------------- #
def make_flush(lib_dir: Path, ids_dir: Path, library_name: str, pad: int, write_id_map: bool):
    """Return a flush(smiles_buf, ids_buf, idx) that writes one chunk atomically."""

    def flush(smiles_buf, ids_buf, idx):
        chunk_final = lib_dir / f"{library_name}_chunk_{idx:0{pad}d}.csv"
        chunk_tmp = lib_dir / (chunk_final.name + ".tmp")

        # Write the id-map shard FIRST so the chunk file is the single commit marker.
        if write_id_map:
            ids_final = ids_dir / f"{library_name}_smiles_ids_{idx:0{pad}d}.csv.gz"
            ids_tmp = ids_dir / (ids_final.name + ".tmp")
            with gzip.open(ids_tmp, "wt", encoding="utf-8", newline="") as gf:
                w = csv.writer(gf)
                w.writerow(["smiles", "collection_id"])
                w.writerows(zip(smiles_buf, ids_buf))
            os.replace(ids_tmp, ids_final)

        with open(chunk_tmp, "w", newline="", encoding="utf-8") as cf:
            w = csv.writer(cf)
            w.writerow(["smiles"])
            w.writerows([s] for s in smiles_buf)
        os.replace(chunk_tmp, chunk_final)  # atomic commit

    return flush


# --------------------------------------------------------------------------- #
# Main processing
# --------------------------------------------------------------------------- #
def process(args) -> None:
    input_path = Path(args.input)
    if not input_path.exists():
        raise SystemExit(f"ERROR: input file not found: {input_path}")

    lib_dir = Path(args.output_dir) / args.library_name
    ids_dir = lib_dir / "smiles_ids"
    lib_dir.mkdir(parents=True, exist_ok=True)
    if args.id_map:
        ids_dir.mkdir(parents=True, exist_ok=True)

    delimiter = "\t" if args.delimiter == "\\t" else args.delimiter

    log.info("=" * 70)
    log.info("Large library ingestion")
    log.info(f"  Input       : {input_path}  ({input_path.stat().st_size / 1e9:.1f} GB on disk)")
    log.info(f"  Library     : {args.library_name}")
    log.info(f"  Output dir  : {lib_dir}")
    log.info(f"  Chunk size  : {args.chunk_size:,}")
    log.info(f"  Columns     : smiles='{args.smiles_col}'  id='{args.id_col}'  delim={delimiter!r}")
    log.info(f"  ID map      : {'sharded gzip in smiles_ids/' if args.id_map else 'DISABLED'}")
    if args.limit:
        log.info(f"  LIMIT       : first {args.limit:,} molecules only (test mode)")
    log.info("=" * 70)

    # Decide resume point (skips already-committed chunks).
    start_index, rows_to_skip, already_done = cleanup_and_plan_resume(
        lib_dir, ids_dir, args.library_name, args.chunk_size, args.pad
    )
    if already_done and not args.limit:
        log.info("Nothing to do — output already complete. (Delete the library dir to reprocess.)")
        _finalize(lib_dir, args, start_index)
        if args.upload_s3:
            _upload_chunks(lib_dir, args)
        if args.upload_idmap_s3 and args.id_map:
            _upload_idmap(ids_dir, args)
        return

    flush = make_flush(lib_dir, ids_dir, args.library_name, args.pad, args.id_map)

    stream, closer = open_text_stream(input_path)
    t0 = time.time()
    total_emitted = rows_to_skip   # molecules accounted for (skipped + written)
    written = 0
    chunk_idx = start_index
    smiles_buf: list[str] = []
    ids_buf: list[str] = []
    try:
        header_line = stream.readline()
        if header_line.strip().lower().startswith("sep="):
            header_line = stream.readline()   # skip Excel sep= directive
        smiles_idx, id_idx, headers = resolve_columns(
            header_line, delimiter, args.smiles_col, args.id_col
        )
        if smiles_idx is None:
            raise SystemExit(
                f"ERROR: SMILES column '{args.smiles_col}' not found. "
                f"Header (first 8): {headers[:8]}"
            )
        if id_idx is None and args.id_map:
            log.warning(f"  ID column '{args.id_col}' not found; id-map will have empty ids. "
                        f"Header (first 8): {headers[:8]}")
        log.info(f"  Resolved columns -> smiles@{smiles_idx}  id@{id_idx}")

        records = iter_records(stream, smiles_idx, id_idx, delimiter)

        # --- Fast-forward past already-committed molecules on resume ---
        if rows_to_skip:
            log.info(f"  Fast-forwarding past {rows_to_skip:,} already-written molecules "
                     f"(re-decompression, no writing)...")
            skipped = 0
            for _ in records:
                skipped += 1
                if skipped % PROGRESS_EVERY == 0:
                    log.info(f"    skipped {skipped:,}/{rows_to_skip:,}")
                if skipped >= rows_to_skip:
                    break

        # --- Main write loop ---
        for smi, cid in records:
            smiles_buf.append(smi)
            ids_buf.append(cid)
            written += 1
            total_emitted += 1

            if len(smiles_buf) == args.chunk_size:
                flush(smiles_buf, ids_buf, chunk_idx)
                chunk_idx += 1
                smiles_buf = []
                ids_buf = []

            if total_emitted % PROGRESS_EVERY == 0:
                _log_rate(total_emitted, written, chunk_idx, t0)

            if args.limit and written >= args.limit:
                break

        # Final partial chunk (EOF flush).
        if smiles_buf:
            flush(smiles_buf, ids_buf, chunk_idx)
            chunk_idx += 1
    finally:
        closer()

    elapsed = time.time() - t0
    log.info("-" * 70)
    log.info(f"  Wrote {written:,} molecules this run into chunks {start_index}..{chunk_idx - 1}")
    log.info(f"  Total molecules on disk: {total_emitted:,}  in {chunk_idx} chunk file(s)")
    log.info(f"  Elapsed: {elapsed / 3600:.2f} h  ({written / max(elapsed, 1e-9):,.0f} mol/s this run)")
    _finalize(lib_dir, args, chunk_idx, total_emitted)

    if args.upload_s3:
        _upload_chunks(lib_dir, args)
    if args.upload_idmap_s3 and args.id_map:
        _upload_idmap(ids_dir, args)


def _log_rate(total_emitted, written, chunk_idx, t0):
    elapsed = time.time() - t0
    rate = written / max(elapsed, 1e-9)
    log.info(f"  ... {total_emitted:,} molecules total  "
             f"({chunk_idx} chunks)  {rate:,.0f} mol/s  elapsed {elapsed / 3600:.2f} h")


def _finalize(lib_dir: Path, args, n_chunks: int, total: int | None = None) -> None:
    """Write a small manifest describing the produced chunks."""
    manifest = {
        "library_name": args.library_name,
        "chunk_size": args.chunk_size,
        "pad": args.pad,
        "n_chunks": n_chunks,
        "total_molecules": total,
        "id_map": bool(args.id_map),
        "source_file": str(Path(args.input).name),
    }
    with open(lib_dir / "_manifest.json", "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    log.info(f"  Manifest -> {lib_dir / '_manifest.json'}")


def _upload_chunks(lib_dir: Path, args) -> None:
    """Sync only the chunk CSVs to the S3 input prefix (id-map shards excluded)."""
    dest = args.upload_s3.rstrip("/") + "/"
    cmd = [
        "aws", "s3", "sync", str(lib_dir) + "/", dest,
        "--exclude", "*", "--include", f"{args.library_name}_chunk_*.csv",
    ]
    log.info("=" * 70)
    log.info(f"Uploading chunk inputs to S3: {dest}")
    log.info("  " + " ".join(cmd))
    result = subprocess.run(cmd)
    if result.returncode != 0:
        raise SystemExit(f"ERROR: aws s3 sync failed (exit {result.returncode})")
    log.info("  Upload complete. FSx Lustre will auto-import (AutoImportPolicy: NEW_CHANGED).")


def _upload_idmap(ids_dir: Path, args) -> None:
    """Sync the gzip id-map shards to their own S3 prefix (needed for on-cluster tagging)."""
    dest = args.upload_idmap_s3.rstrip("/") + "/"
    cmd = [
        "aws", "s3", "sync", str(ids_dir) + "/", dest,
        "--exclude", "*", "--include", f"{args.library_name}_smiles_ids_*.csv.gz",
    ]
    log.info("=" * 70)
    log.info(f"Uploading id-map shards to S3: {dest}")
    log.info("  " + " ".join(cmd))
    result = subprocess.run(cmd)
    if result.returncode != 0:
        raise SystemExit(f"ERROR: aws s3 sync (id map) failed (exit {result.returncode})")
    log.info("  Id-map upload complete.")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input", required=True,
                   help="Path to the single large library file (.bz2 / .gz / plain).")
    p.add_argument("--output-dir", default="./output", help="Root output directory.")
    p.add_argument("--library-name", default=DEFAULT_LIBRARY,
                   help=f"Library folder name (default: {DEFAULT_LIBRARY}).")
    p.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK_SIZE,
                   help=f"Molecules per chunk (default: {DEFAULT_CHUNK_SIZE:,}).")
    p.add_argument("--pad", type=int, default=DEFAULT_PAD,
                   help=f"Zero-padding width for chunk numbers (default: {DEFAULT_PAD}).")
    p.add_argument("--smiles-col", default=DEFAULT_SMILES_COL,
                   help=f"SMILES column name (default: {DEFAULT_SMILES_COL}).")
    p.add_argument("--id-col", default=DEFAULT_ID_COL,
                   help=f"Collection ID column name (default: {DEFAULT_ID_COL}).")
    p.add_argument("--delimiter", default=DEFAULT_DELIM,
                   help="Field delimiter (default: tab). Use '\\t' for tab on the CLI.")
    id_grp = p.add_mutually_exclusive_group()
    id_grp.add_argument("--id-map", dest="id_map", action="store_true", default=True,
                        help="Write sharded gzip SMILES->ID map (default: on).")
    id_grp.add_argument("--no-id-map", dest="id_map", action="store_false",
                        help="Do not write the SMILES->ID map.")
    p.add_argument("--limit", type=int, default=0,
                   help="Process only the first N molecules (test mode). 0 = all.")
    p.add_argument("--upload-s3", default=None,
                   help="If set, `aws s3 sync` the chunk CSVs to this S3 input prefix when done.")
    p.add_argument("--upload-idmap-s3", default=None,
                   help="If set, `aws s3 sync` the gzip id-map shards to this S3 prefix "
                        "(required later for on-cluster id tagging; e.g. "
                        "s3://ai2050-ersilia-cluster/smiles_ids/<library>/).")
    args = p.parse_args()
    process(args)


if __name__ == "__main__":
    main()
