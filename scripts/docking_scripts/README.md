# Docking scripts — Uni-Dock on the AL2023 GPU cluster

Uni-Dock 1.2.0 (GPU Vina) packaged as `unidock.sif`. It runs on `gpu-queue` of the
AL2023 cluster through `apptainer exec --nv`, following the same pattern as `drugclip.sif`.
Ligand and receptor preparation is inside the same image.

## Pipeline

```
receptor : *_complex_refined.pdb (has H) ─► unidocktools proteinprep ─► receptor.pdbqt
ligand   : SMILES ─► prepare_ligands.py ─► unidocktools ligandprep ─► torsion-tree SDF
box      : reference ligand (_LIG.pdb) ─► compute_box.py ─► --center_* / --size_*
dock     : unidock --gpu_batch <SDF> --scoring vina --search_mode balance --seed N
```

The two `unidock_tools` steps do less than their names suggest:
- **`proteinprep`** reads the PDB with RDKit, keeping its hydrogens, then adds Gasteiger
  charges and AutoDock atom types. It does **not** add hydrogens or protonate, so the
  receptor must already have them. The Schrödinger-refined conformers do; the protein
  records in `_LIG.pdb` do not.
- **`ligandprep`** builds the torsion tree, atom types and charges. It does **not** add
  hydrogens, protonate or embed, and it needs an existing 3D conformer. That is what
  `prepare_ligands.py` provides.

## Production pipeline (batched, 2026-11-25)

Full-library docking (milestone 4a). Each molecule is docked once, into the pocket DrugCLIP
scored highest. The October per-pocket scripts (`prep-ligands-array.sh`,
`run-docking-array.sh`, `collect_top_poses.py`) wrote ~2 FSx files per ligand. FSx has
~4M inodes, and five libraries are ~19.4M ligands, so the batched pipeline keeps every
intermediate on node-local disk and writes **3 files per batch** of ~1,000 ligands.

```
0. Mtb receptors (once, laptop)  prepare_receptors.py  -> <U>/protonated/<stem>_H.pdb -> S3
1. work list                     make_docking_manifest.py -> docking_manifest.csv, batches.csv, ligands/
2. dock (gpu-queue)              run-docking-batches.sh -> dock_batches.py (inside unidock.sif)
3. progress / resubmit           check-docking.sh
4. collect                       collect_docking.py -> inspect/docking_scores.csv + top-N poses
```

**Receptor hydrogens.** `proteinprep` never adds hydrogens, and Vina needs the polar H to
type donors. Human receptors are Schrödinger-refined (they have H). The `targets_mtb_v2`
receptors are raw AlphaFold models, so `prepare_receptors.py` protonates them with
PDBFixer at pH 7.4 (decision 2026-11-25). It runs once on the laptop (`clpp` env) and
stops if a model has chain breaks. The manifest records `receptor_prep` per pocket
(`schrodinger_refined` / `pdbfixer_pH7.40`), and `dock_batches.py` refuses any receptor
with zero hydrogens.

```bash
# laptop, repo root
conda run -n clpp python scripts/docking_scripts/prepare_receptors.py --dry-run
conda run -n clpp python scripts/docking_scripts/prepare_receptors.py
aws s3 cp --recursive data/processed/receptors_protonated/ s3://ai2050-ersilia-cluster/input/targets/ \
    --exclude "*" --include "*/protonated/*_H.pdb"
```

**Batches.** `make_docking_manifest.py --batch-size 1000` cuts each pocket's ligands into
consecutive batches (`batches.csv`, pocket by pocket, in plain order). Array task *T*
docks batch ids `(T-1)·K+1 … T·K`. K is fixed per dock dir: `dock_batches.py` records it
in `batches_per_task` and refuses a different value. Per batch, on the node:
parallel `prepare()` (no per-molecule timeout, decision 2026-11-25) → `ligandprep` →
`unidock --ligand_index … --num_modes 5`. The output then lands in `batches/`:

| file | content |
|---|---|
| `b<NNNNNN>.poses.sdf.gz` | every pose of every docked ligand; SDF title = ligand name |
| `b<NNNNNN>.failed.csv` | name, smiles, step (parse / fragments / embed / mmff / exception / ligandprep / dock), reason |
| `b<NNNNNN>.scores.csv` | ligand, deck_index, pose, vina_kcal_mol; written **last**, so it marks the batch done |

