#!/bin/bash
# Make the pocket-encoder's batch size configurable, without rebuilding the sif.
#
# The problem
# -----------
# encode_pockets_multi_folds() hardcodes the DataLoader batch:
#
#   unimol/tasks/drugclip.py:1626
#     pocket_data = torch.utils.data.DataLoader(pocket_dataset, batch_size=32, ...)
#
# The Gaussian distance kernel (unimol/models/unimol.py, GaussianLayer K=128) then
# materialises a (batch, N, N, K) tensor, N = pocket atoms. At batch 32 with N = 385 that
# is 32 * 385^2 * 128 * 4 B = 2.4 GB for ONE tensor, and `((x - mean) / std) ** 2` makes
# several temporaries -- 13.66 GB on a 14.56 GB GPU, which is exactly the observed OOM:
#
#   File "/drugclip/unimol/models/unimol.py", line 395, in <forward op>
#     return torch.exp(-0.5 * (((x - mean) / std) ** 2)) / (a * std)
#   RuntimeError: CUDA out of memory. Tried to allocate 1.17 GiB.
#
# It only bites targets that have BOTH many conformations and large pockets, which is why
# it appeared only with the true-ligand pocket set (median 211 atoms vs 54 before) and why
# it is not a clean function of pocket size alone.
#
# The fix
# -------
# Lowering the batch changes NOTHING about the embeddings -- each conformation is encoded
# independently; the batch only controls how many are done at once. That makes this strictly
# preferable to lowering --max-pocket-atoms, which would crop pockets and change the result.
#
# This script extracts drugclip.py from the sif, swaps the literal 32 for an env lookup, and
# leaves it where run-pocket-encode.sh can bind-mount it over the sif's copy. `import os` is
# already present at line 5, so no other change is needed.
#
# Usage (head node, once):
#   bash patch-pocket-batch.sh
# then encode with e.g.
#   POCKET_BATCH_SIZE=4 POCKET_BASE=/fsx/input/targets_ligand \
#     bash submit-pocket-encode.sh --max-pocket-atoms 511 --exclusive

set -euo pipefail

SIF=${SIF:-/shared/sif-files/drugclip_pocket.sif}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/patched"
OUT="${OUT_DIR}/drugclip.py"
SRC_IN_SIF=/drugclip/unimol/tasks/drugclip.py

OLD='batch_size=32, collate_fn=pocket_dataset.collater'
NEW='batch_size=int(os.environ.get("POCKET_BATCH_SIZE", 32)), collate_fn=pocket_dataset.collater'

[ -f "$SIF" ] || { echo "ERROR: sif not found: $SIF"; exit 1; }
mkdir -p "$OUT_DIR"

echo "Extracting $SRC_IN_SIF from $(basename "$SIF") ..."
apptainer exec "$SIF" cat "$SRC_IN_SIF" > "$OUT"
LINES=$(wc -l < "$OUT")
[ "$LINES" -gt 1000 ] || { echo "ERROR: extracted file looks wrong ($LINES lines)"; exit 1; }

# The literal must appear exactly once, or we are patching something we do not understand.
N=$(grep -c "$OLD" "$OUT" || true)
if [ "$N" -ne 1 ]; then
    echo "ERROR: expected exactly 1 occurrence of the batch literal, found $N."
    echo "       The sif's drugclip.py differs from what this patch was written against."
    echo "       Inspect it before proceeding:  grep -n 'batch_size=32' $OUT"
    exit 1
fi
grep -q '^import os$' "$OUT" || { echo "ERROR: 'import os' missing from the extracted file"; exit 1; }

python3 - "$OUT" "$OLD" "$NEW" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
assert s.count(old) == 1
open(path, 'w').write(s.replace(old, new))
PY

echo "Patched -> $OUT"
grep -n "POCKET_BATCH_SIZE" "$OUT" | sed 's/^/  /'
echo ""
echo "Line count unchanged: $(wc -l < "$OUT") (was $LINES)"
echo ""
echo "Next:"
echo "  POCKET_BATCH_SIZE=4 POCKET_BASE=/fsx/input/targets_ligand \\"
echo "    bash submit-pocket-encode.sh --max-pocket-atoms 511 --exclusive --max-pending 2"
