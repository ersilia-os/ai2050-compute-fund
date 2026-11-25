#!/usr/bin/env python3
"""
Audit finished DrugCLIP chunks: are the embeddings complete, and do the files agree?

check-drugclip-results.sh only compares row counts, so it passes a chunk whose h5 is
correctly shaped but partly zero (an encoder that died mid-fold), whose CSV was cut short
(a node lost while writing it), or whose h5 and SMILES index disagree (which would pair
embeddings with the wrong molecules). This script opens every file of a chunk and checks:

  h5        6 fold masks (fold0..fold5), each fully written
            every row's six 128-dim blocks finite and unit norm (min >= 0.9, the same
            test run-drugclip-job.sh applies before promoting a chunk; that test misses
            NaN, so finiteness is checked separately here)
  index     h5 rows == lines in .smiles.txt
  accounted .smiles.txt lines + .skipped.csv rows == input rows
            (chunks encoded before 2026-11-23 have no .skipped.csv: reported as n/a)
  csv       data rows == input rows, and the last line has all 770 columns

Read-only. Reads every h5 and CSV in full, so restrict with --since for large libraries.

Usage:
    /shared/python39/bin/python3.9 audit-drugclip-embeddings.py [library ...]
        [--since YYYY-MM-DD] [--chunks 000,017,029] [--workers N]

    No library given: all 5 main libraries. --since keeps chunks whose h5 was modified
    on or after that date.

Exit code 0 if every audited chunk passes, 1 otherwise.
"""

import argparse
import csv
import io
import os
import sys
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime
from pathlib import Path

import h5py
import numpy as np

ALL_LIBRARIES = [
    "Enamine_Hit_Locator_460K",
    "Coconut_715K",
    "Enamine_Liquid_Stock_2.5M",
    "Molport_Screening_Compounds_5.3M",
    "Enamine_Real_Sample_10.4M",
]
INPUT_ROOT = Path("/fsx/input")
OUTPUT_ROOT = Path("/fsx/output")

N_FOLDS = 6
FOLD_DIM = 128
MIN_NORM = 0.9          # same as run-drugclip-job.sh
N_CSV_COLUMNS = 2 + N_FOLDS * FOLD_DIM


def count_lines(path):
    with open(path, "rb") as f:
        return sum(1 for _ in f)


def count_csv_records(path):
    """Data records, not lines: .skipped.csv's `detail` holds RDKit messages, some of which
    span several lines inside one quoted field."""
    with open(path, newline="", encoding="utf-8") as f:
        return sum(1 for _ in csv.reader(f)) - 1


def last_line(path, block=1 << 20):
    """Last non-empty line of a file, read from the end."""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - block))
        tail = f.read().decode("utf-8", errors="replace")
    lines = [ln for ln in tail.splitlines() if ln.strip()]
    return lines[-1] if lines else ""


def audit_h5(path):
    """Return (n_rows, problems, min_norm)."""
    problems = []
    with h5py.File(path, "r") as f:
        if "mol_reps" not in f:
            return 0, ["h5 has no mol_reps"], None
        n, width = f["mol_reps"].shape
        if width != N_FOLDS * FOLD_DIM:
            problems.append(f"h5 width {width}, expected {N_FOLDS * FOLD_DIM}")
            return n, problems, None
        for k in range(N_FOLDS):
            name = f"fold{k}"
            if name not in f:
                problems.append(f"{name} mask missing")
                continue
            written = int(f[name][:].sum())
            if written != n:
                problems.append(f"{name} {written}/{n} written")
        if n == 0:
            return 0, problems + ["h5 has 0 rows"], None
        X = f["mol_reps"][:].reshape(n, N_FOLDS, FOLD_DIM)
    bad = ~np.isfinite(X).all(axis=2)
    if bad.any():
        problems.append(f"{int(bad.any(axis=1).sum())} rows with NaN/inf")
    norms = np.linalg.norm(np.nan_to_num(X), axis=2)
    min_norm = float(norms.min())
    if min_norm < MIN_NORM:
        low = norms < MIN_NORM
        per_fold = ", ".join(f"f{k}:{int(low[:, k].sum())}" for k in range(N_FOLDS) if low[:, k].any())
        problems.append(f"{int(low.any(axis=1).sum())} rows with a block norm < {MIN_NORM} ({per_fold})")
    return n, problems, min_norm


