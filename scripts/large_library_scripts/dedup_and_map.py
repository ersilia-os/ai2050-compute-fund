#!/usr/bin/env python3
"""
Deduplicate standardized SMILES (keep first) + build the final SMILES->ID map.
==============================================================================
Runs LOCALLY. Consumes the id-tagged shards produced on the cluster by
submit-tag-ids.sh (s3://<bucket>/tagged/<lib>/<model>/*_tagged_NNNNNN.csv.gz,
columns standardized_smiles,collection_id), and produces:

  <work-dir>/<lib>_smiles_ids_dedup.csv.gz          FINAL MAP: standardized_smiles,collection_id
  <work-dir>/dedup_chunks/<dedup-lib>_chunk_NNNNNN.csv   deduped SMILES-only chunks (downstream input)

Dedup keeps the FIRST global appearance of each standardized SMILES (and the
collection_id it first appeared with). It is memory-bounded via hash-sharding:

  Pass 1 (shard): stream every tagged shard IN CHUNK ORDER, appending each
    `std<TAB>id` to bucket file  crc32(std) % B.  Because records are appended in
    global order and all copies of a given SMILES hash to the same bucket, the
    first row for that SMILES within its bucket IS its first global appearance.
  Pass 2 (dedup): for each bucket, walk rows in order, keep the first per SMILES
    (a per-bucket `seen` set fits in RAM: ~unique/B entries).

At 1.41B rows with B=512, each bucket holds ~2.7M uniques (~a few hundred MB RAM),
and bucket files total ~the tagged size (~90 GB uncompressed) — well within local disk.

Usage
-----
  python3 dedup_and_map.py --library-name Enamine_Real_Sample_1.4B --model-id eos4k4f_v1
  # already downloaded the tagged shards?  add --no-download
  # push the deduped chunks to S3 for the next model:
  python3 dedup_and_map.py ... --upload-chunks-s3 s3://ai2050-ersilia-cluster/input/Enamine_Real_Sample_1.4B_std/
"""

import argparse
import csv
import glob
import gzip
import logging
import os
import re
import subprocess
import sys
import time
import zlib
from pathlib import Path

csv.field_size_limit(10 * 1024 * 1024)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)