Also written: `receptors/<tag>.pdbqt` (prepared once per pocket and shared), and
`tasks/<job>_<task>.csv` (per-batch timings, GPU name and slowest molecule).
`errors/b<NNNNNN>.unidock.log` appears only when Uni-Dock exits non-zero, and that batch is
not marked done.

```bash
# REAL is pockets x 10.4M floats in memory: run the manifest on a compute node
/shared/python39/bin/python3.9 /shared/scripts/docking_scripts/make_docking_manifest.py \
    --screen-dir /fsx/output/<LIB>/screen_v2 --out-dir /fsx/output/<LIB>/docking_v2 \
    --targets-base /fsx/input/ai2050_targets --batch-size 1000

# AL2023 head node; K = batches per task (~40 is ~5 h on a T4 at the October rate)
D=/fsx/output/<LIB>/docking_v2; K=40
N=$(( ( $(tail -n +2 $D/batches.csv | wc -l) + K - 1 ) / K ))
sbatch --array=1-${N}%4 /shared/scripts/docking_scripts/run-docking-batches.sh $D $K

/shared/scripts/docking_scripts/check-docking.sh $D --failed    # prints the resubmit line
/shared/python39/bin/python3.9 /shared/scripts/docking_scripts/collect_docking.py --docking-dir $D
```

If Uni-Dock does not accept `--ligand_index` in GPU mode on the cluster, resubmit with
`LIGAND_INPUT=gpu_batch`, which passes the files as arguments, as the October scripts did.

## Files

| File | Where it runs | What it does |
|---|---|---|
| `unidock.def` | laptop | Apptainer recipe: conda-forge `unidock=1.2.0` (CUDA 12.9, includes `unidock_tools`) + rdkit 2026.03 + openbabel 3.2.1 (3.1.1 cannot solve with this stack); lock file at `/opt/unidock.lock`. dimorphite-dl is still installed but unused; drop it at the next rebuild |
| `unidock.lock` | — | the resolved environment exported from a built image (provenance) |
| `prepare_ligands.py` | inside the image | SMILES → neutralise → RDKit 3D + H → SDF for `ligandprep`; failures (incl. multi-fragment SMILES) go to `<out>.failed.csv` |
| `compute_box.py` | inside the image | search box from a reference ligand's heavy-atom extent + padding |
| `pose_rmsd.py` | inside the image | heavy-atom, symmetry-aware RMSD of docked poses to a reference pose (no superposition) |
| `test-unidock.sh` | `gpu-queue` | smoke test: full prep chain + re-dock one pocket's ligand twice with a fixed seed |
| `prepare_receptors.py` | laptop (`clpp`) | PDBFixer protonation of the Mtb receptors (pH 7.4); stops on chain breaks |
| `make_docking_manifest.py` | compute node | screen → pocket per ligand, box, receptor (+ `receptor_prep`), `batches.csv` |
| `dock_batches.py` | inside the image | batched prep + ligandprep + Uni-Dock on node-local disk; 3 files per batch |
| `run-docking-batches.sh` | `gpu-queue` | sbatch wrapper for `dock_batches.py`, K batches per array task |
| `check-docking.sh` | head node | read-only progress, failures by step, throughput per GPU, resubmit line |
| `collect_docking.py` | head node | `docking_scores.csv` (best pose per ligand) + top-N poses per pocket |
| `prep-ligands-array.sh`, `run-docking-array.sh`, `collect_top_poses.py` | — | October per-pocket layout (one file per ligand on FSx); kept for the Hit Locator run of 7 Oct |
| `time-docking.sh` | `gpu-queue` | throughput measurement on one pocket, node-local, nothing kept |

## Docking settings (decisions, 2026-10-01/02)

