#!/usr/bin/env python3
"""
Transplant a ligand from a homologue crystal structure onto an AlphaFold model.

For targets whose drug site is known only from a homologue (e.g. MmpL3, whose inhibitors are
solved in M. smegmatis MmpL3).  The homologue chain nearest the ligand is aligned to the
model by sequence (global Needleman-Wunsch, identity scoring), superposed on the aligned CA
atoms within --local-radius of the ligand, and the ligand's heavy atoms are carried across
as a single LIG residue appended to protein.pdb.

Matching is by alignment, never by residue number: PDB numbering often differs from UniProt
(8evo is offset by one), which is what made the earlier number-matched superposition fail.

Clash is reported but not a reject -- the ligand only selects residues, and a homologue's
ligand sits tighter in an apo model.  Solvent above 0.19 is the reject (PLAN.md).

Inputs:
  <target-dir>/protein.pdb
  <pdb-cache>/<pdb_id>.cif     fetched from RCSB if absent

Outputs, under --target-dir:
  ligands/<site>_<HET>.pdb             the transplanted ligand alone, for PyMOL
  pockets/<stem>-<site>_LIG.pdb        protein + ligand; exactly one underscore
  pockets/manifest.csv                 this pocket's row added or replaced; other rows kept

Requires numpy only.  Python: /home/marina/anaconda3/bin/python

Usage:
    /home/marina/anaconda3/bin/python transplant_homolog_ligand.py \
        --target-dir data/mtb/P9WJV5 --pdb-id 6ajg --het 3RX --site site1 \
        --pdb-cache <dir> --stem AF-P9WJV5-F1-model-MmpL3 --af-source AFDB-v6
"""

import argparse
import csv
import os
import urllib.request

import numpy as np

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--target-dir", required=True)
parser.add_argument("--pdb-id", required=True)
parser.add_argument("--het", required=True, help="ligand component id, e.g. 3RX")
parser.add_argument("--site", required=True, help="pocket name, no underscores, e.g. site1")
parser.add_argument("--pdb-cache", required=True)
parser.add_argument("--stem", required=True, help="e.g. AF-P9WJV5-F1-model-MmpL3")
parser.add_argument("--af-source", required=True, help="e.g. AFDB-v6")
parser.add_argument("--local-radius", type=float, default=15.0,
                    help="superpose on aligned CA within this distance of the ligand (A)")
args = parser.parse_args()

MANIFEST_FIELDS = [
    "pocket_file", "pocket_key", "uniprot", "domain", "pocket", "conf", "center_x", "center_y",
    "center_z", "n_lig_atoms", "het_code", "source", "route", "af_source", "align_rmsd",
    "n_ligands_in_site", "clash_frac", "solvent_frac",
]
AA = {"ALA": "A", "ARG": "R", "ASN": "N", "ASP": "D", "CYS": "C", "GLN": "Q", "GLU": "E", "GLY": "G",
      "HIS": "H", "ILE": "I", "LEU": "L", "LYS": "K", "MET": "M", "PHE": "F", "PRO": "P", "SER": "S",
      "THR": "T", "TRP": "W", "TYR": "Y", "VAL": "V", "MSE": "M"}

tdir = args.target_dir
pdb_id = args.pdb_id.lower()
ligands_dir = os.path.join(tdir, "ligands")
pockets_dir = os.path.join(tdir, "pockets")
os.makedirs(args.pdb_cache, exist_ok=True)
os.makedirs(ligands_dir, exist_ok=True)
os.makedirs(pockets_dir, exist_ok=True)

site = args.site
pocket_file = f"{args.stem}-{site}_LIG.pdb"
if pocket_file.count("_") != 1:
    raise SystemExit(f"{pocket_file}: needs exactly one underscore (encode_pockets.py:134)")


def needleman_wunsch(a, b, match=2, mismatch=-1, gap=-3):
    """Global alignment; returns aligned index pairs (i in a, j in b)."""
    n, m = len(a), len(b)
    score = np.zeros((n + 1, m + 1))
    score[:, 0] = np.arange(n + 1) * gap
    score[0, :] = np.arange(m + 1) * gap
    trace = np.zeros((n + 1, m + 1), dtype=np.int8)
    b_arr = np.array(list(b))
    for i in range(1, n + 1):
        diag = score[i - 1, :-1] + np.where(b_arr == a[i - 1], match, mismatch)
        up = score[i - 1, 1:] + gap
        for j in range(1, m + 1):
            best = max(diag[j - 1], up[j - 1], score[i, j - 1] + gap)
            score[i, j] = best
            trace[i, j] = 0 if best == diag[j - 1] else (1 if best == up[j - 1] else 2)
    i, j, pairs = n, m, []
    while i > 0 and j > 0:
        if trace[i, j] == 0:
            pairs.append((i - 1, j - 1))
            i, j = i - 1, j - 1
        elif trace[i, j] == 1:
            i -= 1
        else:
            j -= 1
    return pairs[::-1]


# ---- homologue structure
cif = os.path.join(args.pdb_cache, f"{pdb_id}.cif")
if not os.path.exists(cif):
    urllib.request.urlretrieve(f"https://files.rcsb.org/download/{pdb_id.upper()}.cif", cif)
cols, rows = [], []
with open(cif) as f:
    for line in f:
        if line.startswith("_atom_site."):
            cols.append(line.strip().split(".")[1])
        elif line.startswith(("ATOM", "HETATM")):
            rows.append(line.split())
ix = {c: i for i, c in enumerate(cols)}


def get(r, c):
    return r[ix[c]]


def xyz(r):
    return np.array([float(get(r, "Cartn_x")), float(get(r, "Cartn_y")), float(get(r, "Cartn_z"))])


