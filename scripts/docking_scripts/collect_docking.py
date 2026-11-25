#!/usr/bin/env python3
"""
Collect a batched docking run (dock_batches.py) into one score table plus a small,
PyMOL-ready pose bundle per pocket. Batched-layout counterpart of collect_top_poses.py.

Writes, under --out-dir (default <docking-dir>/inspect):

    docking_scores.csv     one row per docked ligand: its BEST pose's Vina score, the
                           number of poses, and the pocket / receptor_prep it was docked
                           with. Join to the screen on deck_index (= row of
                           deck_smiles.txt and column of pocket_scores.npz).
    <tag>/top<N>.sdf       the N best ligands' best pose for that pocket
    <tag>/receptor.pdb     the receptor as docked into (ATOM records)
    <tag>/reference.pdb    the ligand that defined the box

Vina scores are kcal/mol and MORE NEGATIVE IS BETTER, the opposite of the DrugCLIP z-score.
Compare ranks, not values. `receptor_prep` differs between the human (Schrodinger) and
Mtb (PDBFixer) sets; keep that column next to any comparison across sets.

An incomplete run is collected anyway, with a warning naming how many batches are missing.

Runs on a head node with /shared/python39 (no RDKit needed); reads /fsx only.
"""

import argparse
import csv
import gzip
import heapq
import os
import sys


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--docking-dir", required=True)
    ap.add_argument("--out-dir", default=None, help="default <docking-dir>/inspect")
    ap.add_argument("--top-n", type=int, default=25,
                    help="poses kept per pocket for inspection (default 25). Output-size "
                         "parameter; the full score table is written regardless.")
    a = ap.parse_args()

    D = a.docking_dir
    OUT = a.out_dir or os.path.join(D, "inspect")
    manifest = list(csv.DictReader(open(os.path.join(D, "docking_manifest.csv"))))
    batches = list(csv.DictReader(open(os.path.join(D, "batches.csv"))))
    by_row = {i: r for i, r in enumerate(manifest, 1)}
    bdir = os.path.join(D, "batches")
    os.makedirs(OUT, exist_ok=True)

    top = {}                                  # tag -> heap of (-score, batch_id, ligand)
    n_done = n_missing = n_lig = 0
    out_csv = os.path.join(OUT, "docking_scores.csv")
    fields = ["batch_id", "uniprot", "set_name", "domain", "pocket", "receptor_prep",
              "ligand", "deck_index", "vina_kcal_mol", "n_poses"]
    with open(out_csv, "w", newline="") as fo:
        w = csv.DictWriter(fo, fieldnames=fields)
        w.writeheader()
        for b in batches:
            bid = int(b["batch_id"])
            p = os.path.join(bdir, f"b{bid:06d}.scores.csv")
            if not os.path.isfile(p):
                n_missing += 1
                continue
            n_done += 1
            m = by_row[int(b["manifest_row"])]
            best = {}                         # ligand -> [score, deck_index, n_poses]
            for r in csv.DictReader(open(p)):
                s = float(r["vina_kcal_mol"])
                cur = best.get(r["ligand"])
                if cur is None:
                    best[r["ligand"]] = [s, r["deck_index"], 1]
                else:
                    cur[2] += 1
                    if s < cur[0]:
                        cur[0] = s
            heap = top.setdefault(m["tag"], [])
            for lig, (s, di, n) in best.items():
                w.writerow({"batch_id": bid, "uniprot": m["uniprot"],
                            "set_name": m["set_name"], "domain": m["domain"],
                            "pocket": m["pocket"], "receptor_prep": m.get("receptor_prep", ""),
                            "ligand": lig, "deck_index": di, "vina_kcal_mol": s,
                            "n_poses": n})
                n_lig += 1
                item = (-s, bid, lig)         # keep the N most negative scores
                if len(heap) < a.top_n:
                    heapq.heappush(heap, item)
                elif item > heap[0]:
                    heapq.heapreplace(heap, item)

    print(f"{n_done} / {n_done + n_missing} batches collected, {n_lig:,} ligands")
    print(f"wrote {out_csv}")
    if n_missing:
        print(f"!! {n_missing} batch(es) not finished: this table is INCOMPLETE "
              "(see check-docking.sh)")

    # pose bundles: best pose of each top-N ligand, read from the batch .gz files
    tag_row = {r["tag"]: r for r in manifest}
    for tag, heap in sorted(top.items()):
        want = {}                             # batch_id -> {ligand}
        for _s, bid, lig in heap:
            want.setdefault(bid, set()).add(lig)
        blocks = {}
        for bid, ligs in want.items():
            gz = os.path.join(bdir, f"b{bid:06d}.poses.sdf.gz")
            buf = []
            with gzip.open(gz, "rt") as f:
                for line in f:
                    buf.append(line)
                    if line.startswith("$$$$"):
                        name = buf[0].strip()
                        if name in ligs and name not in blocks:   # first block = best pose
                            blocks[name] = "".join(buf)
                        buf = []
        ranked = sorted(heap, key=lambda t: -t[0])               # most negative first
        tdir = os.path.join(OUT, tag)
        os.makedirs(tdir, exist_ok=True)
        with open(os.path.join(tdir, f"top{a.top_n}.sdf"), "w") as f:
            for _s, _b, lig in ranked:
                if lig in blocks:
                    f.write(blocks[lig])
        m = tag_row[tag]
        if os.path.isfile(m["receptor"]):
            with open(m["receptor"]) as fi, open(os.path.join(tdir, "receptor.pdb"), "w") as fr:
                fr.writelines(ln for ln in fi if ln.startswith(("ATOM", "TER", "END")))
        ref = m.get("reference_ligand", "")
        if ref and os.path.isfile(ref):
            with open(ref) as fi, open(os.path.join(tdir, "reference.pdb"), "w") as fr:
                fr.write(fi.read())
        print(f"  {tag:<28} best {-ranked[0][0]:>7.2f} kcal/mol   "
              f"({len(blocks)} poses bundled)")
    print(f"\nbundle: {OUT}")
    if n_missing:
        sys.exit(2)


if __name__ == "__main__":
    main()
