#!/usr/bin/env python3
"""
Collect Uni-Dock results into something small enough to pull down and open in PyMOL.

The raw output is one `*_out.sdf` per ligand -- ~460k files for the Hit Locator screen.
Syncing that is hundreds of thousands of S3 requests, and nobody inspects 460k poses.
This writes, per pocket:

    inspect/<tag>/receptor.pdb      the prepared receptor, as docked into
    inspect/<tag>/top<N>.sdf        the N best ligands' best pose, one multi-model SDF
    inspect/<tag>/reference.pdb     the ligand that defined the box, for orientation

plus one global `docking_scores.csv` with EVERY ligand's best Vina score -- the artefact
you actually join against the DrugCLIP scores. That is ~460k rows and tens of MB, versus
tens of GB of poses.

No RDKit: `/shared/python39` does not have it, and SDF is simple enough to parse directly.
Each `*_out.sdf` holds up to `--num-modes` poses; the FIRST is Uni-Dock's best, and its
score lives in a `> <Uni-Dock RESULT>` tag as `... RESULT: <kcal/mol> ...`.

Vina scores are kcal/mol and MORE NEGATIVE IS BETTER -- the opposite convention to the
DrugCLIP z-score, which is higher-is-better. Compare ranks, not values.

Ligand names carry the deck index (`<uniprot>_<pocket>_<deck_index>`), so a pose joins
back to `deck_smiles.txt` and to the screen's score matrices without any lookup table.

Runs on the head node; reads /fsx only.
"""

import argparse
import csv
import glob
import os
import re
import shutil
import sys

# An SDF data tag is a line `> <NAME>` followed by its value lines, terminated by a blank
# line. The score tag's NAME varies by tool and version -- "Uni-Dock RESULT", "docking
# score", "minimizedAffinity" -- and an earlier version of this script searched the whole
# block for the literal "RESULT:", which matched nothing because the tag line reads
# "RESULT>" not "RESULT:". Match on the tag NAME, then take the first float in its value.
TAG_RE = re.compile(r"^>\s*<([^>]+)>")
SCORE_TAG_WORDS = ("RESULT", "SCORE", "AFFINITY", "ENERGY")
FLOAT_RE = re.compile(r"(-?\d+\.\d+)")


def iter_sdf_blocks(path):
    """Yield raw SDF molecule blocks (text up to and including the $$$$ line)."""
    buf = []
    with open(path, errors="replace") as f:
        for line in f:
            buf.append(line)
            if line.startswith("$$$$"):
                yield "".join(buf)
                buf = []
    if buf and any(b.strip() for b in buf):
        yield "".join(buf)


def parse_tags(block):
    """{tag name: value text} for one SDF molecule block."""
    tags, lines = {}, block.splitlines()
    i = 0
    while i < len(lines):
        m = TAG_RE.match(lines[i])
        if m:
            name, vals, i = m.group(1).strip(), [], i + 1
            while i < len(lines) and lines[i].strip() and not lines[i].startswith("$$$$"):
                vals.append(lines[i])
                i += 1
            tags[name] = "\n".join(vals)
        else:
            i += 1
    return tags


def best_pose(path):
    """(score, block, tag_names) for the first pose in an _out.sdf.

    `tag_names` is returned even on failure so the caller can report what tags the file
    actually has, instead of leaving a format mismatch as a silent zero.
    """
    for block in iter_sdf_blocks(path):
        tags = parse_tags(block)
        for name, val in tags.items():
            if any(w in name.upper() for w in SCORE_TAG_WORDS):
                m = FLOAT_RE.search(val)
                if m:
                    return float(m.group(1)), block, list(tags)
        return None, block, list(tags)
    return None, None, []


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--docking-dir", required=True)
    ap.add_argument("--out-dir", default=None,
                    help="default <docking-dir>/inspect")
    ap.add_argument("--top-n", type=int, default=25,
                    help="poses kept per pocket for inspection (default 25). Output-size "
                         "parameter; the full score table is written regardless.")
    a = ap.parse_args()

    D = a.docking_dir
    OUT = a.out_dir or os.path.join(D, "inspect")
    manifest = os.path.join(D, "docking_manifest.csv")
    if not os.path.isfile(manifest):
        sys.exit(f"ERROR: no {manifest}")
    os.makedirs(OUT, exist_ok=True)

    rows = list(csv.DictReader(open(manifest)))
    print(f"{len(rows)} pockets; keeping top {a.top_n} poses each\n")

    all_scores = []
    n_pocket = n_pose = n_noscore = 0
    for r in rows:
        tag = f"{r['uniprot']}_d{r['domain']}_{r['pocket']}"
        pdir = os.path.join(D, "poses", tag)
        sdfs = sorted(glob.glob(os.path.join(pdir, "*_out.sdf")))
        if not sdfs:
            print(f"  no poses: {tag}")
            continue

        scored = []
        for p in sdfs:
            score, block, tag_names = best_pose(p)
            name = os.path.basename(p)[:-len("_out.sdf")]
            if score is None:
                if n_noscore == 0:
                    # Report the real tag names once, so a format mismatch is obvious
                    # immediately rather than arriving as "0 ligands scored".
                    print(f"  !! no score tag in {os.path.basename(p)}")
                    print(f"     tags present: {tag_names or '(none)'}")
                n_noscore += 1
                continue
            scored.append((score, name, block))
            # deck index is the trailing field of <uniprot>_<pocket>_<index>
            try:
                deck_idx = int(name.rsplit("_", 1)[-1])
            except ValueError:
                deck_idx = -1
            all_scores.append({
                "uniprot": r["uniprot"], "set_name": r["set_name"],
                "domain": r["domain"], "pocket": r["pocket"],
                "ligand": name, "deck_index": deck_idx,
                "vina_kcal_mol": score,
            })

        if not scored:
            print(f"  no parsable scores: {tag}")
            continue
        scored.sort(key=lambda t: t[0])          # more negative is better

        tdir = os.path.join(OUT, tag)
        os.makedirs(tdir, exist_ok=True)
        keep = scored[:a.top_n]
        with open(os.path.join(tdir, f"top{a.top_n}.sdf"), "w") as f:
            for _s, _n, block in keep:
                f.write(block)
        for src, dst in (("receptor.pdb", "receptor.pdb"),):
            s = os.path.join(pdir, src)
            if os.path.isfile(s):
                shutil.copy2(s, os.path.join(tdir, dst))
        ref = r.get("reference_ligand", "")
        if ref and os.path.isfile(ref):
            shutil.copy2(ref, os.path.join(tdir, "reference.pdb"))

        n_pocket += 1
        n_pose += len(scored)
        print(f"  {tag:<28}{len(scored):>7} docked   best {keep[0][0]:>7.2f} kcal/mol")

    if all_scores:
        csv_path = os.path.join(OUT, "docking_scores.csv")
        with open(csv_path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(all_scores[0].keys()))
            w.writeheader()
            w.writerows(all_scores)
        print(f"\nwrote {csv_path}  ({len(all_scores)} ligand scores)")

    print(f"{n_pocket} pockets bundled, {n_pose} ligands scored")
    if n_noscore:
        print(f"{n_noscore} pose file(s) had no parsable Uni-Dock RESULT")
    print(f"\nbundle: {OUT}")


if __name__ == "__main__":
    main()