def sync_down(s3_tagged: str, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    cmd = ["aws", "s3", "sync", s3_tagged, str(dest) + "/",
           "--exclude", "*", "--include", "*_tagged_*.csv.gz"]
    log.info("Downloading tagged shards: " + " ".join(cmd))
    if subprocess.run(cmd).returncode != 0:
        raise SystemExit("ERROR: aws s3 sync (download) failed")


def sorted_tagged(tagged_dir: Path) -> list:
    files = glob.glob(str(tagged_dir / "*_tagged_*.csv.gz"))
    def num(p):
        m = re.search(r"_tagged_(\d+)\.csv\.gz$", p)
        return int(m.group(1)) if m else -1
    return sorted(files, key=num)


def shard_pass(files: list, bucket_dir: Path, n_buckets: int) -> int:
    """Append each std<TAB>id into its hash bucket, in global order. Returns rows read."""
    bucket_dir.mkdir(parents=True, exist_ok=True)
    handles = [open(bucket_dir / f"bucket_{b:04d}.tsv", "w", encoding="utf-8") for b in range(n_buckets)]
    total = 0
    t0 = time.time()
    try:
        for i, fp in enumerate(files, 1):
            with gzip.open(fp, "rt", encoding="utf-8", errors="replace") as f:
                first = True
                for line in f:
                    if first:  # skip header
                        first = False
                        if line.startswith("standardized_smiles"):
                            continue
                    line = line.rstrip("\n").rstrip("\r")
                    if not line:
                        continue
                    std, sep, cid = line.partition(",")
                    if not std:
                        continue
                    b = zlib.crc32(std.encode("utf-8")) % n_buckets
                    handles[b].write(std + "\t" + cid + "\n")
                    total += 1
            if i % 500 == 0 or i == len(files):
                log.info(f"  shard: {i:,}/{len(files):,} shards, {total:,} rows, "
                         f"{total / max(time.time() - t0, 1e-9):,.0f} rows/s")
    finally:
        for h in handles:
            h.close()
    return total


def dedup_pass(bucket_dir: Path, n_buckets: int, map_path: Path,
               chunks_dir: Path, dedup_lib: str, chunk_size: int, pad: int):
    """Keep first std per bucket -> final map + deduped SMILES-only chunks."""
    chunks_dir.mkdir(parents=True, exist_ok=True)
    kept = 0
    chunk_idx = 0
    smiles_buf: list = []

    def flush():
        nonlocal chunk_idx, smiles_buf
        p = chunks_dir / f"{dedup_lib}_chunk_{chunk_idx:0{pad}d}.csv"
        with open(p, "w", newline="", encoding="utf-8") as cf:
            w = csv.writer(cf)
            w.writerow(["smiles"])
            w.writerows([s] for s in smiles_buf)
        chunk_idx += 1
        smiles_buf = []

    t0 = time.time()
    with gzip.open(map_path, "wt", encoding="utf-8", newline="") as mf:
        mw = csv.writer(mf)
        mw.writerow(["standardized_smiles", "collection_id"])
        for b in range(n_buckets):
            bf = bucket_dir / f"bucket_{b:04d}.tsv"
            if not bf.exists():
                continue
            seen = set()
            with open(bf, "rt", encoding="utf-8") as f:
                for line in f:
                    std, sep, cid = line.rstrip("\n").partition("\t")
                    if std in seen:
                        continue
                    seen.add(std)
                    mw.writerow([std, cid])
                    smiles_buf.append(std)
                    kept += 1
                    if len(smiles_buf) == chunk_size:
                        flush()
            if (b + 1) % 64 == 0 or b + 1 == n_buckets:
                log.info(f"  dedup: bucket {b + 1:,}/{n_buckets:,}, {kept:,} unique kept, "
                         f"{kept / max(time.time() - t0, 1e-9):,.0f} rows/s")
    if smiles_buf:
        flush()
    return kept, chunk_idx


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--library-name", required=True, help="Source library (for the tagged S3 prefix).")
    p.add_argument("--model-id", required=True, help="Standardization model id (tagged S3 prefix).")
    p.add_argument("--s3-bucket", default="ai2050-ersilia-cluster")
    p.add_argument("--work-dir", default="./dedup_work", help="Local scratch/output dir.")
    p.add_argument("--buckets", type=int, default=512, help="Hash buckets (memory vs file-handles).")
    p.add_argument("--chunk-size", type=int, default=100_000, help="Rows per deduped output chunk.")
    p.add_argument("--pad", type=int, default=6)
    p.add_argument("--dedup-library-name", default=None,
                   help="Name for deduped output chunks (default: <library>_std).")
    p.add_argument("--no-download", dest="download", action="store_false", default=True,
                   help="Skip the S3 download (tagged shards already local).")
    p.add_argument("--upload-chunks-s3", default=None,
                   help="If set, `aws s3 sync` the deduped chunks to this S3 input prefix.")
    p.add_argument("--keep-buckets", action="store_true", help="Do not delete bucket temp files at the end.")
    args = p.parse_args()

    work = Path(args.work_dir)
    tagged_dir = work / "tagged"
    bucket_dir = work / "buckets"
    chunks_dir = work / "dedup_chunks"
    dedup_lib = args.dedup_library_name or f"{args.library_name}_std"
    map_path = work / f"{args.library_name}_smiles_ids_dedup.csv.gz"
    s3_tagged = f"s3://{args.s3_bucket}/tagged/{args.library_name}/{args.model_id}/"
    work.mkdir(parents=True, exist_ok=True)

    log.info("=" * 70)
    log.info("Dedup + final SMILES->ID map")
    log.info(f"  Tagged S3   : {s3_tagged}")
    log.info(f"  Work dir    : {work}")
    log.info(f"  Buckets     : {args.buckets}")
    log.info(f"  Final map   : {map_path}")
    log.info(f"  Deduped lib : {dedup_lib}  (chunks of {args.chunk_size:,})")
    log.info("=" * 70)

    if args.download:
        sync_down(s3_tagged, tagged_dir)

    files = sorted_tagged(tagged_dir)
    if not files:
        raise SystemExit(f"ERROR: no *_tagged_*.csv.gz in {tagged_dir}")
    log.info(f"Found {len(files):,} tagged shards.")

    log.info("Pass 1/2: hash-sharding (preserving global order) ...")
    total = shard_pass(files, bucket_dir, args.buckets)

    log.info("Pass 2/2: dedup (keep first) + writing map & chunks ...")
    kept, n_chunks = dedup_pass(bucket_dir, args.buckets, map_path,
                                chunks_dir, dedup_lib, args.chunk_size, args.pad)

    if not args.keep_buckets:
        for bf in bucket_dir.glob("bucket_*.tsv"):
            bf.unlink()
        try:
            bucket_dir.rmdir()
        except OSError:
            pass

    dropped = total - kept
    pct = (kept / total * 100) if total else 0
    log.info("=" * 70)
    log.info(f"  Input (tagged) records : {total:,}")
    log.info(f"  Unique kept            : {kept:,} ({pct:.1f}%)")
    log.info(f"  Duplicates dropped     : {dropped:,}")
    log.info(f"  Final map              : {map_path}")
    log.info(f"  Deduped chunks         : {n_chunks:,} in {chunks_dir}")
    log.info("=" * 70)

    if args.upload_chunks_s3:
        dest = args.upload_chunks_s3.rstrip("/") + "/"
        cmd = ["aws", "s3", "sync", str(chunks_dir) + "/", dest,
               "--exclude", "*", "--include", f"{dedup_lib}_chunk_*.csv"]
        log.info("Uploading deduped chunks: " + " ".join(cmd))
        if subprocess.run(cmd).returncode != 0:
            raise SystemExit("ERROR: aws s3 sync (upload) failed")
        log.info(f"Deduped input ready at {dest} — run downstream models on library '{dedup_lib}'.")
    else:
        log.info(f"To use the deduped set downstream, upload the chunks, e.g.:")
        log.info(f"  aws s3 sync {chunks_dir}/ "
                 f"s3://{args.s3_bucket}/input/{dedup_lib}/ --exclude '*' --include '{dedup_lib}_chunk_*.csv'")


if __name__ == "__main__":
    main()