def audit_chunk(args):
    library, chunk, input_file = args
    out = OUTPUT_ROOT / library / "drugclip"
    stem = f"{library}_drugclip_{chunk}"
    h5_path = out / f"{stem}.h5"
    smi_path = out / f"{stem}.smiles.txt"
    skip_path = out / f"{stem}.skipped.csv"
    csv_path = out / f"{stem}.csv"

    problems = []
    n_input = count_lines(input_file) - 1

    try:
        n_h5, h5_problems, min_norm = audit_h5(h5_path)
        problems += h5_problems
    except Exception as e:
        return chunk, [f"h5 unreadable: {e}"], None, "?"

    if smi_path.exists():
        n_smi = count_lines(smi_path)
        if n_smi != n_h5:
            problems.append(f"h5 rows {n_h5} != smiles.txt lines {n_smi}")
    else:
        n_smi = None
        problems.append("smiles.txt missing")

    accounted = "n/a"
    if skip_path.exists() and n_smi is not None:
        n_skip = count_csv_records(skip_path)
        accounted = f"{n_smi}+{n_skip}"
        if n_smi + n_skip != n_input:
            problems.append(f"encoded {n_smi} + skipped {n_skip} != input {n_input}")

    if csv_path.exists():
        n_csv = count_lines(csv_path) - 1
        if n_csv != n_input:
            problems.append(f"csv rows {n_csv} != input {n_input}")
        n_cols = len(next(csv.reader(io.StringIO(last_line(csv_path))), []))
        if n_cols != N_CSV_COLUMNS:
            problems.append(f"csv last line has {n_cols} columns, expected {N_CSV_COLUMNS}")
    else:
        problems.append("csv missing")

    return chunk, problems, min_norm, accounted


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("libraries", nargs="*", default=ALL_LIBRARIES)
    p.add_argument("--since", help="only chunks whose h5 was modified on/after YYYY-MM-DD")
    p.add_argument("--chunks", help="comma-separated chunk numbers, e.g. 000,017,029")
    p.add_argument("--workers", type=int, default=4)
    a = p.parse_args()

    since = datetime.strptime(a.since, "%Y-%m-%d").timestamp() if a.since else None
    only = set(a.chunks.split(",")) if a.chunks else None
    all_ok = True

    for library in a.libraries:
        out = OUTPUT_ROOT / library / "drugclip"
        jobs, not_done = [], []
        for input_file in sorted((INPUT_ROOT / library).glob("*_chunk_*.csv")):
            chunk = input_file.stem.split("_")[-1]
            if only and chunk not in only:
                continue
            h5_path = out / f"{library}_drugclip_{chunk}.h5"
            if not h5_path.exists():
                not_done.append(chunk)
                continue
            if since and h5_path.stat().st_mtime < since:
                continue
            jobs.append((library, chunk, input_file))

        print(f"\n== {library}: auditing {len(jobs)} chunks"
              + (f" (h5 modified since {a.since})" if since else "")
              + (f" | not encoded yet: {' '.join(not_done)}" if not_done else ""))
        if not jobs:
            continue

        with ProcessPoolExecutor(max_workers=a.workers) as pool:
            results = sorted(pool.map(audit_chunk, jobs))

        failed = [(c, pr) for c, pr, _, _ in results if pr]
        norms = [m for _, _, m, _ in results if m is not None]
        no_skiplog = sum(1 for *_, acc in results if acc == "n/a")
        print(f"   pass {len(results) - len(failed)}/{len(results)}"
              + (f" | min block norm {min(norms):.4f}" if norms else "")
              + (f" | {no_skiplog} chunks without .skipped.csv (pre-23 Nov)" if no_skiplog else ""))
        for chunk, pr in failed:
            all_ok = False
            print(f"   FAIL {chunk}: " + "; ".join(pr))

    print("\nALL PASS" if all_ok else "\nSOME CHUNKS FAILED (see FAIL lines)")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
