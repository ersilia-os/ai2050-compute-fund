#!/usr/bin/env python3
"""
Build a real pocket-defining ligand for the 182 GENPACK-route pockets by transposition.

Background
----------
The 339 AI2050 pockets come from two detection routes (paper p. 12).  For the 157
template-route pockets the authors' own ligand is recoverable, because the source PDB
entry is written into the refined-conformation filename, and
`recover_template_ligands.py` reconstructs it -- taking pocket_by_target AUC from 0.508
to 0.854.

The 182 "pocketN" pockets came from Fpocket + GenPack instead.  The paper's method is:

    During inference, Fpocket is initially employed to detect pockets approximately
    10 A in size, after which our generative model generates potential ligand molecules
    conditioned on backbone atoms only.  Subsequently, side-chain atoms are introduced
    ... The protein residues with at least one heavy atom within a 6-A radius of the
    generated ligands are selected as the final pocket region.

That generated molecule is NOT distributed -- every `complex_refined.pdbgz` in
`screen_results.zip` has 0 HETATM -- and GenPack itself was never released (the authors'
repo ships DrugCLIP only).  So the molecule that defined these pockets is gone.

This script substitutes a *real* ligand for the generated one: find a PDB entry of the
same protein (or a homolog), superpose it onto the AlphaFold conformer, and keep the
transposed ligand that lands in this pocket.  It is the same transposition the authors
used for their template route, applied to pockets where they used a generative model
instead -- which is exactly the operation the paper describes for template matching
(TM-score > 0.6, pocket IoU > 0.6).

What is new here, and it is the only new thing
----------------------------------------------
For a template pocket the donor PDB code is read off the filename
(`..._4_5orz_complex_refined.pdb` -> 5orz).  GenPack conformations carry no code, so the
donor has to be SEARCHED for.  Everything after the search -- fetch, cealign, ligand
pick, the contact-residue guard, the _LIG.pdb writer, the manifest -- is imported
unchanged from recover_template_ligands.py.

Donor search, per target
------------------------
  1. RCSB search for entries of this UniProt accession whose largest non-polymer entity
     is drug-sized (--min-ligand-mw, default 0.25 kDa), best resolution first.  These are
     genuine binders of the real protein and superpose almost perfectly.  The weight
     floor is not optional -- see has_ligand_node().
  2. If a pocket finds no acceptable donor among those, fall back to a sequence-
     similarity search (homologs) seeded with the AlphaFold superdomain sequence.

Candidates are searched once per target and shared across its pockets; the *choice* is
made per pocket, because different pockets of one protein are different sites.

Donor choice, per pocket
------------------------
Each candidate is superposed onto one representative conformation and scored.  A
candidate must clear every gate -- ligand size within [--min-lig-atoms, --max-lig-atoms],
centroid within --max-offset of the pocket's Glide grid centre, cealign RMSD and aligned
length sane, and at least --min-contact-residues residues contacted.  Survivors are
ranked by centroid offset, ties broken toward the larger ligand.

The size ceiling matters and is not cosmetic.  The true-ligand set that scored 0.854 has
a median of 29 heavy atoms; the 88-atom fpocket cavity pseudo-ligand scored *worse* than
a single point on early enrichment.  Bigger is not better -- an unbounded search would
happily pick a bound peptide or a cofactor and over-select the pocket.

Output
------
`<out-base>/<UNIPROT>/pockets/` with filenames and pocket_keys IDENTICAL to
prepare_centers_for_drugclip.py, so `pockets_index.csv` still applies and
`merge_pocket_sets.py` can merge this set by pocket_key like any other.  manifest.csv
carries the template script's columns plus `donor_source`, so which route supplied each
conformation stays auditable.

Requires PyMOL and network access to RCSB:  /home/marina/anaconda3/bin/python

Usage:
    /home/marina/anaconda3/bin/python recover_genpack_ligands.py \
        --targets-dir /home/marina/Documents/AI2050/Targets/targets \
        --out-base    /home/marina/Documents/AI2050/Targets/targets_genpack \
        --pdb-cache   /home/marina/Documents/AI2050/Targets/pdb_cache

Smoke-test one target first:
    ... --targets P00519 --dry-run
"""

