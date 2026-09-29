# pocket_rebuild — recovering the DrugCLIP authors' real pockets

Self-contained toolkit for the pocket-side investigation. **Nothing here modifies anything
that already exists** — no script under `scripts/drugclip_scripts/` is edited, and no
existing pocket set or result directory is written to. The originals are copied and adapted
so the current `/fsx/input/targets` set stays exactly reproducible.

See [docs/05_drugclip_validation.md](../../../docs/05_drugclip_validation.md)
for the result. See the approved plan at
`~/.claude/plans/i-think-that-one-iterative-knuth.md` for the reasoning.

## The problem in one paragraph

Our 339 pockets come from two different detection routes, and the naming tells you which:
a bare-integer pocket token (`..._0_3`) means **template matching** — a real PDBbind ligand
mapped onto the AlphaFold superdomain by TM-align — while `pocketN` means **Fpocket +
GenPack**, an AI-generated ligand. The two perform very differently (median pocket AUC
**0.507 vs 0.603**; paired within-target +0.091, p = 5×10⁻⁴), and the template route sits at
chance. For the template route the defining ligand is recoverable: the source PDB code is in
the refined-conformer filename (`..._4_5orz_complex_refined.pdb`). This toolkit fetches it,
superposes it onto our AlphaFold conformation, and rebuilds the pocket the way the paper
defines it — *"residues with at least one heavy atom within a 6 Å radius of the ligand"*.

## Where things go

| | existing (read-only) | new |
|---|---|---|
| pockets, laptop | `Documents/AI2050/Targets/targets/` | `Documents/AI2050/Targets/targets_ligand/` |
| pockets, cluster | `/fsx/input/targets/` | `/fsx/input/targets_ligand/`, `/fsx/input/targets_a511/` |
| results | `enrichment_out/`, `enrichment_out_centered/` | `enrichment_out_ligand/`, `enrichment_out_a511/` |

`submit-pocket-encode.sh` and `stage-ligand-pockets.sh` both **refuse** to write to the
production `targets` path, regardless of flags.

## Scripts

| Script | Where | Role |
|---|---|---|
| `recover_template_ligands.py` | laptop | fetch RCSB entry → `cealign` onto the AF conformer → pick the pocket ligand → write `_LIG.pdb` + manifest |
| `compare_pocket_geometry.py` | laptop | 6 Å residue sets under both definitions → IoU, centroid offset, Spearman vs AUC |
| `pymol_pocket_session.py` | laptop | PyMOL view of ours vs theirs; `--mode emit` prints commands for a live session / the MCP |
| `run-pocket-encode.sh` | cluster | sbatch job; `--max-pocket-atoms` parameterised (copy of `run-drugclip-pocket-job.sh`) |
| `submit-pocket-encode.sh` | cluster | fan-out over a pocket base; `--clone-from` and `--max-pocket-atoms` |
| `stage-ligand-pockets.sh` | laptop | validate + upload pre-built pockets to a new S3/FSx prefix |

`recover_template_ligands.py` and `pymol_pocket_session.py --mode session` need PyMOL, so run
them with **`/home/marina/anaconda3/bin/python`**. The other two work with any Python 3 + numpy.

## Workflow

```bash
cd scripts/drugclip_scripts/pocket_rebuild
T=/home/marina/Documents/AI2050/Targets

# 1. recover the authors' true ligands (582 conformations, 415 RCSB entries, cached)
/home/marina/anaconda3/bin/python recover_template_ligands.py \
    --targets-dir $T/targets --out-base $T/targets_ligand --pdb-cache $T/pdb_cache
#    watch the "not-clean fraction" line: >20% means the superposition is unsound,
#    and per the plan Phase 4 must not proceed on that basis

# 2. how far is our pocket from theirs?  (the go/no-go for a rebuild)
python3 compare_pocket_geometry.py \
    --true-base    $T/targets_ligand \
    --current-base /home/marina/fpocket_staging/targets_fpocket \
    --enrichment   ../../../enrichment_out \
    --out pocket_geometry.csv

# 3. look at the AUC extremes — emit commands into the live PyMOL via the MCP
python3 pymol_pocket_session.py --uniprot P04049 --pocket 2 \
    --true-base $T/targets_ligand --current-base /home/marina/fpocket_staging/targets_fpocket
#    or render headless:
/home/marina/anaconda3/bin/python pymol_pocket_session.py --uniprot P04049 --pocket 2 \
    --true-base $T/targets_ligand --mode session --out P04049_p2.pse --png
```

On the cluster — **run by Marina, not by Claude.** Everything below is submitted by hand;
nothing in this repo should `sbatch`, `ssh`, or `aws s3 sync` on your behalf.

```bash
# Phase 0 — the free control: same pockets, 256 -> 511, nothing else changed
POCKET_BASE=/fsx/input/targets_a511 \
  bash submit-pocket-encode.sh --clone-from /fsx/input/targets --max-pocket-atoms 511
TARGETS_BASE=/fsx/input/targets_a511 VAL_TAG=a511 \
  bash /shared/scripts/drugclip_scripts/validation/run-validation.sh enrich cpu-queue

# Phase 4 — the true-ligand rebuild
bash stage-ligand-pockets.sh $T/targets_ligand          # from the laptop
POCKET_BASE=/fsx/input/targets_ligand \
  bash submit-pocket-encode.sh --max-pocket-atoms 511   # on the head node
TARGETS_BASE=/fsx/input/targets_ligand VAL_TAG=ligand \
  bash /shared/scripts/drugclip_scripts/validation/run-validation.sh enrich cpu-queue
```

Only the **encoding** needs a GPU, and it is small — 582 conformations, minutes. The molecule
deck is untouched, so nothing is re-encoded on the molecule side.

## Reading the results honestly

- **Compare like for like.** The rebuild covers 157 of 339 pockets. The headline comparison is
  new-vs-old restricted to *those same 157 pockets and their 57 targets*, never the full table.
- **Success needs two things**, both stated before running: template-route AUC rises from
  0.507 toward 0.603+, **and** the per-target count beating its own mismatched control rises
  above 42/66. AUC moving while the control count does not is the same non-result as the
  hubness centering, and should be reported as such.
- **EF@1% is not the metric.** With ~127 actives in 35,931 molecules the top 1% expects 1.27
  hits. Use EF@5% and AUC, as the validation README explains.

## Gotchas inherited from upstream

- **Pocket tokens are never normalised.** `"2"` and `"pocket2"` are different pockets. Every
  script here matches them literally.
- **The filename mangling is load-bearing.** Output stems replace `_` with `-` so the name has
  exactly one underscore, right before `_LIG` — `encode_pockets.py:134` parses the ligand name
  with a greedy `_.*\.` regex. Break this and the `pocket_key` join fails silently.
- **`process_one_pdbdir` swallows errors** with a bare `except: pass`, so a malformed PDB just
  vanishes from the lmdb. `run-pocket-encode.sh` compares the pocket count against the `*.pdb`
  count and warns on a mismatch rather than trusting the run.
- **The 6 Å cutoff is hard-coded** in `encode_pockets.py:102` and cannot be set from the CLI —
  which is why pocket geometry has to be controlled through the ligand we supply.
