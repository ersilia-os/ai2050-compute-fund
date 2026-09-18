# Phase 0 — re-encode the existing pockets at `--max-pocket-atoms 511`

Same pockets, same centres, same dummy ligand, same weights. **One changed integer.**

The production set used 256; upstream `encode_pocket.sh:16` uses 511. 28% of our pockets
exceed 256 heavy atoms, and above the limit `CroppingPocketDataset` takes a seeded random
subsample weighted *toward* the centroid — so it preferentially discards the pocket periphery.

Everything is written to **`/fsx/input/targets_a511/`**. `/fsx/input/targets/` is read once
and never written to.

> Honest expectation, set before running: the evidence for the crop is weaker than it first
> looked. On the 77 pockets measurable locally, over-256 pockets score 0.536 vs 0.604 for
> under-256 — but that **reverses within the template route** (0.507 vs 0.482), so much of the
> gap is route composition rather than cropping. This is worth running because it is cheap and
> definitive, not because it is likely.

---

## 1. Laptop — ship the scripts to the cluster

```bash
ssh ai2050cluster 'mkdir -p /shared/scripts/drugclip_scripts/pocket_rebuild'

rsync -av --chmod=F755 \
    /home/marina/ersilia/AI2050-Compute-Fund/scripts/drugclip_scripts/pocket_rebuild/ \
    ai2050cluster:/shared/scripts/drugclip_scripts/pocket_rebuild/
```

## 2. Head node — dry run first

```bash
ssh ai2050cluster
cd /shared/scripts/drugclip_scripts/pocket_rebuild

POCKET_BASE=/fsx/input/targets_a511 \
  bash submit-pocket-encode.sh \
      --clone-from /fsx/input/targets \
      --max-pocket-atoms 511 \
      --dry-run
```

Expect: 66 targets listed, the per-target PDB counts, **no jobs submitted, nothing copied**.
If it prints `ERROR: POCKET_BASE is the production set`, the guard is doing its job — fix the
variable, don't bypass it.

## 3. Head node — clone and submit

```bash
POCKET_BASE=/fsx/input/targets_a511 \
  bash submit-pocket-encode.sh \
      --clone-from /fsx/input/targets \
      --max-pocket-atoms 511 \
      --max-pending 8
```

The clone copies ~2,264 conformation PDBs (~1.5 GB) and copies **only** `*.pdb` and
`manifest.csv` — no `pocket_reps.pkl`, no `pocket.lmdb`. It is not instant; a slow first step
is not a hang.

## 4. Monitor

```bash
watch -n 10 'squeue -u $USER'

# one job's log
tail -f /shared/logs/pocket-encode-<JOBID>.out

# anything that failed
grep -l ERROR /shared/logs/pocket-encode-*.out
```

## 5. Confirm every target encoded

```bash
echo "encoded: $(ls /fsx/input/targets_a511/*/pockets/pocket_reps.pkl 2>/dev/null | wc -l) / 66"

# per-target pocket counts, and any target whose pkl is missing
for d in /fsx/input/targets_a511/*/pockets; do
    t=$(basename $(dirname $d))
    [ -f "$d/pocket_reps.pkl" ] || echo "  MISSING $t ($(ls $d/*.pdb 2>/dev/null | wc -l) pdb)"
done
```

## 6. The control — under-256 pockets must be unchanged

**This is the step that makes the experiment valid.** Pockets below the limit were never
cropped, so they must come back the same. If they moved, something other than the crop
changed and the run cannot be interpreted.

Use `verify_crop_control.py` — it caches pocket sizes (measuring ~2,264 PDBs off FSx is the
slow part and you will want to re-run this), prints progress, and ends with one of three
verdicts: **VALID**, **INVALID**, or **NULL RESULT**.

```bash
cd /shared/scripts/drugclip_scripts/pocket_rebuild

/shared/python39/bin/python3.9 verify_crop_control.py \
    --old-base /fsx/input/targets \
    --new-base /fsx/input/targets_a511 \
    --threshold 256 \
    --cache ~/pocket_atom_counts.csv \
    --out   ~/crop_control.csv
```

Only run step 7 if this prints **VALID**.

<details>
<summary>Equivalent inline version (superseded — kept for reference)</summary>

