# DrugCLIP validation

## TL;DR

Our DrugCLIP setup finds the right molecules for a target when the pocket is defined the way
the paper defines it: from the residues around a real bound ligand. On 57 of 66 human targets,
mixed into ~200,000 ChEMBL decoys, it ranks the known actives far above chance: **EF@1% 28.6,
AUC 0.944, 57/57 targets above the null**. Pockets built without a real ligand carry no
target-specific signal, and that is the main open problem.

## The question

The DrugCLIP authors released, per pocket, a leaderboard of their top-ranked molecules
(`leader.csv`). We encoded the same pockets and asked whether our setup ranks each pocket's
leaders above everything else. We compare rankings, not absolute scores: their scores are
normalised against a ~500M-molecule library and ours against a much smaller one, which changes
the scale but not the order.

**Metrics.** *EF@1%* (enrichment factor): among the top 1% of ranked molecules, how many times
more actives we find than random picking would; 1 is chance. *AUC*: the probability that a
random active outranks a random decoy; 0.5 is chance. Reported as the median over targets of
each target's median pocket, so targets with many pockets do not dominate.

## Result

Deck: 35,931 leader molecules plus 199,930 ChEMBL decoys (235,861 in total); 155 pockets on
57 targets.

| | leaders only | leaders + ChEMBL decoys |
|---|---|---|
| EF@1% | 9.0 | **28.6** |
| AUC | 0.872 | **0.944** |
| targets above the null | 57/57 | **57/57** |

Adding decoys raises the numbers: the decoys mostly rank below the actives, so the same
retrieval stands out more in a deck six times larger, and the EF@1% ceiling rises from ~9 to
~100.

## What made it work: the pocket definition

Our first pockets were a 6 Å ball around a single point, which gave **7 residues**. The paper
uses residues within 6 Å of a real ligand, which gives **27**. Our pocket captured about a
quarter of theirs, far from what the encoder was trained on. Rebuilding the pockets from the
authors' actual ligands took AUC from 0.51 to 0.85 on the same molecules, and targets beating
their own control from 42/66 to 55/57.

Splitting one run by how each pocket was built makes the point directly:

| pockets | EF@1% | AUC | AUC against the wrong target's pocket |
|---|---|---|---|
| true-ligand (155) | **25.0** | **0.944** | 0.689 |
| older definitions (184) | 0.81 | 0.625 | 0.615 |

The older pockets score no better against their own target than against a wrong one. Pocket
location and size were ruled out as the explanation; what matters is the *shape* of the residue
set that a real ligand selects.

## What this does and does not show

- **Does:** the reproduction is faithful, and it survives decoys that DrugCLIP never saw.
  Leaders alone are DrugCLIP's own output, so they only test agreement with the authors; the
  decoys make the test independent.
- **Is a lower bound:** ChEMBL contains genuine binders for these kinases that we labelled as
  decoys.
- **The wrong-pocket control is not a null.** Most targets are kinases, and kinase inhibitors
  really do bind related kinases. Measured per target, the right pocket gives AUC 0.806; an
  *unrelated* target's pocket gives 0.563.
- **Coverage is 57 of 66 targets.**

## Open work

- **182 pockets from the GenPack route** have no recoverable ligand, so they are still on the
  old definition and carry no signal. Fixing them would bring coverage to 66 targets. Ideas:
  transplant a ligand from a similar pocket, or dock an external binder.
- Every DrugCLIP embedding made before **2026-09-14 is void** because of two encoder bugs, since
  fixed. Re-encode before use.

How to run it: [`scripts/drugclip_scripts/validation/`](../scripts/drugclip_scripts/validation/README.md).