lig_rows = [r for r in rows if get(r, "label_comp_id") == args.het and get(r, "type_symbol") != "H"
            and get(r, "pdbx_PDB_model_num") == "1"]
if not lig_rows:
    raise SystemExit(f"{args.het} not found in {cif}")
first = (get(lig_rows[0], "auth_asym_id"), get(lig_rows[0], "auth_seq_id"))
lig_rows = [r for r in lig_rows if (get(r, "auth_asym_id"), get(r, "auth_seq_id")) == first]
lig = np.array([xyz(r) for r in lig_rows])

ca_rows = [r for r in rows if r[0] == "ATOM" and get(r, "label_atom_id") == "CA"
           and get(r, "label_comp_id") in AA and get(r, "pdbx_PDB_model_num") == "1"]
chains = sorted(set(get(r, "auth_asym_id") for r in ca_rows))


def chain_min_dist(c):
    x = np.array([xyz(r) for r in ca_rows if get(r, "auth_asym_id") == c])
    return np.linalg.norm(x[:, None] - lig[None], axis=2).min()


chain = min(chains, key=chain_min_dist)
homo = [(AA[get(r, "label_comp_id")], xyz(r)) for r in ca_rows if get(r, "auth_asym_id") == chain]

# ---- AlphaFold model
with open(os.path.join(tdir, "protein.pdb")) as f:
    atom_lines = [l.rstrip("\n") for l in f if l.startswith("ATOM")]
prot_xyz = np.array([(float(l[30:38]), float(l[38:46]), float(l[46:54])) for l in atom_lines])
prot_res = np.array([int(l[22:26]) for l in atom_lines])
model = [(AA[l[17:20]], prot_xyz[i]) for i, l in enumerate(atom_lines) if l[12:16] == " CA "]

# ---- align, superpose locally, transplant
pairs = needleman_wunsch("".join(h[0] for h in homo), "".join(m[0] for m in model))
identity = sum(homo[i][0] == model[j][0] for i, j in pairs) / len(pairs)
near = [(i, j) for i, j in pairs if np.linalg.norm(lig - homo[i][1], axis=1).min() < args.local_radius]
X = np.array([homo[i][1] for i, _ in near])
Y = np.array([model[j][1] for _, j in near])
cx, cy = X.mean(axis=0), Y.mean(axis=0)
U, _, Vt = np.linalg.svd((X - cx).T @ (Y - cy))
rot = U @ np.diag([1, 1, np.sign(np.linalg.det(U @ Vt))]) @ Vt
rmsd = float(np.sqrt((((X - cx) @ rot + cy - Y) ** 2).sum(axis=1).mean()))
placed = (lig - cx) @ rot + cy

last_serial = int(atom_lines[-1][6:11])
het_lines = []
for k, (r, (x, y, z)) in enumerate(zip(lig_rows, placed)):
    name = get(r, "label_atom_id").strip('"')
    element = get(r, "type_symbol").upper()
    name_field = name if len(name) == 4 else f" {name:<3s}"
    het_lines.append(f"HETATM{last_serial + k + 1:5d} {name_field} LIG L   1    "
                     f"{x:8.3f}{y:8.3f}{z:8.3f}  1.00  0.00          {element:>2s}")

with open(os.path.join(ligands_dir, f"{site}_{args.het}.pdb"), "w") as f:
    f.write("\n".join(het_lines) + "\nEND\n")
with open(os.path.join(pockets_dir, pocket_file), "w") as f:
    f.write("\n".join(atom_lines + het_lines) + "\nEND\n")

d = np.linalg.norm(placed[:, None, :] - prot_xyz[None, :, :], axis=2)
selected = sorted(set(prot_res[(d <= 6).any(axis=0)]))
clash = float((d.min(axis=1) < 2.6).mean())
solvent = float((d.min(axis=1) > 5).mean())
centre = placed.mean(axis=0)

row = dict.fromkeys(MANIFEST_FIELDS, "")
row.update({
    "pocket_file": pocket_file,
    "pocket_key": f"{pocket_file[:-4]}_L_1",
    "uniprot": os.path.basename(os.path.normpath(tdir)),
    "domain": 0,
    "pocket": site,
    "conf": 0,
    "center_x": round(centre[0], 3),
    "center_y": round(centre[1], 3),
    "center_z": round(centre[2], 3),
    "n_lig_atoms": len(placed),
    "het_code": args.het,
    "source": pdb_id,
    "route": f"homolog_transplant_id{round(identity * 100)}",
    "af_source": args.af_source,
    "align_rmsd": round(rmsd, 2),
    "n_ligands_in_site": 1,
    "clash_frac": round(clash, 3),
    "solvent_frac": round(solvent, 3),
})
manifest = os.path.join(pockets_dir, "manifest.csv")
kept = []
if os.path.exists(manifest):
    with open(manifest) as f:
        kept = [r for r in csv.DictReader(f) if r["pocket_file"] != pocket_file]
with open(manifest, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=MANIFEST_FIELDS)
    writer.writeheader()
    writer.writerows(kept + [row])

print(f"{pocket_file}")
print(f"  {pdb_id} chain {chain} {args.het}: aligned {len(pairs)} residues, {identity:.0%} identity")
print(f"  local RMSD        {rmsd:.2f} A over {len(near)} CA within {args.local_radius:g} A")
print(f"  ligand atoms      {len(placed):4d}   (reference median 29)")
print(f"  residues at 6 A   {len(selected):4d}   (reference median 27)")
print(f"  pocket atoms      {int((d <= 6).any(axis=0).sum()):4d}   (encode cap 511; training crop 256)")
print(f"  clash < 2.6 A     {clash:.2f}   (p90 0.63; not a reject)")
print(f"  solvent > 5 A     {solvent:.2f}   (reject above 0.19)")
print(f"  residues          {' '.join(map(str, selected))}")
