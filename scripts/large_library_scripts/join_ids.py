#!/usr/bin/env python3
"""
Re-attach the collection ID to standardized SMILES for ONE chunk.
=================================================================
The standardization model strips the Enamine `id` (its output is key / input /
standardized_smiles). The id only survives in step 01's per-chunk id shard
(`<lib>_smiles_ids_NNNNNN.csv.gz`, columns smiles,collection_id), which is
ROW-ALIGNED with the raw chunk — and therefore with the model result for that
chunk (the pipeline preserves 1:1 row order, as check-results.sh already asserts).

This joins result row i with id-shard row i, emitting `standardized_smiles,collection_id`
with empty-standardized rows dropped. It runs on the cluster (Python 3.9), invoked
per chunk by run-tag-ids-job.sh, and is the input the local dedup consumes.

Robustness: if an `--input-col` is present in the result, each row's raw SMILES is
checked against the id shard's smiles. Any mismatch (or a row-count mismatch) means
the positional alignment broke, so the script FAILS loudly rather than emit a wrong
map. A small tolerance of verify-mismatches is allowed via --max-mismatch (default 0).

Usage
-----
  python3 join_ids.py --result RES.csv --idshard IDS.csv.gz --out OUT.csv.gz
      [--std-col standardized_smiles] [--input-col input]
      [--idshard-smiles-col smiles] [--id-col collection_id] [--max-mismatch 0]
"""

import argparse
import csv
import gzip
import sys
from itertools import zip_longest

csv.field_size_limit(10 * 1024 * 1024)

_SENTINEL = object()


def _open(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="replace", newline="")
    return open(path, "rt", encoding="utf-8", errors="replace", newline="")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--result", required=True, help="Standardization result CSV for one chunk.")
    p.add_argument("--idshard", required=True, help="Step-01 id shard (.csv or .csv.gz) for the same chunk.")
    p.add_argument("--out", required=True, help="Output .csv.gz of standardized_smiles,collection_id.")
    p.add_argument("--std-col", default="standardized_smiles", help="Standardized SMILES column in the result.")
    p.add_argument("--input-col", default="input",
                   help="Raw-SMILES column in the result, used to verify row alignment (skipped if absent).")
    p.add_argument("--idshard-smiles-col", default="smiles", help="Raw SMILES column in the id shard.")
    p.add_argument("--id-col", default="collection_id", help="Collection ID column in the id shard.")
    p.add_argument("--max-mismatch", type=int, default=0,
                   help="Max tolerated raw-SMILES verify mismatches before failing (default 0).")
    args = p.parse_args()

    kept = 0
    dropped_empty = 0
    mismatches = 0
    total = 0

    with _open(args.result) as rf, _open(args.idshard) as idf, \
            gzip.open(args.out, "wt", encoding="utf-8", newline="") as outf:
        rr = csv.DictReader(rf)
        ir = csv.DictReader(idf)

        if args.std_col not in (rr.fieldnames or []):
            sys.exit(f"ERROR: std column '{args.std_col}' not in result {args.result}. "
                     f"Have: {rr.fieldnames}")
        if args.id_col not in (ir.fieldnames or []):
            sys.exit(f"ERROR: id column '{args.id_col}' not in id shard {args.idshard}. "
                     f"Have: {ir.fieldnames}")
        verify = args.input_col in (rr.fieldnames or []) and \
            args.idshard_smiles_col in (ir.fieldnames or [])

        w = csv.writer(outf)
        w.writerow(["standardized_smiles", "collection_id"])

        for rrow, irow in zip_longest(rr, ir, fillvalue=_SENTINEL):
            if rrow is _SENTINEL or irow is _SENTINEL:
                sys.exit(f"ERROR: row-count mismatch between {args.result} and {args.idshard} "
                         f"at row {total} — positional alignment broken.")
            total += 1

            if verify:
                raw_res = (rrow.get(args.input_col) or "").strip()
                raw_id = (irow.get(args.idshard_smiles_col) or "").strip()
                if raw_res != raw_id:
                    mismatches += 1
                    if mismatches > args.max_mismatch:
                        sys.exit(f"ERROR: raw-SMILES mismatch at row {total} "
                                 f"(result='{raw_res}' vs idshard='{raw_id}') — "
                                 f"alignment broken; refusing to emit a wrong map.")

            std = (rrow.get(args.std_col) or "").strip()
            if not std:
                dropped_empty += 1
                continue
            cid = (irow.get(args.id_col) or "").strip()
            w.writerow([std, cid])
            kept += 1

    sys.stderr.write(
        f"join_ids: total={total} kept={kept} dropped_empty={dropped_empty} "
        f"verify_mismatch={mismatches}\n"
    )


if __name__ == "__main__":
    main()