- **Charge state: every molecule is docked neutral**, with no pH model (2026-10-02).
  RDKit's `Uncharger` removes charges where a neutral form exists. Charges with no neutral
  form (e.g. quaternary ammonium) are kept and flagged (`residual_charge` in the SDF, listed
  on stderr). One leader = one docked molecule, so the comparison with DrugCLIP (one SMILES
  per molecule) stays 1:1. Multi-fragment SMILES (salts, mixtures) are not stripped; they go
  to the failures file. *Why not pH 7.4:* dimorphite-dl was tried first. In the smoke test
  it protonated VX2's aryl-NH-cyclohexyl linker to `[NH2+]`, treating an aniline-like
  nitrogen as an aliphatic amine. That would give a fake hydrogen-bond donor to a motif
  common in kinase inhibitors.
- **3D:** RDKit `AddHs` + ETKDGv3 (seeded) + MMFF94 optimisation. Vina keeps rings rigid
  while docking, so the starting ring geometry has to be sensible.

- **Scoring:** `vina`.
- **Search effort:** `--search_mode balance` (Uni-Dock preset: exhaustiveness 384,
  max_step 40). On a GPU each exhaustiveness unit is one parallel Monte Carlo thread, so
  this is not comparable with CPU Vina's exhaustiveness 8.
- **Box:** centred on the reference ligand's heavy-atom bounding box. Size = extent on each
  axis + **6 Å padding on every side**. 6 Å is the radius that defines a DrugCLIP pocket,
  so both methods look at the same region. The box is fixed per pocket from the reference
  ligand, so a leader larger than that ligand gets the same box.
- **Seed:** always passed explicitly. One value drives both the ETKDG embedding and
  Uni-Dock's `--seed` (default 42 in the smoke test).

## Build and stage

```bash
# 0. check the driver on gpu-queue first (decides whether the CUDA 12.9 build can run)
grep -h -m1 "Driver Version" /shared/logs/drugclip-*.out | sort -u

# 1. build locally, from the repo root
apptainer build unidock.sif scripts/docking_scripts/unidock.def
apptainer exec unidock.sif cat /opt/unidock.lock > scripts/docking_scripts/unidock.lock

# 2. upload, then stage from the AL2023 head node
aws s3 cp unidock.sif s3://ai2050-ersilia-cluster/sif-files/unidock.sif
aws s3 cp s3://ai2050-ersilia-cluster/sif-files/unidock.sif /shared/sif-files/unidock.sif

# 3. deploy the scripts (/shared is the same EFS on both clusters)
rsync -av scripts/docking_scripts/ ai2050cluster:/shared/scripts/docking_scripts/
```

If the smoke test fails with an "insufficient driver" CUDA error, rebuild with the
fallback pins noted in `unidock.def` (`unidock=1.1.3`, CUDA 12.6).

## Smoke test

Submit from the AL2023 head node:

```bash
mkdir -p /shared/logs
sbatch /shared/scripts/docking_scripts/test-unidock.sh \
    /fsx/input/targets_ligand/<UNIPROT>/pockets/<stem>_LIG.pdb \
    <path to the matching *_complex_refined.pdb>
```

The receptor is the pocket's `source_refined_pdb`, as listed in that pocket's
`manifest.csv`: the full protein with hydrogens, which `proteinprep` requires. Refined
conformers are staged at `s3://ai2050-ersilia-cluster/input/targets/<UNIPROT>/refined/`
(→ `/fsx/input/targets/<UNIPROT>/refined/`). They are not there by default; upload them from
the laptop's `Targets/targets/<UNIPROT>/refined/`.

First run (2026-10-02, job 451, P11309 / VX2 from 3bgq, Tesla T4, driver 570.172.08): every
step ran; the two same-seed runs gave identical output; the top-scored pose was 0.79 Å from the
reference (−10.64 kcal/mol), and the runner-up 5.03 Å away scored only 0.08 kcal/mol worse. Prep
was the pH 7.4 version (VX2 docked as `[NH2+]`); re-run after the switch to neutral.

The log `/shared/logs/unidock-test-<job>.out` reports the GPU the node got, the wall-clock
per run, whether the two same-seed runs agree, and each pose's RMSD to the reference pose.
The RMSD is reported only. No pose-recovery cutoff has been chosen.

**Caveat:** the reference pose is a crystal ligand transposed onto the AlphaFold conformer
with `cealign` (see `align_rmsd` in the manifest), not a native pose in this receptor.
