#!/usr/bin/env python3
"""
Build DrugCLIP pocket inputs (`_LIG.pdb` + manifest.csv) for targets that have no
existing pocket set -- the M. tuberculosis / Klebsiella additions.

Two ligand sources, decided per target by survey (see
docs/claude_sessions/2026-10-06_mtb_new_target_pockets.md):

  pdb       a real inhibitor co-crystal exists.  Fetch entries, superpose each onto the
            AlphaFold model, transpose the ligand into the model frame.
  alphafill AlphaFill has already transplanted ligands from homologues onto the AlphaFold
            model, so they arrive in frame and only need extracting.

Both then run the SAME site logic:
  * exclusion list applied (see NARROW / SUBSTRATE below)
  * ligands must contact the superposed monomer -- a crystal dimer's second protomer
    otherwise lands on a phantom site (this produced two spurious DprE1 "sites")
  * complete-linkage clustering on centroids, diameter --site-diameter
    (single linkage chained guaB2 across 12.1 A, which is not one pocket)
  * one conformation per site, defined by the LARGEST surviving ligand

Output matches prepare_centers_for_drugclip.py exactly, so pockets_index.csv,
merge_pocket_sets.py and the encode path all apply unchanged.  Filename stems carry NO
underscore except the one before `_LIG`, because encode_pockets.py:134 parses the ligand
name with a greedy `_.*\\.` regex.

Laptop only; needs PyMOL:  /home/marina/anaconda3/bin/python
"""

import argparse
import collections
import csv
import itertools
import json
import os
import re
import time
import urllib.request

import numpy as np

SEARCH_URL = "https://search.rcsb.org/rcsbsearch/v2/query"
AFDB = "https://alphafold.ebi.ac.uk/files/AF-{acc}-F1-model_{v}.pdb"
ALPHAFILL = "https://alphafill.eu/v1/aff/AF-{acc}-F1"

# Never pocket-defining: ions, solvent, buffer, cryoprotectant, detergent, lipid, heme,
# metal cluster, sugar.  FLAVINS, NUCLEOTIDES AND CoA ARE DELIBERATELY ABSENT -- they are
# the drug site for several of these targets (PrrB's ATP site, RibF's FMN site, ethA's
# FAD).  Decision, 2026-10-06.
NARROW = {
    "HOH", "DOD", "NA", "K", "LI", "RB", "CS", "MG", "CA", "SR", "BA", "ZN", "MN",
    "FE", "FE2", "CU", "CU1", "NI", "CO", "CD", "HG", "PT", "AU", "AG", "PB", "CL",
    "BR", "IOD", "F", "XE", "KR", "AR", "SO4", "PO4", "NO3", "CO3", "BCT", "SCN",
    "AZI", "ACT", "ACY", "FMT", "CIT", "FLC", "TLA", "MLA", "MLI", "SIN", "GOL",
    "EDO", "PEG", "PG4", "PGE", "1PE", "2PE", "P6G", "15P", "MPD", "MRD", "BU1",
    "BU3", "IPA", "DMS", "MES", "EPE", "TRS", "IMD", "BME", "DTT", "TCE", "UNX",
    "UNL", "UNK", "MOH", "EOH", "LMT", "AV0", "CE1", "C8E", "BOG", "LDA", "DDQ",
    "PLM", "OLA", "MYR", "STE", "PEE", "CDL", "HEM", "HEA", "HEB", "HEC", "DHE",
    "FES", "SF4", "F3S", "NAG", "NDG", "BMA", "MAN", "GLC", "GAL", "FUC", "MQ9",
    "PCA", "SRT", "BEZ", "TAM", "NHE", "CXS", "PGR", "TAR", "2J3", "PGO", "9YF",
    "9Y0",
}

# Natural substrates / products / regulators.  A biological judgement, not a
# measurement -- every drop is logged so it can be overturned.
SUBSTRATE = {
    "XMP": "IMPDH product", "IMP": "IMPDH substrate",
    "AMZ": "AICAR, purH substrate", "JLN": "FAICAR, purH product",
    "SKM": "shikimate, aroK substrate", "S3P": "shikimate-3-phosphate",
    "DHK": "dehydroshikimate", "PEP": "aroG substrate",
    "TRP": "aroG feedback regulator", "035": "aroG substrate analogue",
    "036": "aroG substrate analogue", "TSA": "aroG transition-state analogue",
    "SAH": "methyltransferase product", "SAM": "methyltransferase cofactor",
    "AIR": "purC substrate",
}

