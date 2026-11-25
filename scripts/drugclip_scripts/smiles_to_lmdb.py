#!/usr/bin/env python3
"""
Convert a SMILES CSV to LMDB format expected by DrugCLIP (LMDBDatasetV2).

Generates a single 3D conformer per molecule using RDKit ETKDGv3.
Molecules that cannot be encoded are skipped; downstream they become empty rows.

Usage:
    python smiles_to_lmdb.py --input chunk.csv --output mols.lmdb
        [--workers N] [--timeout 60] [--max-heavy-atoms 511]

LMDB format produced (LMDBDatasetV2-compatible):
    Named sub-database "data":
        key:   "0", "1", ...  (sequential, only for successful molecules)
        value: zstd-compressed pickle({ "smi": str, "atoms": list[str],
                                        "coordinates": list[ndarray(N, 3)] })
    Named sub-database "split":
        key:   "success"
        value: zstd-compressed b"0,1,2,..."  (comma-separated keys)

Companion files, next to the LMDB:
    <output>.smiles.txt    successful SMILES, one per line, in input order
    <output>.skipped.csv   row,smiles,reason,detail for every molecule left out

Skip reasons
------------
  empty         blank SMILES cell
  invalid       RDKit cannot parse the SMILES
  no_heavy_atoms  zero heavy atoms ([H][H], [HH], [H+]). The encoder strips hydrogens, so
                the molecule reaches the tokenizer empty and its len(atoms) > 0 assertion kills
                the whole chunk -- Coconut chunks 000/017/029 failed this way (2026-11-25).
  too_large     more than --max-heavy-atoms heavy atoms (default 511). Uni-Mol's tokenizer
                asserts len(atoms) < max_seq_len = 512 (unicore tokenize_dataset.py), and
                that assertion kills the whole chunk, not just the molecule -- which is how
                Molport chunks 386/448/472/480/526 and several Coconut chunks failed.
  timeout       3D generation (ETKDGv3, ETDG fallback, MMFF) took longer than --timeout s
                (default 60, decided 2026-11-23). Enforced by killing the worker process,
                because RDKit's embedding runs in C++ and a Python signal cannot interrupt it.
  embed_failed  3D generation raised, or its worker process died

Unchanged on purpose
--------------------
3D generation runs in --workers processes, but the LMDB is still written in INPUT order with
key = str(success counter). The encoder's lexicographic row order, and the remap that
h5_to_csv.py and score_validation.py apply to undo it (`key=str`), are therefore exactly as
before. Each molecule goes through the same RDKit calls with the same seed, so a molecule
that encoded under the old single-process version encodes identically now -- chunks already
finished do not need redoing. (The ETDG fallback has never been seeded; that pre-existing
non-determinism is kept rather than silently changed.)
"""

import argparse
import csv
import logging
import multiprocessing as mp
import os
import pickle
import sys
import time
from multiprocessing.connection import wait as mp_wait
from pathlib import Path

import lmdb
import numpy as np
import zstandard as zstd
from rdkit import Chem
from rdkit.Chem import AllChem

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)

SMILES_COLS = {"smiles", "canonical_smiles", "input"}

# Uni-Mol max_seq_len is 512 and the tokenizer requires len(atoms) < 512.
DEFAULT_MAX_HEAVY_ATOMS = 511
DEFAULT_TIMEOUT = 60.0


def smiles_to_atoms_coords(smi: str):
    """
    Generate a single 3D conformer from a SMILES string.

    Returns:
        atoms        : list[str]  — heavy-atom symbols (hydrogens removed)
        coordinates  : list       — [ndarray(N, 3)], single conformer wrapped in list

    Raises ValueError if SMILES is invalid or 3D generation fails.
    """
    mol = Chem.MolFromSmiles(smi)
    if mol is None:
        raise ValueError(f"Invalid SMILES: {smi[:80]}")

    mol = Chem.AddHs(mol)

    params = AllChem.ETKDGv3()
    params.randomSeed = 42
    result = AllChem.EmbedMolecule(mol, params)

    if result == -1:
        # Fallback: classic distance-geometry without ETKDG
        result = AllChem.EmbedMolecule(mol, AllChem.ETDG())

    if result == -1:
        raise ValueError(f"3D conformer generation failed: {smi[:80]}")

    AllChem.MMFFOptimizeMolecule(mol)
    mol = Chem.RemoveHs(mol)

    conf = mol.GetConformer()
    atoms = [atom.GetSymbol() for atom in mol.GetAtoms()]
    coords = conf.GetPositions()  # (N, 3)

    return atoms, [coords]  # list of one (N, 3) array — matches AffinityMolDataset expectation


