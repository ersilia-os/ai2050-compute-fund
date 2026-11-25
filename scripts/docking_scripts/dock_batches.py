#!/usr/bin/env python3
"""
Dock a range of batches from batches.csv: prep, ligandprep and Uni-Dock on node-local disk,
then pack each batch into three files on FSx. Runs INSIDE unidock.sif.

Why this layout (milestone 4a, 2026-11-25)
------------------------------------------
The October pipeline wrote ~2 FSx files per ligand (prepared SDF + _out.sdf). FSx has
~4M inodes in total, and full-library docking is ~19.4M ligands. Here every intermediate
file lives on the node's local disk and is deleted after the batch; FSx only receives

    batches/b<NNNNNN>.poses.sdf.gz   every pose of every docked ligand (title = ligand name)
    batches/b<NNNNNN>.failed.csv     name, smiles, step, reason
    batches/b<NNNNNN>.scores.csv     ligand, deck_index, pose, vina_kcal_mol

written under temporary names and renamed into place, scores.csv LAST. A batch is done if
and only if its scores.csv exists, so a task killed mid-batch (spot reclaim, 24 h limit)
leaves nothing that looks finished, and re-running the same task redoes only that batch.

Per batch
---------
1. Its SMILES slice of ligands/<tag>.smi (rows start..end of batches.csv).
2. prepare() from prepare_ligands.py, unchanged, in a process pool over the node's CPUs:
   neutralise (no pH model), AddHs, ETKDGv3 with the fixed seed, MMFF94. The seed is per
   molecule, so the output does not depend on the worker count. NO per-molecule timeout
   (decision 2026-11-25); the slowest molecule of each batch is logged instead.
3. `unidocktools ligandprep` (torsion tree, atom types, charges).
4. `unidock` with the settings decided 2026-10-01/02: vina, balance, explicit seed, box from
   docking_manifest.csv (reference ligand + 6 A), --num_modes 5 (decided 2026-11-23).
5. Pack, rename into place, delete the local directory.

Receptors are prepared once per pocket into receptors/<tag>.pdbqt (shared cache, written
atomically) and reused by every batch and task. A receptor with ZERO hydrogens is refused:
Vina needs the polar H to type donors, and proteinprep does not add them (see
prepare_receptors.py). That pocket's batches are skipped and the task exits non-zero.

Per-task statistics go to tasks/<job>_<task>.csv, one row per batch (GPU name, counts,
prep / ligandprep / dock seconds, slowest molecule).

Usage (normally via run-docking-batches.sh):
    python dock_batches.py --dock-dir D --task-id T --per-task K [--local-dir /tmp/x]
    python dock_batches.py --dock-dir D --task-id 1 --per-task 1 --no-dock   # prep only
"""

import argparse
import csv
import gzip
import io
import itertools
import multiprocessing as mp
import os
import shutil
import subprocess
import sys
import time

from rdkit import Chem, RDLogger
from rdkit.Chem.MolStandardize import rdMolStandardize

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from prepare_ligands import prepare                                      # noqa: E402
from collect_top_poses import iter_sdf_blocks, parse_tags, SCORE_TAG_WORDS, FLOAT_RE  # noqa: E402

MAX_CONSECUTIVE_DOCK_FAILURES = 3      # a broken GPU fails every batch; stop wasting the node

SCORE_FIELDS = ["ligand", "deck_index", "pose", "vina_kcal_mol"]
FAIL_FIELDS = ["name", "smiles", "step", "reason"]
STAT_FIELDS = ["batch_id", "tag", "gpu", "n_in", "n_prepped", "n_prep_failed",
               "n_ligandprep", "n_docked", "n_poses", "prep_s", "slowest_mol_s",
               "slowest_mol", "ligandprep_s", "dock_s", "pack_s", "status"]


class ReceptorError(Exception):
    pass


# ---------------------------------------------------------------- 3D prep (worker side)
_UNCHARGER = None
_SEED = None


def _init_worker(seed):
    global _UNCHARGER, _SEED
    RDLogger.DisableLog("rdApp.*")
    _UNCHARGER = rdMolStandardize.Uncharger()
    _SEED = seed


