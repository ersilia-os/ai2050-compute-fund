#!/bin/bash
#
# Read-only progress check for a batched docking dir (run-docking-batches.sh).
#
# Reports batches done / missing, ligands docked / failed so far, and the array task ids
# that still own missing batches, as a ready-to-paste --array list.
#
# Usage (either head node):
#   check-docking.sh <dock_dir> [--failed]
#     --failed  also sum failed.csv rows by step (opens every finished batch's
#               failed.csv; slower on a large library)
#
# Only lists directories and reads small CSVs; safe while jobs are running.

set -euo pipefail

DOCK_DIR=${1:-}
[ -n "$DOCK_DIR" ] || { echo "usage: $0 <dock_dir> [--failed]"; exit 1; }
PY=${PY:-/shared/python39/bin/python3.9}
command -v "$PY" >/dev/null 2>&1 || PY=python3

"$PY" - "$DOCK_DIR" "${2:-}" <<'PYEOF'
import csv, os, sys
from collections import Counter

D, opt = sys.argv[1], sys.argv[2]
batches = list(csv.DictReader(open(os.path.join(D, "batches.csv"))))
kfile = os.path.join(D, "batches_per_task")
K = int(open(kfile).read().strip()) if os.path.isfile(kfile) else None

bdir = os.path.join(D, "batches")
names = set(os.listdir(bdir)) if os.path.isdir(bdir) else set()
done = {int(n[1:7]) for n in names if n.endswith(".scores.csv") and not n.endswith(".tmp")}
tmp = sum(1 for n in names if n.endswith(".tmp"))
ids = [int(b["batch_id"]) for b in batches]
n_lig = {int(b["batch_id"]): int(b["n"]) for b in batches}
missing = [i for i in ids if i not in done]

print(f"dock dir        : {D}")
print(f"batches         : {len(done)} / {len(ids)} done   ({len(missing)} missing)")
print(f"ligands covered : {sum(n_lig[i] for i in done):,} / {sum(n_lig.values()):,}")
print(f"in-flight tmp   : {tmp}  (files being written right now, or left by a killed task)")
errs = os.path.join(D, "errors")
if os.path.isdir(errs) and os.listdir(errs):
    print(f"Uni-Dock errors : {len(os.listdir(errs))} log(s) in {errs}")

if opt == "--failed" and done:
    steps, n_fail = Counter(), 0
    for i in sorted(done):
        p = os.path.join(bdir, f"b{i:06d}.failed.csv")
        if os.path.isfile(p):
            for r in csv.DictReader(open(p)):
                steps[r["step"]] += 1
                n_fail += 1
    print(f"failed ligands  : {n_fail:,} in finished batches  "
          + "  ".join(f"{k} {v:,}" for k, v in steps.most_common()))

# per-task stats: throughput by GPU type
tdir = os.path.join(D, "tasks")
if os.path.isdir(tdir):
    by_gpu = {}
    for n in os.listdir(tdir):
        for r in csv.DictReader(open(os.path.join(tdir, n))):
            if r.get("status") != "ok":
                continue
            g = by_gpu.setdefault(r["gpu"], [0, 0.0, 0.0])
            g[0] += int(r["n_in"])
            g[1] += sum(float(r[k] or 0) for k in ("prep_s", "ligandprep_s", "dock_s", "pack_s"))
            g[2] = max(g[2], float(r["slowest_mol_s"] or 0))
    for gpu, (n, s, slow) in sorted(by_gpu.items()):
        print(f"throughput      : {gpu:<28} {n / s * 3600 if s else 0:>9,.0f} lig/h   "
              f"slowest molecule {slow:.1f} s")

if missing:
    if K is None:
        print("\nno batches_per_task file yet: nothing has started; submit the full array")
    else:
        tasks = sorted({(i - 1) // K + 1 for i in missing})
        # compress to ranges for --array
        rng, s = [], tasks[0]
        for a, b in zip(tasks, tasks[1:] + [None]):
            if b != a + 1:
                rng.append(f"{s}-{a}" if a != s else f"{s}")
                s = b
        print(f"\ntasks with missing batches ({len(tasks)}, K={K}):")
        print(f"  sbatch --array={','.join(rng)}%4 "
              f"/shared/scripts/docking_scripts/run-docking-batches.sh {D} {K}")
else:
    print("\nall batches done")
PYEOF