def heavy_atom_count(mol):
    """Atoms the encoder keeps: it drops every "H", including isotopic ones."""
    return sum(1 for a in mol.GetAtoms() if a.GetAtomicNum() > 1)


def _worker(conn):
    """Embed (idx, smiles) jobs received over `conn` until it receives None."""
    while True:
        job = conn.recv()
        if job is None:
            return
        idx, smi = job
        try:
            atoms, coords = smiles_to_atoms_coords(smi)
            conn.send((idx, None, atoms, coords))
        except Exception as e:
            conn.send((idx, str(e), None, None))


def embed_all(jobs, n_workers, timeout):
    """Run 3D generation for [(idx, smiles)] in worker processes with a per-molecule timeout.

    Returns ({idx: (None, atoms, coords) | (reason, detail, None)}, [seconds per success]).
    A worker that overruns `timeout` is killed and replaced; one that dies on its own
    (e.g. a crash inside RDKit) is replaced too, and its molecule recorded as embed_failed.
    """
    ctx = mp.get_context("fork")

    def spawn():
        parent, child = ctx.Pipe()
        proc = ctx.Process(target=_worker, args=(child,), daemon=True)
        proc.start()
        child.close()
        return {"proc": proc, "conn": parent, "job": None, "t0": 0.0}

    def retire(w):
        w["proc"].kill()
        w["proc"].join()
        w["conn"].close()

    workers = [spawn() for _ in range(max(1, min(n_workers, len(jobs))))]
    queue = list(reversed(jobs))                     # pop() takes them in input order
    results, seconds = {}, []

    while queue or any(w["job"] is not None for w in workers):
        for w in workers:
            if w["job"] is None and queue:
                w["job"] = queue.pop()
                w["t0"] = time.monotonic()
                w["conn"].send(w["job"])

        ready = mp_wait([w["conn"] for w in workers if w["job"] is not None], timeout=1.0)
        now = time.monotonic()
        for i, w in enumerate(workers):
            if w["job"] is None:
                continue
            idx, _smi = w["job"]
            if w["conn"] in ready:
                try:
                    _idx, err, atoms, coords = w["conn"].recv()
                except EOFError:
                    results[idx] = ("embed_failed", "worker process died", None)
                    retire(w)
                    workers[i] = spawn()
                    continue
                if err is None:
                    results[idx] = (None, atoms, coords)
                    seconds.append(now - w["t0"])
                else:
                    results[idx] = ("embed_failed", err, None)
                w["job"] = None
            elif now - w["t0"] > timeout:
                results[idx] = ("timeout", f"3D generation exceeded {timeout:.0f} s", None)
                retire(w)
                workers[i] = spawn()

    for w in workers:
        w["conn"].send(None)
        w["proc"].join(timeout=5)
    return results, seconds