import argparse
import csv
import glob
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

from recover_template_ligands import (
    CENTER_RE,
    JUNK_HET,
    contact_residues,
    fetch_pdb,
    heavy_atom_lines,
    hetatm,
    last_serial,
    read_center,
)

SEARCH_URL = "https://search.rcsb.org/rcsbsearch/v2/query"

def has_ligand_node(min_mw):
    """Search clause: the entry's largest non-polymer entity is at least min_mw kDa.

    NOT `nonpolymer_entity_count > 0`, which was the first thing tried and is worthless:
    a lone sulfate or zinc satisfies it. Combined with a best-resolution-first sort it
    actively selects against us, because the highest-resolution structures of a protein
    tend to be small apo domains crystallised with nothing but cryoprotectant. P00519
    returned eight such entries in a row -- max non-polymer weights 0.15, 0.11, 0.09 kDa,
    i.e. sulfate, glycerol, chloride -- and every one was discarded by JUNK_HET after
    download, so the search never reached a real complex.
    """
    return {
        "type": "terminal",
        "service": "text",
        "parameters": {
            "attribute": "rcsb_entry_info.nonpolymer_molecular_weight_maximum",
            "operator": "greater",
            "value": min_mw,
        },
    }

AA3TO1 = {
    "ALA": "A", "ARG": "R", "ASN": "N", "ASP": "D", "CYS": "C", "GLN": "Q",
    "GLU": "E", "GLY": "G", "HIS": "H", "ILE": "I", "LEU": "L", "LYS": "K",
    "MET": "M", "PHE": "F", "PRO": "P", "SER": "S", "THR": "T", "TRP": "W",
    "TYR": "Y", "VAL": "V", "MSE": "M", "SEC": "U", "PYL": "O",
}


def rcsb_search(payload, retries=3, pause=1.0):
    """POST a search query to RCSB. Returns a list of entry ids, [] for no hits, None on error.

    The empty-list / None distinction matters: "this protein has no holo structure" is a
    result we act on (fall back to homologs), while "the search service failed" must not
    be silently read as the same thing.
    """
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        SEARCH_URL, data=data, headers={"Content-Type": "application/json"})
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                if r.status == 204:
                    return []
                body = r.read()
            if not body:
                return []
            hits = json.loads(body).get("result_set", [])
            return [h["identifier"].lower() for h in hits]
        except urllib.error.HTTPError as e:
            if e.code in (204, 400):
                return []          # no content / malformed-for-this-input: not retryable
            time.sleep(pause * (attempt + 1))
        except Exception:
            time.sleep(pause * (attempt + 1))
    return None


def search_same_uniprot(uniprot, rows, min_mw):
    """Entries whose polymer maps to this UniProt accession and that carry a real ligand."""
    query = {
        "type": "group",
        "logical_operator": "and",
        "nodes": [
            {
                "type": "terminal",
                "service": "text",
                "parameters": {
                    "attribute": "rcsb_polymer_entity_container_identifiers."
                                 "reference_sequence_identifiers.database_accession",
                    "operator": "exact_match",
                    "value": uniprot,
                },
            },
            has_ligand_node(min_mw),
        ],
    }
    return rcsb_search({
        "query": query,
        "return_type": "entry",
        "request_options": {
            "paginate": {"start": 0, "rows": rows},
            "results_content_type": ["experimental"],
            # Best-resolution first: a 1.5 A structure gives a cleaner ligand pose than a
            # 3.5 A one, and we only ever try the first few. Safe only because the clause
            # above now guarantees every hit actually has a drug-sized ligand -- see
            # has_ligand_node() for what this sort did before it did.
            "sort": [{"sort_by": "rcsb_entry_info.resolution_combined",
                      "direction": "asc"}],
        },
    })


