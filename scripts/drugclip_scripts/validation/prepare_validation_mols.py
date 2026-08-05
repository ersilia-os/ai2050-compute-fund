#!/usr/bin/env python3
"""
Prepare the molecule side of the DrugCLIP validation run.

For each published pocket screen (screen_results/<screen_dir>/leader.csv) whose target
we have already encoded, this script:

  1. Parses the screen_dir name  AF-<uniprot>-F1-model_v4_<domain>_<pocket>  into
     (uniprot, domain, pocket).
  2. Looks up that pocket's conformations in our own manifest
     (<targets_base>/<uniprot>/pockets/manifest.csv) → the list of pocket_keys that
     index into pocket_reps.pkl.
  3. Collects the leader.csv SMILES.

It then writes:
  - chunk CSVs of the *unique union* of all leader SMILES (column `smiles`) into
    <input_dir>/<library>_chunk_NNN.csv, ready for submit-drugclip.sh to encode.
  - <input_dir>/pockets_index.csv — one row per (screen pocket × conformation):
        screen_dir,uniprot,domain,pocket,pocket_key,leader_csv
    which score_validation.py uses to gather each pocket's conformation embeddings
    and its ground-truth leader.csv.

Only pockets whose target has a pocket_reps.pkl are included (scope=all); scope=pilot
restricts to --pilot-targets.

Usage:
    python prepare_validation_mols.py \
        --screen-results-dir /fsx/input/validation_leaders/screen_results \
        --targets-base       /fsx/input/targets \
        --input-dir          /fsx/input/validation_leaders \
        --library            validation_leaders \
        --scope              all            # or: pilot
        [--pilot-targets P00519]
        [--chunk-size 2000]
"""

import argparse
import csv
import glob
import os
import re
import sys

SCREEN_RE = re.compile(r"^AF-(?P<uni>.+?)-F1-model_v4_(?P<dom>\d+)_(?P<pocket>.+)$")


def parse_screen_dir(name):
    m = SCREEN_RE.match(name)
    if not m:
        return None
    return m.group("uni"), m.group("dom"), m.group("pocket")


def load_manifest_keys(manifest_path, domain, pocket):
    """Return the list of pocket_keys for a given (domain, pocket) from a target manifest."""
    keys = []
    with open(manifest_path, newline="") as f:
        for row in csv.DictReader(f):
            if row["domain"].strip() == str(domain) and row["pocket"].strip() == str(pocket):
                keys.append(row["pocket_key"].strip())
    return keys


def read_leader_smiles(leader_csv):
    csv.field_size_limit(10 * 1024 * 1024)
    smiles = []
    with open(leader_csv, newline="") as f:
        for row in csv.DictReader(f):
            s = (row.get("smiles") or "").strip()
            if s:
                smiles.append(s)
    return smiles


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--screen-results-dir", default="/fsx/input/validation_leaders/screen_results")
    ap.add_argument("--targets-base", default="/fsx/input/targets")
    ap.add_argument("--input-dir", default="/fsx/input/validation_leaders")
    ap.add_argument("--library", default="validation_leaders")
    ap.add_argument("--scope", choices=["all", "pilot"], default="all")
    ap.add_argument("--pilot-targets", default="P00519",
                    help="Comma-separated UniProt IDs used when --scope pilot")
    ap.add_argument("--chunk-size", type=int, default=2000)
    args = ap.parse_args()

    if not os.path.isdir(args.screen_results_dir):
        print(f"ERROR: screen_results dir not found: {args.screen_results_dir}")
        sys.exit(1)

    pilot = {t.strip() for t in args.pilot_targets.split(",") if t.strip()}

    screen_dirs = sorted(
        d for d in os.listdir(args.screen_results_dir)
        if os.path.isdir(os.path.join(args.screen_results_dir, d)) and d.startswith("AF-")
    )

    index_rows = []          # (screen_dir, uniprot, domain, pocket, pocket_key, leader_csv)
    union_smiles = {}        # smiles -> None (insertion-ordered dedupe)
    n_pockets = n_skipped_scope = n_skipped_nopkl = n_skipped_nomanifest = 0

    for sd in screen_dirs:
        parsed = parse_screen_dir(sd)
        if not parsed:
            print(f"  WARN unparseable screen dir: {sd}")
            continue
        uni, dom, pocket = parsed

        if args.scope == "pilot" and uni not in pilot:
            n_skipped_scope += 1
            continue

        pkt_dir = os.path.join(args.targets_base, uni, "pockets")
        if not os.path.isfile(os.path.join(pkt_dir, "pocket_reps.pkl")):
            n_skipped_nopkl += 1
            continue

        manifest = os.path.join(pkt_dir, "manifest.csv")
        if not os.path.isfile(manifest):
            print(f"  WARN no manifest for {uni}: {manifest}")
            n_skipped_nomanifest += 1
            continue

        keys = load_manifest_keys(manifest, dom, pocket)
        if not keys:
            print(f"  WARN no manifest rows for {sd} (domain={dom}, pocket={pocket})")
            n_skipped_nomanifest += 1
            continue

        leader_csv = os.path.join(args.screen_results_dir, sd, "leader.csv")
        if not os.path.isfile(leader_csv):
            print(f"  WARN no leader.csv for {sd}")
            continue

        for s in read_leader_smiles(leader_csv):
            union_smiles.setdefault(s, None)
        for k in keys:
            index_rows.append((sd, uni, dom, pocket, k, leader_csv))
        n_pockets += 1

    if n_pockets == 0:
        print("ERROR: no pockets selected (nothing to validate). Check scope / pocket_reps.pkl presence.")
        sys.exit(1)

    os.makedirs(args.input_dir, exist_ok=True)

    # ── Write molecule chunks (unique union of leader SMILES) ─────────────────────
    smiles_list = list(union_smiles.keys())
    n_chunks = 0
    for i in range(0, len(smiles_list), args.chunk_size):
        chunk = smiles_list[i:i + args.chunk_size]
        path = os.path.join(args.input_dir, f"{args.library}_chunk_{n_chunks:03d}.csv")
        with open(path, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["smiles"])
            for s in chunk:
                w.writerow([s])
        n_chunks += 1

    # ── Write pockets index ───────────────────────────────────────────────────────
    index_path = os.path.join(args.input_dir, "pockets_index.csv")
    with open(index_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["screen_dir", "uniprot", "domain", "pocket", "pocket_key", "leader_csv"])
        w.writerows(index_rows)

    print("==========================================")
    print("Validation input prep")
    print("==========================================")
    print(f"Scope             : {args.scope}" + (f" ({sorted(pilot)})" if args.scope == 'pilot' else ""))
    print(f"Pockets selected  : {n_pockets}")
    print(f"Unique SMILES      : {len(smiles_list)}")
    print(f"Chunks written     : {n_chunks} × up to {args.chunk_size}  → {args.input_dir}/{args.library}_chunk_NNN.csv")
    print(f"Pockets index      : {index_path} ({len(index_rows)} conformation rows)")
    if n_skipped_scope:
        print(f"Skipped (scope)    : {n_skipped_scope}")
    if n_skipped_nopkl:
        print(f"Skipped (no pkl)   : {n_skipped_nopkl}  (target not encoded yet)")
    if n_skipped_nomanifest:
        print(f"Skipped (manifest) : {n_skipped_nomanifest}")
    print("==========================================")


if __name__ == "__main__":
    main()