# Routing decided by survey.  (accession, gene, route)
ROUTES = [
    ("P9WJF1", "DprE1", "pdb"), ("I6X8D2", "Pks13", "pdb"),
    ("P9WP37", "QcrB", "pdb"), ("P9WKL5", "Rv0560", "pdb"),
    ("P9WKI7", "guaB2", "pdb"), ("P9WPY3", "aroK", "pdb"),
    ("P9WKZ1", "Rv3406", "pdb"),
    ("P9WIE5", "KatG", "alphafill"), ("A6TC99", "purC-Kleb", "alphafill"),
    ("A6TGR3", "purH-Kleb", "alphafill"), ("P9WHN1", "purC-Mtb", "alphafill"),
    ("P9WGK7", "PrrB", "alphafill"), ("P9WNF9", "ethA", "alphafill"),
    ("I6X5C9", "RibF", "alphafill"),
]


# ----------------------------------------------------------------- fetching

def fetch(url, path):
    if not os.path.exists(path):
        urllib.request.urlretrieve(url, path)
    return path


def af_model(acc, cache):
    """AlphaFold model. Version varies by entry, so try each and record which won."""
    for v in ("v4", "v6", "v5"):
        try:
            p = fetch(AFDB.format(acc=acc, v=v), os.path.join(cache, f"AF-{acc}-{v}.pdb"))
            return p, f"AFDB-{v}"
        except Exception:
            continue
    p = fetch(ALPHAFILL.format(acc=acc), os.path.join(cache, f"AF-{acc}-fill.cif"))
    return p, "alphafill-cif"