def search_homologs(sequence, rows, identity_cutoff, evalue_cutoff, min_mw):
    """Entries similar in sequence to the superdomain, carrying a ligand, best match first."""
    query = {
        "type": "group",
        "logical_operator": "and",
        "nodes": [
            {
                "type": "terminal",
                "service": "sequence",
                "parameters": {
                    "sequence_type": "protein",
                    "value": sequence,
                    "identity_cutoff": identity_cutoff,
                    "evalue_cutoff": evalue_cutoff,
                },
            },
            has_ligand_node(min_mw),
        ],
    }
    # Left on the default sort (match score) -- for a homolog the alignment quality
    # matters more than the crystallographic resolution.
    return rcsb_search({
        "query": query,
        "return_type": "entry",
        "request_options": {
            "paginate": {"start": 0, "rows": rows},
            "results_content_type": ["experimental"],
        },
    })


def sequence_from_pdb(path):
    """One-letter sequence from a PDB's CA atoms, in file order."""
    seq, seen = [], set()
    try:
        with open(path) as f:
            for line in f:
                if not line.startswith("ATOM") or line[12:16].strip() != "CA":
                    continue
                key = (line[21], line[22:27])
                if key in seen:
                    continue
                seen.add(key)
                seq.append(AA3TO1.get(line[17:20].strip().upper(), "X"))
    except OSError:
        return ""
    return "".join(seq)


def collect_genpack_pockets(target_dir):
    """Group this target's GenPack-route refined conformations by pocket.

    Mirrors collect_template_confs() but keeps the "pocketN" tokens it skips, and does
    not require a PDB id in the conformation label -- GenPack filenames have none, which
    is the entire reason this script exists.
    """
    refined_dir = os.path.join(target_dir, "refined")
    pockets = []
    for cpath in sorted(glob.glob(os.path.join(target_dir, "*_center.txt"))):
        m = CENTER_RE.match(os.path.basename(cpath))
        if not m:
            continue
        prefix, uniprot, domain, pocket = m.group(1), m.group(2), m.group(3), m.group(4)
        if not pocket.startswith("pocket"):
            continue                       # template route: recover_template_ligands.py
        center = read_center(cpath)
        if center is None:
            continue
        confs = []
        pattern = os.path.join(refined_dir, f"{prefix}_{pocket}_*_complex_refined.pdb")
        for conf_path in sorted(glob.glob(pattern)):
            stem = os.path.basename(conf_path)[:-len(".pdb")]
            inner = re.match(
                rf"^{re.escape(prefix)}_{re.escape(pocket)}_(.+)_complex_refined$", stem)
            if not inner:
                continue
            confs.append({
                "conf": inner.group(1), "conf_path": conf_path, "stem": stem,
                "source_refined_pdb": os.path.basename(conf_path),
            })
        if confs:
            pockets.append({
                "uniprot": uniprot, "domain": domain, "pocket": pocket,
                "center": center, "confs": confs,
                "apo_path": os.path.join(target_dir, f"{prefix}.pdb"),
            })
    return pockets


def pick_ligand_sized(cmd, obj, center, min_atoms, max_atoms):
    """Nearest non-junk HET group to `center` with heavy-atom count in [min, max].

    recover_template_ligands.pick_ligand() has no upper bound, which is right there: the
    authors' own ligand is whatever it is, and we are recovering it, not choosing it.
    Here we ARE choosing, out of every ligand ever crystallised with this protein, so the
    ceiling is load-bearing -- see the module docstring.
    """
    groups = {}
    cmd.iterate_state(
        1, f"{obj} and not polymer and not solvent and not hydro",
        "groups.setdefault((chain, resi, resn), []).append((name, x, y, z, elem))",
        space={"groups": groups},
    )
    best = None
    for (_chain, _resi, resn), atoms in groups.items():
        if resn.strip().upper() in JUNK_HET:
            continue
        if not (min_atoms <= len(atoms) <= max_atoms):
            continue
        cx = sum(a[1] for a in atoms) / len(atoms)
        cy = sum(a[2] for a in atoms) / len(atoms)
        cz = sum(a[3] for a in atoms) / len(atoms)
        off = ((cx - center[0]) ** 2 + (cy - center[1]) ** 2 + (cz - center[2]) ** 2) ** 0.5
        if best is None or off < best[2]:
            best = (atoms, resn.strip(), off)
    return best if best else (None, None, None)