def _prep_one(item):
    """(name, smiles, sdf block or None, (step, reason) or None, seconds)."""
    smiles, name = item
    t0 = time.perf_counter()
    try:
        mol, err = prepare(smiles, _SEED, _UNCHARGER)
    except Exception as e:                           # never let one molecule kill a batch
        mol, err = None, ("exception", f"{type(e).__name__}: {e}")
    dt = time.perf_counter() - t0
    if mol is None:
        return name, smiles, None, err, dt
    mol.SetProp("_Name", name)
    sio = io.StringIO()
    w = Chem.SDWriter(sio)
    w.write(mol)
    w.close()
    return name, smiles, sio.getvalue(), None, dt


# ---------------------------------------------------------------- helpers
def read_csv(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def write_csv(path, fields, rows):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)


def read_slice(path, start, end):
    """[(smiles, name)] for data lines start..end (0-based, end exclusive) of a .smi."""
    out = []
    with open(path) as f:
        for line in itertools.islice(f, start, end):
            parts = line.split()
            if len(parts) >= 2:
                out.append((parts[0], parts[1]))
    if len(out) != end - start:
        raise RuntimeError(f"{path}: expected {end - start} lines at {start}, got {len(out)}")
    return out


def is_hydrogen(line):
    el = line[76:78].strip()
    if el:
        return el.upper() == "H"
    return line[12:16].strip().upper().startswith("H")


def run(cmd, log_path):
    """Run a command, stdout+stderr to log_path. Returns (exit code, seconds)."""
    t0 = time.time()
    with open(log_path, "w") as log:
        rc = subprocess.call(cmd, stdout=log, stderr=subprocess.STDOUT)
    return rc, time.time() - t0


def tail(path, n=15):
    try:
        with open(path, errors="replace") as f:
            return "".join(f.readlines()[-n:])
    except OSError:
        return ""


def gpu_name():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
                             capture_output=True, text=True, timeout=30).stdout
        return out.strip().splitlines()[0] if out.strip() else "none"
    except Exception:
        return "none"


def pose_score(block):
    for name, val in parse_tags(block).items():
        if any(w in name.upper() for w in SCORE_TAG_WORDS):
            m = FLOAT_RE.search(val)
            if m:
                return float(m.group(1))
    return None


def deck_index(name):
    try:
        return int(name.rsplit("_", 1)[-1])
    except ValueError:
        return -1


def publish(src, dst):
    """Copy a local file to FSx under a temporary name, then rename into place."""
    tmp = f"{dst}.{os.getpid()}.tmp"
    shutil.copyfile(src, tmp)
    os.replace(tmp, dst)


# ---------------------------------------------------------------- receptor cache
def receptor_pdbqt(mrow, dock_dir, work):
    """Path to receptors/<tag>.pdbqt, preparing it if this is the first use of the pocket."""
    tag = mrow["tag"]
    cache = os.path.join(dock_dir, "receptors", f"{tag}.pdbqt")
    if os.path.isfile(cache) and os.path.getsize(cache) > 0:
        return cache
    src = mrow["receptor"]
    if not os.path.isfile(src):
        raise ReceptorError(f"receptor not found: {src}")
    with open(src) as f:
        lines = [ln for ln in f if ln.startswith(("ATOM", "TER", "END"))]
    n_atom = sum(1 for ln in lines if ln.startswith("ATOM"))
    n_h = sum(1 for ln in lines if ln.startswith("ATOM") and is_hydrogen(ln))
    if n_h == 0:
        raise ReceptorError(
            f"{src} has {n_atom} atoms and ZERO hydrogens (receptor_prep="
            f"{mrow.get('receptor_prep', '?')}). Vina needs polar H to type donors; run "
            "prepare_receptors.py, stage <U>/protonated/, and rebuild the manifest.")
    rdir = os.path.join(work, f"receptor_{tag}")
    os.makedirs(rdir, exist_ok=True)
    pdb = os.path.join(rdir, "receptor.pdb")
    with open(pdb, "w") as f:
        f.writelines(lines)
    local = os.path.join(rdir, "receptor.pdbqt")
    rc, sec = run(["unidocktools", "proteinprep", "-r", pdb, "-o", local],
                  os.path.join(rdir, "proteinprep.log"))
    if rc != 0 or not os.path.isfile(local) or os.path.getsize(local) == 0:
        raise ReceptorError(f"proteinprep failed for {tag} (exit {rc}):\n"
                            + tail(os.path.join(rdir, "proteinprep.log")))
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    publish(local, cache)
    print(f"  receptor {tag}: {n_atom} atoms, {n_h} H, proteinprep {sec:.0f} s -> {cache}",
          flush=True)
    return cache