```bash
/shared/python39/bin/python3.9 - <<'PY'
import pickle, csv, glob, os
import numpy as np
from collections import defaultdict

def pocket_atoms(path):
    """Heavy atoms within 6 A of the LIG ligand - upstream's rule, encode_pockets.py:102."""
    prot = defaultdict(list); lig = []
    for l in open(path):
        if l.startswith('ATOM'):
            prot[(l[21], l[22:27])].append(
                (float(l[30:38]), float(l[38:46]), float(l[46:54])))
        elif l.startswith('HETATM'):
            lig.append((float(l[30:38]), float(l[38:46]), float(l[46:54])))
    L = np.array(lig)
    if not len(L):
        return 0
    return sum(len(v) for v in prot.values()
               if np.linalg.norm(np.array(v)[:, None, :] - L[None, :, :], axis=-1).min() <= 6.0)

under, over, missing = [], [], 0
for new_pkl in sorted(glob.glob('/fsx/input/targets_a511/*/pockets/pocket_reps.pkl')):
    pdir = os.path.dirname(new_pkl)
    tid  = pdir.split('/')[4]
    old_pkl = f'/fsx/input/targets/{tid}/pockets/pocket_reps.pkl'
    if not os.path.exists(old_pkl):
        missing += 1; continue
    on, orp = pickle.load(open(old_pkl, 'rb'))
    nn, nrp = pickle.load(open(new_pkl, 'rb'))
    orp, nrp = np.asarray(orp, dtype=np.float64), np.asarray(nrp, dtype=np.float64)
    oi = {n: i for i, n in enumerate(on)}
    # map pocket_key -> pocket_file via the manifest (read from the NEW tree)
    f2 = {r['pocket_key']: r['pocket_file']
          for r in csv.DictReader(open(os.path.join(pdir, 'manifest.csv')))}
    for j, name in enumerate(nn):
        if name not in oi or name not in f2:
            continue
        p = os.path.join(pdir, f2[name])
        if not os.path.exists(p):
            continue
        # per-fold cosine, averaged over the 6 folds (each 128-block is unit-norm)
        cos = float(np.einsum('fd,fd->', orp[oi[name]], nrp[j]) / orp.shape[1])
        (over if pocket_atoms(p) > 256 else under).append(cos)

print(f"targets compared: {len(glob.glob('/fsx/input/targets_a511/*/pockets/pocket_reps.pkl')) - missing}")
print()
print(f"UNDER 256 atoms  n={len(under):4d}  cosine median "
      f"{np.median(under) if under else float('nan'):.6f}  min {min(under) if under else float('nan'):.6f}")
print(f"OVER  256 atoms  n={len(over):4d}  cosine median "
      f"{np.median(over) if over else float('nan'):.6f}  min {min(over) if over else float('nan'):.6f}")
print()
print(f"  under-256 with cosine < 0.999 : {sum(c < 0.999 for c in under)}   <-- expect ~0")
print(f"  over-256  with cosine < 0.999 : {sum(c < 0.999 for c in over)}    <-- expect most")
print()
if under and np.median(under) < 0.999:
    print("  INVALID: pockets that were never cropped changed anyway.")
    print("           Something other than --max-pocket-atoms differs; do not interpret the AUC.")
elif over and np.median(over) > 0.999:
    print("  NULL RESULT: even the over-256 pockets barely moved, so the crop was")
    print("               doing almost nothing. Expect no AUC change.")
else:
    print("  VALID: only the over-256 pockets moved. The AUC comparison is interpretable.")
PY
```

</details>

`--fp16` makes the encoder mildly non-deterministic, so "unchanged" means cosine > 0.999
rather than bit-identical.

## 7. Score — CPU queue, no molecule re-encoding

```bash
TARGETS_BASE=/fsx/input/targets_a511 VAL_TAG=a511 \
  bash /shared/scripts/drugclip_scripts/validation/run-validation.sh enrich cpu-queue
```

Results land in `/fsx/output/validation_leaders/enrichment_a511/` and sync to
`s3://ai2050-ersilia-cluster/output/validation_leaders/enrichment_a511/`.
`enrichment/` (your current results) is untouched.

The molecule deck is unchanged — `validation_leaders` embeddings are reused, nothing is
re-encoded on the molecule side.

```bash
# monitor
squeue -u $USER | grep drugclip-enrich
tail -f /shared/logs/drugclip-enrich-<JOBID>.out
```

## 8. Laptop — pull the results down

```bash
aws s3 sync s3://ai2050-ersilia-cluster/output/validation_leaders/enrichment_a511/ \
    /home/marina/ersilia/AI2050-Compute-Fund/enrichment_out_a511/
```

Then the comparison is run locally against `enrichment_out/`, split by whether each pocket was
over or under 256 atoms — only the over-256 group should move.

---

## If it goes wrong

Nothing needs undoing on the production side. To start over:

```bash
rm -rf /fsx/input/targets_a511
```

`/fsx/input/targets/`, `/fsx/output/validation_leaders/enrichment/`, and every existing
`pocket_reps.pkl` are never written to by any step above.

## Note for Phase 4 later

`run-validation.sh` passes `--pockets-index /fsx/input/validation_leaders/pockets_index.csv`,
which is shared across pocket sets. For Phase 0 that is correct — `targets_a511` has identical
filenames and `pocket_key`s to `targets`. For the **true-ligand** set it will not be: only 157
of 339 pockets exist there, so the index will reference pockets with no embedding. Check how
`enrichment_validation.py` handles the missing rows before running Phase 4, rather than
assuming it drops them cleanly.