def nearest_het(cmd, obj, center, floor=3):
    """Nearest non-junk HET of ANY size to `center`. Diagnostics only.

    Tells apart the two ways pick_ligand_sized() comes back empty: nothing is bound near
    this site at all, versus something is bound and the size window excluded it. Without
    this the two are indistinguishable in the output, and they call for opposite fixes.
    """
    groups = {}
    cmd.iterate_state(
        1, f"{obj} and not polymer and not solvent and not hydro",
        "groups.setdefault((chain, resi, resn), []).append((x, y, z))",
        space={"groups": groups},
    )
    best = None
    for (_chain, _resi, resn), atoms in groups.items():
        if resn.strip().upper() in JUNK_HET or len(atoms) < floor:
            continue
        cx = sum(a[0] for a in atoms) / len(atoms)
        cy = sum(a[1] for a in atoms) / len(atoms)
        cz = sum(a[2] for a in atoms) / len(atoms)
        off = ((cx - center[0]) ** 2 + (cy - center[1]) ** 2 + (cz - center[2]) ** 2) ** 0.5
        if best is None or off < best[2]:
            best = (len(atoms), resn.strip(), off)
    return best if best else (0, None, None)


def superpose(cmd, donor_path, min_align_len):
    """Fit `xtal` onto the loaded `af` object as well as possible. Returns (rmsd, alen, how).

    Tries sequence-aware `super` on each donor chain separately, then falls back to
    `cealign` on the whole polymer. Reloads the donor between attempts because align/super
    transform the mobile object's coordinates in place, so a second attempt would otherwise
    start from the first one's result.

    All three refinements here exist because the first version -- one `cealign` over the
    whole donor polymer, inherited from recover_template_ligands.py -- fitted every P00519
    donor at 7.6-9.9 A RMSD and threw the ligand 17-32 A off site:

      * `cealign` is a remote-homology aligner; for a same-UniProt donor the sequence is
        identical and `super` is much sharper.
      * these entries have several copies in the asymmetric unit, and fitting all chains
        at once onto a single-copy model returns a compromise between them.
      * the AF file is a superdomain, so a donor covering a different region of the protein
        cannot fit well no matter which aligner is used -- that case has to be visible as a
        low `alen` rather than hidden inside a bad RMSD.
    """
    best = (float("inf"), 0, "")
    chains = []
    try:
        chains = [c for c in cmd.get_chains("xtal and polymer") if c]
    except Exception:
        pass

    for ch in chains:
        sel = f"xtal and polymer and chain {ch}"
        if cmd.count_atoms(sel) < 20:
            continue
        try:
            # super/align move the whole mobile OBJECT, so the ligand travels with the
            # chain we fit on even though it is not part of the selection.
            r = cmd.super(sel, "af and polymer")
            rmsd, alen = float(r[0]), int(r[6])
        except Exception:
            continue
        if alen >= min_align_len and rmsd < best[0]:
            best = (rmsd, alen, f"super/chain {ch}")
        cmd.delete("xtal")
        cmd.load(donor_path, "xtal")

    if best[2]:
        # Redo the winning fit on the freshly reloaded object.
        ch = best[2].split()[-1]
        try:
            cmd.super(f"xtal and polymer and chain {ch}", "af and polymer")
            return best
        except Exception:
            pass

    cmd.delete("xtal")
    cmd.load(donor_path, "xtal")
    try:
        res = cmd.cealign("af and polymer", "xtal and polymer")
        return float(res.get("RMSD", float("nan"))), int(res.get("alignment_length", 0)), "cealign"
    except Exception as e:
        return float("nan"), 0, f"failed ({e})"