def holo_entries(acc, rows):
    q = {"type": "group", "logical_operator": "and", "nodes": [
        {"type": "terminal", "service": "text", "parameters": {
            "attribute": "rcsb_polymer_entity_container_identifiers."
                         "reference_sequence_identifiers.database_accession",
            "operator": "exact_match", "value": acc}},
        {"type": "terminal", "service": "text", "parameters": {
            "attribute": "rcsb_entry_info.nonpolymer_molecular_weight_maximum",
            "operator": "greater", "value": 0.25}}]}
    req = urllib.request.Request(
        SEARCH_URL,
        data=json.dumps({"query": q, "return_type": "entry", "request_options": {
            "paginate": {"start": 0, "rows": rows},
            "results_content_type": ["experimental"],
            "sort": [{"sort_by": "rcsb_entry_info.resolution_combined",
                      "direction": "asc"}]}}).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return [h["identifier"].lower() for h in json.loads(r.read())["result_set"]]
    except Exception:
        return []


# ----------------------------------------------------------------- geometry

def excluded(resn, log):
    rn = resn.strip().upper()
    if rn in NARROW:
        log["narrow"][rn] += 1
        return True
    if rn in SUBSTRATE:
        log["substrate"][rn] += 1
        return True
    return False


def complete_linkage(cents, diameter):
    clusters = [[i] for i in range(len(cents))]
    merged = True
    while merged:
        merged = False
        for a, b in itertools.combinations(range(len(clusters)), 2):
            cand = clusters[a] + clusters[b]
            if all(np.linalg.norm(cents[i] - cents[j]) <= diameter
                   for i, j in itertools.combinations(cand, 2)):
                clusters = ([c for n, c in enumerate(clusters) if n not in (a, b)]
                            + [cand])
                merged = True
                break
    return clusters


def qc(prot_xyz, lig_xyz):
    """(clash fraction, solvent fraction, n contact residues is computed by caller).

    Reference, from the 573 true-ligand conformations that score AUC 0.944:
    clash p50 0.23 / p90 0.63 / max 1.00; solvent p50 0.00 / p90 0.00 / max 0.19.
    Clash is normal -- the ligand is only a residue-selection device and is discarded
    before encoding.  Solvent exposure is not: it pulls surface residues into the pocket.
    """
    D = np.linalg.norm(prot_xyz[:, None, :] - lig_xyz[None, :, :], axis=2)
    return float((D.min(0) < 2.6).mean()), float(((D < 5.0).sum(0) == 0).mean())


# ----------------------------------------------------------------- writers

def hetatm(serial, name, x, y, z, elem):
    return (f"HETATM{serial:>5d} {name:<4s} LIG L   1    "
            f"{x:>8.3f}{y:>8.3f}{z:>8.3f}  1.00  0.00          {elem:>2s}\n")


def protein_lines(path):
    out = []
    if path.endswith(".cif"):
        return out                      # caller supplies lines for cif inputs
    for line in open(path):
        if line.startswith("ATOM"):
            el = line[76:78].strip()
            if el.upper() == "H":
                continue
            out.append(line)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out-base", required=True)
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/drugclip_newtargets"))
    ap.add_argument("--n-entries", type=int, default=10)
    ap.add_argument("--site-diameter", type=float, default=8.0)
    ap.add_argument("--min-contact-res", type=int, default=5)
    ap.add_argument("--min-lig-atoms", type=int, default=10)
    ap.add_argument("--max-solvent", type=float, default=0.19,
                    help="Reject a site whose ligand has more than this fraction of atoms "
                         "with no protein within 5 A. Default 0.19 is the MAXIMUM observed "
                         "across the 573 true-ligand conformations that score AUC 0.944 "
                         "(p50 and p90 are both 0.00) -- an empirical bound, not a chosen "
                         "one. Set to 1.0 to disable and keep every site.")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.cache, exist_ok=True)
    import pymol2

    print(f"site diameter {a.site_diameter} A (complete linkage); one conformation per "
          f"site, largest ligand; flavins/nucleotides/CoA KEPT\n")
    grand = collections.Counter()

    with pymol2.PyMOL() as p:
        cmd = p.cmd
        cmd.set("retain_order", 1)
        cmd.set("pdb_conect_all", 0)

        for acc, gene, route in ROUTES:
            log = {"narrow": collections.Counter(), "substrate": collections.Counter()}
            afp, afsrc = af_model(acc, a.cache)
            cmd.delete("all")
            cmd.load(afp, "af")
            cmd.remove("af and hydro")
            afxyz = []
            cmd.iterate_state(1, "af and polymer", "afxyz.append((x,y,z))",
                              space={"afxyz": afxyz})
            afxyz = np.array(afxyz)

            ligs = []
            if route == "pdb":
                for e in holo_entries(acc, a.n_entries):
                    try:
                        xp = fetch(f"https://files.rcsb.org/download/{e.upper()}.pdb",
                                   os.path.join(a.cache, f"{e}.pdb"))
                    except Exception:
                        continue
                    cmd.delete("xtal")
                    try:
                        cmd.load(xp, "xtal")
                    except Exception:
                        continue
                    best = (1e9, None)
                    for ch in cmd.get_chains("xtal and polymer"):
                        if cmd.count_atoms(f"xtal and polymer and chain {ch}") < 50:
                            continue
                        try:
                            r = cmd.super(f"xtal and polymer and chain {ch}",
                                          "af and polymer")
                        except Exception:
                            continue
                        if r[0] < best[0]:
                            best = (r[0], ch)
                        cmd.delete("xtal"); cmd.load(xp, "xtal")
                    if best[1] is None:
                        continue
                    cmd.super(f"xtal and polymer and chain {best[1]}", "af and polymer")
                    groups = collections.defaultdict(list)
                    cmd.iterate_state(
                        1, "xtal and not polymer and not solvent and not hydro",
                        "g.setdefault((chain,resi,resn),[]).append((name,x,y,z,elem))",
                        space={"g": groups})
                    for (_c, _r, resn), ats in groups.items():
                        if len(ats) < a.min_lig_atoms or excluded(resn, log):
                            continue
                        X = np.array([t[1:4] for t in ats])
                        if int((np.linalg.norm(afxyz[:, None, :] - X[None, :, :],
                                               axis=2).min(0) <= 6.0).sum()) < 5:
                            continue
                        ligs.append({"resn": resn.strip().upper(), "ats": ats,
                                     "cent": X.mean(0), "src": e,
                                     "rmsd": round(best[0], 2)})
                    time.sleep(0.03)
            else:
                fp = fetch(ALPHAFILL.format(acc=acc),
                           os.path.join(a.cache, f"AF-{acc}-fill.cif"))
                cmd.delete("fill"); cmd.load(fp, "fill"); cmd.remove("fill and hydro")
                groups = collections.defaultdict(list)
                cmd.iterate_state(
                    1, "fill and not polymer and not solvent",
                    "g.setdefault((chain,resi,resn),[]).append((name,x,y,z,elem))",
                    space={"g": groups})
                for (_c, _r, resn), ats in groups.items():
                    if len(ats) < a.min_lig_atoms or excluded(resn, log):
                        continue
                    X = np.array([t[1:4] for t in ats])
                    if int((np.linalg.norm(afxyz[:, None, :] - X[None, :, :],
                                           axis=2).min(0) <= 6.0).sum()) < 5:
                        continue
                    ligs.append({"resn": resn.strip().upper(), "ats": ats,
                                 "cent": X.mean(0), "src": "alphafill", "rmsd": None})

            print(f"=== {gene} ({acc}) [{route}, {afsrc}] -- {len(ligs)} ligands survive")
            if log["substrate"]:
                print("    dropped as SUBSTRATE: " + ", ".join(
                    f"{c}x{k} ({SUBSTRATE[c]})" for c, k in log["substrate"].most_common()))
            if not ligs:
                print("    *** NO POCKET ***\n")
                grand["lost"] += 1
                continue

            prot = protein_lines(afp)
            rows = []
            for n, cl in enumerate(sorted(
                    complete_linkage([l["cent"] for l in ligs], a.site_diameter),
                    key=lambda c: -len(c)), 1):
                members = [ligs[i] for i in cl]
                # Largest ligand defines the site (decision 2026-10-06). Copies of the
                # SAME compound all tie on size -- ethA's four FADs are 53 atoms each --
                # so break the tie on geometry, least solvent-exposed then least clashing.
                # Without this the winner is whichever copy the dict happened to yield,
                # and for ethA that was a clash-0.94 copy over the clash-0.17 one.
                scored = []
                for m in members:
                    Xm = np.array([t[1:4] for t in m["ats"]])
                    cm, sm = qc(afxyz, Xm)
                    scored.append((len(m["ats"]), -sm, -cm, m, cm, sm))
                scored.sort(key=lambda t: (t[0], t[1], t[2]), reverse=True)
                _n, _ns, _nc, rep, clash, solv = scored[0]
                X = np.array([t[1:4] for t in rep["ats"]])
                d = np.linalg.norm(afxyz[:, None, :] - X[None, :, :], axis=2).min(1)
                n_res = int((d <= 6.0).sum())     # atom-level proxy; residues counted below
                stem = f"AF-{acc}-F1-model-{gene}-site{n}"
                if solv > a.max_solvent:
                    print(f"    site {n}: REJECTED, solvent {solv:.2f} > {a.max_solvent} "
                          f"({rep['resn']}, {len(rep['ats'])} atoms) -- ligand hangs out of "
                          f"the protein, so its 6 A shell is surface, not pocket")
                    grand["rejected"] += 1
                    continue
                print(f"    site {n}: {len(members)} ligands -> {rep['resn']} "
                      f"({len(rep['ats'])} atoms, {rep['src']})  "
                      f"clash {clash:.2f}  solvent {solv:.2f}")
                rows.append({
                    "pocket_file": f"{stem}_LIG.pdb", "pocket_key": f"{stem}_LIG_L_1",
                    "uniprot": acc, "domain": "0", "pocket": f"site{n}", "conf": "0",
                    "center_x": round(float(rep["cent"][0]), 3),
                    "center_y": round(float(rep["cent"][1]), 3),
                    "center_z": round(float(rep["cent"][2]), 3),
                    "n_lig_atoms": len(rep["ats"]), "het_code": rep["resn"],
                    "source": rep["src"], "route": route, "af_source": afsrc,
                    "align_rmsd": rep["rmsd"], "n_ligands_in_site": len(members),
                    "clash_frac": round(clash, 3), "solvent_frac": round(solv, 3),
                })
                if not a.dry_run and prot:
                    od = os.path.join(a.out_base, acc, "pockets")
                    os.makedirs(od, exist_ok=True)
                    last = max((int(l[6:11]) for l in prot if l[6:11].strip().isdigit()),
                               default=0)
                    with open(os.path.join(od, f"{stem}_LIG.pdb"), "w") as f:
                        f.writelines(prot)
                        for j, (_nm, x, y, z, el) in enumerate(rep["ats"]):
                            e = (el or "C").strip() or "C"
                            f.write(hetatm(last + 1 + j, f"{e}{j+1}"[:4], x, y, z, e))
                grand["pockets"] += 1
            grand["targets"] += 1
            if not a.dry_run and rows:
                od = os.path.join(a.out_base, acc, "pockets")
                os.makedirs(od, exist_ok=True)
                with open(os.path.join(od, "manifest.csv"), "w", newline="") as f:
                    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
                    w.writeheader(); w.writerows(rows)
            print()

    print(f"{'[dry-run] ' if a.dry_run else ''}"
          f"{grand['pockets']} pockets across {grand['targets']} targets; "
          f"{grand['lost']} targets with no pocket")


if __name__ == "__main__":
    main()