# ---------------------------------------------------------------- one batch
def dock_batch(b, mrow, receptor, a, pool, work, gpu):
    """Dock one batch. Returns a stats dict; status 'ok', 'no_dock' or 'dock_failed'."""
    bid = int(b["batch_id"])
    stem = f"b{bid:06d}"
    bdir = os.path.join(work, stem)
    shutil.rmtree(bdir, ignore_errors=True)
    os.makedirs(bdir)
    st = {k: "" for k in STAT_FIELDS}
    st.update(batch_id=bid, tag=b["tag"], gpu=gpu)

    items = read_slice(mrow["ligand_file"], int(b["start"]), int(b["end"]))
    st["n_in"] = len(items)
    smiles_of = {name: smi for smi, name in items}

    # 1. 3D prep, in input order
    t0 = time.time()
    failed, blocks, slowest = [], [], (0.0, "")
    for name, smi, block, err, dt in pool.imap(_prep_one, items, chunksize=4):
        if dt > slowest[0]:
            slowest = (dt, name)
        if block is None:
            failed.append({"name": name, "smiles": smi, "step": err[0], "reason": err[1]})
        else:
            blocks.append((name, block))
    st.update(prep_s=round(time.time() - t0, 1), slowest_mol_s=round(slowest[0], 2),
              slowest_mol=slowest[1], n_prepped=len(blocks), n_prep_failed=len(failed))

    # 2. ligandprep
    lig3d = os.path.join(bdir, "ligands_3d.sdf")
    with open(lig3d, "w") as f:
        f.writelines(blk for _n, blk in blocks)
    ligprep = os.path.join(bdir, "ligprep")
    os.makedirs(ligprep)
    names_ok = []
    if blocks:
        rc, sec = run(["unidocktools", "ligandprep", "-l", lig3d, "-sd", ligprep, "-sf", "sdf"],
                      os.path.join(bdir, "ligandprep.log"))
        st["ligandprep_s"] = round(sec, 1)
        for name, _blk in blocks:
            if os.path.isfile(os.path.join(ligprep, f"{name}.sdf")):
                names_ok.append(name)
            else:
                failed.append({"name": name, "smiles": smiles_of[name], "step": "ligandprep",
                               "reason": f"no output (ligandprep exit {rc})"})
    st["n_ligandprep"] = len(names_ok)

    if a.no_dock:
        st["status"] = "no_dock"
        print(f"  {stem} --no-dock: {len(items)} in, {len(blocks)} prepped, "
              f"{len(names_ok)} through ligandprep; local files kept in {bdir}", flush=True)
        return st

    # 3. Uni-Dock
    outdir = os.path.join(bdir, "out")
    os.makedirs(outdir)
    if names_ok:
        paths = [os.path.join(ligprep, f"{n}.sdf") for n in names_ok]
        cmd = ["unidock", "--receptor", receptor]
        if a.ligand_input == "index":
            idx = os.path.join(bdir, "ligand_index.txt")
            with open(idx, "w") as f:
                f.write("\n".join(paths) + "\n")
            cmd += ["--ligand_index", idx]
        else:
            cmd += ["--gpu_batch"] + paths
        cmd += ["--scoring", a.scoring, "--search_mode", a.search_mode, "--seed", str(a.seed),
                "--center_x", mrow["center_x"], "--center_y", mrow["center_y"],
                "--center_z", mrow["center_z"], "--size_x", mrow["size_x"],
                "--size_y", mrow["size_y"], "--size_z", mrow["size_z"],
                "--num_modes", str(a.num_modes), "--dir", outdir]
        dlog = os.path.join(bdir, "unidock.log")
        rc, sec = run(cmd, dlog)
        st["dock_s"] = round(sec, 1)
        if rc != 0:
            os.makedirs(os.path.join(a.dock_dir, "errors"), exist_ok=True)
            publish(dlog, os.path.join(a.dock_dir, "errors", f"{stem}.unidock.log"))
            print(f"  {stem} Uni-Dock exit {rc} - batch NOT marked done; log in errors/\n"
                  + tail(dlog, 8), flush=True)
            st["status"] = "dock_failed"
            shutil.rmtree(bdir, ignore_errors=True)
            return st

    # 4. pack
    t0 = time.time()
    scores, n_docked = [], 0
    gz_local = os.path.join(bdir, f"{stem}.poses.sdf.gz")
    with gzip.open(gz_local, "wt", compresslevel=6) as gz:
        for name in names_ok:
            out = os.path.join(outdir, f"{name}_out.sdf")
            poses = list(iter_sdf_blocks(out)) if os.path.isfile(out) else []
            got = 0
            for i, blk in enumerate(poses, 1):
                s = pose_score(blk)
                if s is None:
                    continue
                lines = blk.split("\n", 1)
                gz.write(name + "\n" + (lines[1] if len(lines) > 1 else ""))
                scores.append({"ligand": name, "deck_index": deck_index(name),
                               "pose": i, "vina_kcal_mol": s})
                got += 1
            if got:
                n_docked += 1
            else:
                failed.append({"name": name, "smiles": smiles_of[name], "step": "dock",
                               "reason": "no scored pose written"})
    st.update(n_docked=n_docked, n_poses=len(scores))

    fail_local = os.path.join(bdir, f"{stem}.failed.csv")
    write_csv(fail_local, FAIL_FIELDS, failed)
    scores_local = os.path.join(bdir, f"{stem}.scores.csv")
    write_csv(scores_local, SCORE_FIELDS, scores)

    dst = os.path.join(a.dock_dir, "batches")
    publish(gz_local, os.path.join(dst, f"{stem}.poses.sdf.gz"))
    publish(fail_local, os.path.join(dst, f"{stem}.failed.csv"))
    publish(scores_local, os.path.join(dst, f"{stem}.scores.csv"))      # LAST = done
    st["pack_s"] = round(time.time() - t0, 1)
    st["status"] = "ok"
    shutil.rmtree(bdir, ignore_errors=True)
    return st


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dock-dir", required=True,
                    help="holds docking_manifest.csv, batches.csv, ligands/")
    ap.add_argument("--task-id", type=int, required=True, help="1-based array task id")
    ap.add_argument("--per-task", type=int, required=True,
                    help="batches per task (K); task T runs batch ids (T-1)K+1 .. TK")
    ap.add_argument("--local-dir", default=None,
                    help="node-local scratch (default $SLURM_TMPDIR or /tmp)")
    ap.add_argument("--workers", type=int, default=0,
                    help="3D-prep processes (default: CPUs in this process's affinity set)")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--scoring", default="vina")
    ap.add_argument("--search-mode", default="balance")
    ap.add_argument("--num-modes", type=int, default=5)
    ap.add_argument("--ligand-input", choices=["index", "gpu_batch"], default="index",
                    help="pass ligands to Uni-Dock via --ligand_index (default) or as "
                         "--gpu_batch arguments (the October way)")
    ap.add_argument("--no-dock", action="store_true",
                    help="prep + ligandprep only, write nothing to the dock dir (testing)")
    a = ap.parse_args()

    D = a.dock_dir
    manifest = read_csv(os.path.join(D, "docking_manifest.csv"))
    batches = read_csv(os.path.join(D, "batches.csv"))
    if manifest and "tag" not in manifest[0]:
        sys.exit("ERROR: docking_manifest.csv has no 'tag' column; rebuild it with the "
                 "current make_docking_manifest.py")

    # K is fixed per dock dir: check-docking.sh maps missing batches back to task ids with it
    kfile = os.path.join(D, "batches_per_task")
    if os.path.isfile(kfile):
        k_old = int(open(kfile).read().strip())
        if k_old != a.per_task:
            sys.exit(f"ERROR: {D} was started with {k_old} batches per task, not "
                     f"{a.per_task}. Keep the same value so task ids stay meaningful.")
    elif not a.no_dock:
        tmp = f"{kfile}.{os.getpid()}.tmp"
        with open(tmp, "w") as f:
            f.write(f"{a.per_task}\n")
        os.replace(tmp, kfile)

    lo, hi = (a.task_id - 1) * a.per_task + 1, a.task_id * a.per_task
    mine = [b for b in batches if lo <= int(b["batch_id"]) <= hi]
    if not mine:
        print(f"task {a.task_id}: no batches in {lo}..{hi} (library has {len(batches)})")
        return

    done_dir = os.path.join(D, "batches")
    os.makedirs(done_dir, exist_ok=True)
    todo = [b for b in mine if not os.path.isfile(
        os.path.join(done_dir, f"b{int(b['batch_id']):06d}.scores.csv"))]

    job = os.environ.get("SLURM_ARRAY_JOB_ID") or os.environ.get("SLURM_JOB_ID") or "manual"
    base = a.local_dir or os.environ.get("SLURM_TMPDIR") or "/tmp"
    work = os.path.join(base, f"dock_{job}_{a.task_id}")
    os.makedirs(work, exist_ok=True)
    n_workers = a.workers or len(os.sched_getaffinity(0))
    gpu = gpu_name()

    print(f"task {a.task_id}: batches {lo}..{hi}: {len(mine)} assigned, "
          f"{len(mine) - len(todo)} already done, {len(todo)} to do")
    print(f"  GPU {gpu}   3D workers {n_workers}   local {work}")
    print(f"  {a.scoring} / {a.search_mode} / seed {a.seed} / num_modes {a.num_modes} / "
          f"ligands via {a.ligand_input}", flush=True)
    if not todo:
        return

    stats_path = os.path.join(D, "tasks", f"{job}_{a.task_id}.csv")
    if not a.no_dock:
        os.makedirs(os.path.dirname(stats_path), exist_ok=True)

    by_row = {i: r for i, r in enumerate(manifest, 1)}
    bad_receptor, n_fail, consecutive = {}, 0, 0
    ctx = mp.get_context("fork")
    with ctx.Pool(n_workers, initializer=_init_worker, initargs=(a.seed,)) as pool:
        for b in todo:
            mrow = by_row[int(b["manifest_row"])]
            tag = mrow["tag"]
            if tag in bad_receptor:
                n_fail += 1
                continue
            try:
                receptor = receptor_pdbqt(mrow, D, work) if not a.no_dock else ""
            except ReceptorError as e:
                print(f"  RECEPTOR ERROR {tag}: {e}", flush=True)
                bad_receptor[tag] = str(e)
                n_fail += 1
                continue

            t0 = time.time()
            st = dock_batch(b, mrow, receptor, a, pool, work, gpu)
            if not a.no_dock:
                new = not os.path.isfile(stats_path)
                with open(stats_path, "a", newline="") as f:
                    w = csv.DictWriter(f, fieldnames=STAT_FIELDS)
                    if new:
                        w.writeheader()
                    w.writerow(st)
            if st["status"] == "dock_failed":
                n_fail += 1
                consecutive += 1
                if consecutive >= MAX_CONSECUTIVE_DOCK_FAILURES:
                    print(f"ABORT: {consecutive} consecutive Uni-Dock failures on "
                          f"{os.uname().nodename} ({gpu})", flush=True)
                    break
                continue
            consecutive = 0
            if st["status"] == "ok":
                rate = st["n_in"] / max(time.time() - t0, 1)
                print(f"  b{int(b['batch_id']):06d} {tag:<28} in {st['n_in']:>5}  "
                      f"docked {st['n_docked']:>5}  failed {st['n_in'] - st['n_docked']:>4}  "
                      f"prep {st['prep_s']} s (slowest {st['slowest_mol_s']} s)  "
                      f"ligandprep {st['ligandprep_s']} s  dock {st['dock_s']} s  "
                      f"{rate * 3600:,.0f} lig/h", flush=True)

    if not a.no_dock:
        shutil.rmtree(work, ignore_errors=True)
    if bad_receptor:
        print(f"\n{len(bad_receptor)} pocket(s) refused for their receptor: "
              + ", ".join(sorted(bad_receptor)))
    if n_fail:
        print(f"{n_fail} batch(es) not done in this task; resubmit the same task id")
        sys.exit(1)
    print("all assigned batches done")


if __name__ == "__main__":
    main()