def transpose(cmd, conf_path, donor_path, center, prot_lines, args):
    """Superpose donor onto one conformation and return the transposed ligand + quality.

    ALWAYS returns a dict, never None. `error` set means the superposition itself failed;
    `reject` set means it worked and the result failed a gate, with the offending values
    in the string. Returning None for both made "every fetch 404'd", "cealign died" and
    "the ligand is 18 A away" print as the same single line, which is useless at exactly
    the moment the output matters.
    """
    out = {"atoms": None, "het": None, "offset": None, "rmsd": None, "alen": None,
           "n_contact": None, "error": "", "reject": "", "note": "", "how": ""}
    cmd.delete("all")
    try:
        cmd.load(conf_path, "af")
        cmd.load(donor_path, "xtal")
    except Exception as e:
        out["error"] = f"load failed ({e})"
        return out

    out["rmsd"], out["alen"], out["how"] = superpose(cmd, donor_path, args.min_align_len)
    if out["how"].startswith("failed"):
        out["error"] = f"superposition {out['how']}"
        return out
    n_af = cmd.count_atoms("af and polymer and name CA")

    atoms, het, offset = pick_ligand_sized(
        cmd, "xtal", center, args.min_lig_atoms, args.max_lig_atoms)
    # Carried on every diagnostic line, not just failures: a donor rejected for a 20 A
    # offset after aligning 80 of 400 residues is a coverage problem, and a donor rejected
    # after aligning all of them is a real statement about where the ligand sits. The two
    # need opposite responses and the offset alone does not tell them apart.
    fit = f"{out['how']}, aligned {out['alen']}/{n_af} res"

    if not atoms:
        n_near, resn_near, off_near = nearest_het(cmd, "xtal", center)
        near = (f"nearest HET {resn_near} {n_near} atoms at {off_near:.1f} A"
                if resn_near else "no non-solvent HET in entry")
        out["note"] = f"{near}; {fit}"
        out["reject"] = f"no ligand in {args.min_lig_atoms}-{args.max_lig_atoms} atom window"
        return out

    out["atoms"], out["het"], out["offset"] = atoms, het, offset
    out["n_contact"] = contact_residues(prot_lines, atoms)
    out["note"] = fit
    reject = []
    if offset > args.max_offset:
        reject.append(f"offset={offset:.1f}A")
    # Negated comparison so a NaN RMSD -- a superposition that returned nothing usable --
    # rejects instead of sliding through, which `rmsd > max` would let it do.
    if not (out["rmsd"] <= args.max_align_rmsd):
        reject.append(f"rmsd={out['rmsd']:.1f}A")
    if out["alen"] < args.min_align_len:
        reject.append(f"alen={out['alen']}")
    if out["n_contact"] < args.min_contact_residues:
        reject.append(f"contacts={out['n_contact']}")
    out["reject"] = ";".join(reject)
    return out