def main():
    parser = argparse.ArgumentParser(
        description="Convert SMILES CSV → LMDB for DrugCLIP (LMDBDatasetV2 format)"
    )
    parser.add_argument("--input",      required=True,
                        help="Input CSV file (must have a SMILES column)")
    parser.add_argument("--output",     required=True,
                        help="Output LMDB directory path")
    parser.add_argument("--smiles-col", default=None,
                        help="SMILES column name (auto-detected if omitted)")
    parser.add_argument("--workers",    type=int, default=0,
                        help="3D-generation processes (default: CPUs available to this job)")
    parser.add_argument("--timeout",    type=float, default=DEFAULT_TIMEOUT,
                        help="seconds allowed for one molecule's 3D generation (default 60)")
    parser.add_argument("--max-heavy-atoms", type=int, default=DEFAULT_MAX_HEAVY_ATOMS,
                        help="skip larger molecules; the encoder cannot take 512 or more "
                             "(default 511)")
    args = parser.parse_args()

    input_path  = Path(args.input)
    output_path = Path(args.output)
    n_workers   = args.workers or len(os.sched_getaffinity(0))

    # ── Read CSV ─────────────────────────────────────────────────────────────
    csv.field_size_limit(10 * 1024 * 1024)
    with open(input_path, newline="", encoding="utf-8") as f:
        reader    = csv.DictReader(f)
        fieldnames_lower = [c.strip().lower() for c in (reader.fieldnames or [])]

        if args.smiles_col:
            smiles_col = args.smiles_col
        else:
            smiles_col = next(
                (orig for orig, lower in zip(reader.fieldnames, fieldnames_lower)
                 if lower in SMILES_COLS),
                None,
            )

        if smiles_col is None:
            log.error(f"No SMILES column found. Columns: {reader.fieldnames}")
            sys.exit(1)

        rows = list(reader)

    log.info(f"Input      : {input_path}  ({len(rows):,} rows, SMILES col: '{smiles_col}')")
    log.info(f"Output     : {output_path}")
    log.info(f"3D workers : {n_workers}   timeout {args.timeout:.0f} s/molecule   "
             f"max heavy atoms {args.max_heavy_atoms}")

    # ── Cheap checks in this process; only plausible molecules reach a worker ─
    skipped = []                 # (row, smiles, reason, detail)
    jobs = []
    for idx, row in enumerate(rows):
        smi = row[smiles_col].strip()
        if not smi:
            skipped.append((idx, smi, "empty", ""))
            continue
        mol = Chem.MolFromSmiles(smi)
        if mol is None:
            skipped.append((idx, smi, "invalid", f"Invalid SMILES: {smi[:80]}"))
            continue
        n_heavy = heavy_atom_count(mol)
        if n_heavy == 0:
            skipped.append((idx, smi, "no_heavy_atoms", "nothing left after removing hydrogens"))
            continue
        if n_heavy > args.max_heavy_atoms:
            skipped.append((idx, smi, "too_large", f"{n_heavy} heavy atoms"))
            continue
        jobs.append((idx, smi))

    t0 = time.monotonic()
    results, seconds = embed_all(jobs, n_workers, args.timeout)
    log.info(f"3D generation: {len(jobs):,} molecules in {time.monotonic() - t0:.0f} s")

    # ── Write LMDB (LMDBDatasetV2 format), in INPUT order ────────────────────
    env = lmdb.open(
        str(output_path),
        max_dbs=2,
        map_size=1099511627776,  # 1 TB virtual — actual disk use is much smaller
        readonly=False,
        lock=False,
        readahead=False,
        meminit=False,
    )

    split_db = env.open_db(b"split")
    data_db  = env.open_db(b"data")

    compressor = zstd.ZstdCompressor(level=3)

    n_ok        = 0
    keys        = []
    success_smiles = []   # SMILES of successfully processed molecules, in embedding order

    with env.begin(write=True) as txn:
        for idx, smi in jobs:
            reason, a, b = results[idx]
            if reason is not None:
                skipped.append((idx, smi, reason, a))
                continue
            atoms, coordinates = a, b

            key  = str(n_ok)
            data = {"smi": smi, "atoms": atoms, "coordinates": coordinates}
            txn.put(key.encode(), compressor.compress(pickle.dumps(data)), db=data_db)
            keys.append(key)
            success_smiles.append(smi)
            n_ok += 1

        # Write "success" split: comma-separated keys, zstd-compressed
        split_value = ",".join(keys).encode()
        txn.put(b"success", compressor.compress(split_value), db=split_db)

    env.close()

    # Write companion SMILES index: one SMILES per line, same order as h5 rows
    smiles_index_path = output_path.with_suffix(".smiles.txt")
    with open(smiles_index_path, "w", encoding="utf-8") as f:
        f.write("\n".join(success_smiles) + ("\n" if success_smiles else ""))
    log.info(f"SMILES index: {smiles_index_path}  ({n_ok:,} entries)")

    # Every molecule left out, with the reason, so an empty row downstream is explainable
    skipped.sort()
    skipped_path = output_path.with_suffix(".skipped.csv")
    with open(skipped_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["row", "smiles", "reason", "detail"])
        w.writerows(skipped)
    for idx, _smi, reason, detail in skipped:
        if reason != "empty":
            log.warning(f"  SKIP [{idx}] {reason}: {detail}")

    log.info(f"Done — {n_ok:,} written, {len(skipped):,} skipped")
    if skipped:
        counts = {}
        for s in skipped:
            counts[s[2]] = counts.get(s[2], 0) + 1
        log.warning("  skipped by reason: "
                    + ", ".join(f"{r} {n}" for r, n in sorted(counts.items())))
    if seconds:
        q = np.percentile(seconds, [50, 99])
        log.info(f"  3D time per molecule: p50 {q[0]:.2f} s, p99 {q[1]:.2f} s, "
                 f"max {max(seconds):.2f} s")

    # Exit non-zero if everything failed
    if n_ok == 0:
        log.error("No molecules were written to LMDB — aborting")
        sys.exit(1)


if __name__ == "__main__":
    main()