def choose_donor(cmd, pocket, candidates, source, args, pdb_cache):
    """Try candidates against this pocket's representative conformation.

    Returns (donor_or_None, diagnostics). Ranked by centroid offset ascending, ties broken
    toward the larger ligand. Gates do the quality work; the ranking only decides among
    donors that already passed.

    `diagnostics` is one line per candidate tried, and is the whole point of the return
    signature: a pocket that resolves nothing needs to say whether the ligands were absent,
    mis-sited, or merely outside a window we chose.
    """
    rep = pocket["confs"][0]
    prot = heavy_atom_lines(rep["conf_path"])
    if not prot:
        return None, ["representative conformation has no heavy atoms"]

    scored, diag = [], []
    for pdb_id in candidates[:args.max_candidates]:
        local = fetch_pdb(pdb_id, pdb_cache)
        if not local:
            diag.append(f"{pdb_id}: fetch failed")
            continue
        got = transpose(cmd, rep["conf_path"], local, pocket["center"], prot, args)
        if got["error"]:
            diag.append(f"{pdb_id}: {got['error']}")
            continue
        if got["reject"]:
            extra = f"  [{got['note']}]" if got["note"] else ""
            diag.append(f"{pdb_id}: {got['reject']}{extra}")
            continue
        diag.append(f"{pdb_id}: OK {got['het']} {len(got['atoms'])} atoms "
                    f"offset {got['offset']:.1f} A  [{got['note']}]")
        scored.append((got["offset"], -len(got["atoms"]), pdb_id, local, got))

    if not scored:
        return None, diag
    scored.sort(key=lambda t: (t[0], t[1]))
    _off, _neg, pdb_id, local, got = scored[0]
    return {"pdb_id": pdb_id, "path": local, "source": source,
            "n_tried": min(len(candidates), args.max_candidates), "probe": got}, diag


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--targets-dir", required=True,
                    help="Existing targets tree (read-only): <targets-dir>/<UNIPROT>/")
    ap.add_argument("--out-base", required=True,
                    help="New output tree: <out-base>/<UNIPROT>/pockets/")
    ap.add_argument("--pdb-cache", required=True,
                    help="Directory for downloaded RCSB entries (shared with the template "
                         "run; cached across runs)")
    ap.add_argument("--targets", default="",
                    help="Comma-separated UniProt IDs to restrict to (default: all)")
    ap.add_argument("--donor-source", choices=("auto", "same-uniprot", "homolog"),
                    default="auto",
                    help="auto: same-UniProt entries, falling back to homologs per pocket. "
                         "homolog: force a different protein (blind recreation of what "
                         "GenPack had to do from backbone alone).")
    ap.add_argument("--max-candidates", type=int, default=12,
                    help="Donor entries to superpose per pocket before giving up")
    ap.add_argument("--search-rows", type=int, default=50,
                    help="Entries to request from RCSB per target")
    ap.add_argument("--min-ligand-mw", type=float, default=0.25,
                    help="kDa. An entry qualifies as a donor only if its largest "
                         "non-polymer entity is at least this heavy. 0.25 kDa is about 18 "
                         "heavy atoms, so it sits just above --min-lig-atoms and below any "
                         "ion, sulfate, glycerol or MPD.")
    ap.add_argument("--identity-cutoff", type=float, default=0.3,
                    help="Sequence-identity floor for the homolog fallback")
    ap.add_argument("--evalue-cutoff", type=float, default=0.1,
                    help="E-value ceiling for the homolog fallback")
    ap.add_argument("--min-lig-atoms", type=int, default=10,
                    help="Minimum heavy atoms for a HET group to count as the ligand")
    ap.add_argument("--max-lig-atoms", type=int, default=60,
                    help="Maximum heavy atoms. The true-ligand set that scored 0.854 runs "
                         "10-74 with median 29; without a ceiling the search picks bound "
                         "peptides and cofactors and over-selects the pocket.")
    ap.add_argument("--min-contact-residues", type=int, default=5,
                    help="Reject a conformation whose transposed ligand contacts fewer "
                         "than this many residues within 6 A. An empty pocket kills the "
                         "whole target at encode time with 'need at least one array to "
                         "stack'.")
    ap.add_argument("--max-offset", type=float, default=5.0,
                    help="Reject a donor whose ligand centroid is further than this (A) "
                         "from the pocket's grid centre. Unlike the template script this "
                         "REJECTS rather than flags -- a far ligand here means we picked "
                         "the wrong site, not that the authors did.")
    ap.add_argument("--max-align-rmsd", type=float, default=5.0,
                    help="Reject a donor whose cealign RMSD exceeds this (A)")
    ap.add_argument("--min-align-len", type=int, default=50,
                    help="Reject a donor with fewer aligned residues than this")
    ap.add_argument("--limit", type=int, default=0,
                    help="Stop after N pockets (smoke test)")
    ap.add_argument("--dry-run", action="store_true",
                    help="Do everything except write _LIG.pdb / manifest.csv")
    args = ap.parse_args()

    try:
        import pymol2
    except ImportError:
        sys.exit("pymol2 not importable - run with /home/marina/anaconda3/bin/python")

    targets_dir = os.path.abspath(args.targets_dir)
    only = {t.strip() for t in args.targets.split(",") if t.strip()}
    target_dirs = sorted(d for d in glob.glob(os.path.join(targets_dir, "*"))
                         if os.path.isdir(d) and (not only or os.path.basename(d) in only))
    if not target_dirs:
        sys.exit(f"no target folders under {targets_dir}")

    by_uniprot = {}
    for td in target_dirs:
        pockets = collect_genpack_pockets(td)
        if pockets:
            by_uniprot[os.path.basename(td)] = pockets
    if args.limit:
        trimmed, left = {}, args.limit
        for uni, pks in by_uniprot.items():
            if left <= 0:
                break
            trimmed[uni] = pks[:left]
            left -= len(trimmed[uni])
        by_uniprot = trimmed

    n_pockets = sum(len(p) for p in by_uniprot.values())
    n_confs = sum(len(pk["confs"]) for p in by_uniprot.values() for pk in p)
    print(f"{n_pockets} GenPack pockets / {n_confs} conformations "
          f"across {len(by_uniprot)} targets")
    print(f"donor source: {args.donor_source}   ligand size window: "
          f"{args.min_lig_atoms}-{args.max_lig_atoms} heavy atoms\n")

    manifest_by_target = {}
    stats = {"ok_conf": 0, "ok_pocket": 0, "no_candidates": 0, "no_donor": 0,
             "conf_failed": 0, "search_failed": 0, "homolog_used": 0}
    unresolved = []

    with pymol2.PyMOL() as p:
        cmd = p.cmd
        cmd.set("retain_order", 1)
        cmd.set("pdb_conect_all", 0)

        for uni, pockets in sorted(by_uniprot.items()):
            same_uniprot, homologs = None, None

            if args.donor_source in ("auto", "same-uniprot"):
                same_uniprot = search_same_uniprot(uni, args.search_rows,
                                                   args.min_ligand_mw)
                if same_uniprot is None:
                    print(f"{uni}: RCSB search FAILED")
                    stats["search_failed"] += 1
                    same_uniprot = []
            else:
                same_uniprot = []

            print(f"{uni}: {len(pockets)} pockets, {len(same_uniprot)} same-UniProt "
                  f"ligand-bearing entries")

            for pk in pockets:
                tag = f"{uni} d{pk['domain']} {pk['pocket']}"

                donor, diag = None, []
                if same_uniprot:
                    donor, d = choose_donor(cmd, pk, same_uniprot, "same_uniprot",
                                            args, args.pdb_cache)
                    diag += d

                # Per-pocket fallback: this target may be crystallised many times over and
                # still have nothing bound at THIS site.
                if donor is None and args.donor_source in ("auto", "homolog"):
                    if homologs is None:
                        seq = sequence_from_pdb(pk["apo_path"])
                        if len(seq) >= 25:
                            homologs = search_homologs(
                                seq, args.search_rows, args.identity_cutoff,
                                args.evalue_cutoff, args.min_ligand_mw) or []
                        else:
                            homologs = []
                        if args.donor_source == "homolog":
                            excl = set(same_uniprot)
                            homologs = [h for h in homologs if h not in excl]
                    if homologs:
                        donor, d = choose_donor(cmd, pk, homologs, "homolog",
                                                args, args.pdb_cache)
                        diag += d
                        if donor is not None:
                            stats["homolog_used"] += 1

                if donor is None:
                    have_any = bool(same_uniprot) or bool(homologs)
                    stats["no_donor" if have_any else "no_candidates"] += 1
                    unresolved.append((tag, len(pk["confs"]),
                                       "no candidate passed the gates" if have_any
                                       else "no ligand-bearing entry found"))
                    print(f"  {tag}: UNRESOLVED ({len(pk['confs'])} conformations)")
                    for line in diag[:args.max_candidates]:
                        print(f"      {line}")
                    continue

                probe = donor["probe"]
                print(f"  {tag}: {donor['pdb_id']} {probe['het']} "
                      f"({len(probe['atoms'])} atoms, offset {probe['offset']:.1f} A, "
                      f"rmsd {probe['rmsd']:.1f} A, {probe['n_contact']} residues, "
                      f"{probe['how']}) [{donor['source']}]")
                stats["ok_pocket"] += 1

                for conf in pk["confs"]:
                    prot = heavy_atom_lines(conf["conf_path"])
                    if not prot:
                        stats["conf_failed"] += 1
                        continue
                    got = transpose(cmd, conf["conf_path"], donor["path"],
                                    pk["center"], prot, args)
                    if got["error"] or got["reject"]:
                        print(f"    SKIP {conf['conf']}: {got['error'] or got['reject']}")
                        stats["conf_failed"] += 1
                        continue

                    out_stem = conf["stem"].replace("_", "-")
                    out_name = f"{out_stem}_LIG.pdb"
                    if not args.dry_run:
                        out_dir = os.path.join(args.out_base, uni, "pockets")
                        os.makedirs(out_dir, exist_ok=True)
                        s0 = last_serial(prot)
                        with open(os.path.join(out_dir, out_name), "w") as f:
                            f.writelines(prot)
                            for j, (_n, x, y, z, elem) in enumerate(got["atoms"]):
                                el = (elem or "C").strip() or "C"
                                f.write(hetatm(s0 + j, f"{el}{j + 1}"[:4], x, y, z, el))

                    manifest_by_target.setdefault(uni, []).append({
                        "pocket_file": out_name,
                        "pocket_key": f"{out_stem}_LIG_L_1",
                        "uniprot": uni, "domain": pk["domain"], "pocket": pk["pocket"],
                        "conf": conf["conf"],
                        "center_x": pk["center"][0], "center_y": pk["center"][1],
                        "center_z": pk["center"][2],
                        "n_lig_atoms": len(got["atoms"]),
                        "n_contact_res": got["n_contact"],
                        "source_refined_pdb": conf["source_refined_pdb"],
                        "pdb_id": donor["pdb_id"], "het_code": got["het"],
                        "align_rmsd": round(got["rmsd"], 3), "align_len": got["alen"],
                        "centroid_offset": round(got["offset"], 3),
                        "flag": "",
                        "donor_source": donor["source"],
                        "donor_candidates_tried": donor["n_tried"],
                    })
                    stats["ok_conf"] += 1

    if not args.dry_run:
        for uni, rows in manifest_by_target.items():
            out_dir = os.path.join(args.out_base, uni, "pockets")
            os.makedirs(out_dir, exist_ok=True)
            with open(os.path.join(out_dir, "manifest.csv"), "w", newline="") as f:
                w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
                w.writeheader()
                w.writerows(rows)

    print(f"\n{'[dry-run] ' if args.dry_run else ''}"
          f"resolved {stats['ok_pocket']}/{n_pockets} pockets, "
          f"wrote {stats['ok_conf']}/{n_confs} conformations "
          f"across {len(manifest_by_target)} targets")
    print(f"  homolog fallback used : {stats['homolog_used']} pockets")
    print(f"  unresolved            : {stats['no_donor']} no donor passed the gates, "
          f"{stats['no_candidates']} no candidates at all")
    print(f"  conformations dropped : {stats['conf_failed']}")
    if stats["search_failed"]:
        print(f"  RCSB search failures  : {stats['search_failed']} targets "
              f"<-- rerun, these are NOT 'no structure'")
    for tag, n, why in unresolved[:40]:
        print(f"    {tag}  ({n} confs)  {why}")
    if len(unresolved) > 40:
        print(f"    ... and {len(unresolved) - 40} more")

    # Unresolved pockets are not a failure mode on their own -- merge_pocket_sets.py falls
    # back to the baseline definition for any pocket_key this set does not carry. But a low
    # resolution rate means the arm barely differs from baseline and will not move the AUC.
    if n_pockets:
        print(f"\n  pocket resolution rate: {stats['ok_pocket'] / n_pockets:.1%}"
              + ("   <-- too low to be worth encoding" if stats["ok_pocket"] / n_pockets < 0.5
                 else "   <-- worth encoding"))


if __name__ == "__main__":
    main()
