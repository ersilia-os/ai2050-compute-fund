#!/bin/bash
#SBATCH --job-name=drugclip-screen
#SBATCH --partition=cpu-queue
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=08:00:00
#SBATCH --output=/shared/logs/drugclip-screen-%j.out
#SBATCH --error=/shared/logs/drugclip-screen-%j.err
#
# Score an encoded library against every encoded pocket set.
#
# cpu-queue, not gpu-queue: this is BLAS over precomputed embeddings, no inference. The
# GPU-only rule applies to ENCODING.
#
# --exclusive is not tidiness. cpu-queue is CR_CPU, so Slurm does no memory accounting and
# co-scheduled jobs overpack the node until something is OOM-killed. The same packing on
# gpu-queue is what put 10 encoders on one T4 and failed all 12 pocket jobs on 2026-10-06.
#
# Memory: screen_library.py holds the (6,128,N) float32 deck ONCE (1.4 GB for 460k,
# 32 GB for REAL 10.4M) plus the score rows; expected REAL peak ~45-50 GB, under the
# c6i.8xlarge's 64 GB. Before 2026-11-25 the loader held up to three copies (~96 GB for
# REAL). The log ends with the measured peak RSS.
#
# Usage:
#   sbatch run-screen.sh <library> [out_dir]
#
#   LIBRARY   e.g. Enamine_Hit_Locator_460K
#   OUT_DIR   default /fsx/output/<library>/screen
#
# Optional env:
#   TARGETS_BASES   space-separated pocket sets
#                   (default: /fsx/input/ai2050_targets = targets_ligand + targets_mtb_v2,
#                   each target labelled with its original set via sets.csv)
#   TOP_N           rows per target in the convenience export (default 1000)
#
# BEFORE RUNNING, the embeddings must be post-2026-09-14. Everything under
# /fsx/output/*/drugclip encoded before then is VOID -- lexicographic row order and partial
# fold-major writes, both silent. Hit Locator was re-encoded 2026-10-06 (job 458, 47/47).

set -euo pipefail

LIBRARY=${1:-}
OUT_DIR=${2:-}
PY=${PY:-/shared/python39/bin/python3.9}
# NOT $(dirname "${BASH_SOURCE[0]}"): sbatch COPIES the batch script to
# /var/spool/slurmd/job<id>/ and runs it from there, so BASH_SOURCE points at the spool
# copy and screen_library.py is not beside it. Scripts invoked with plain `bash` (e.g.
# submit-pocket-encode.sh) can use BASH_SOURCE; an sbatch script cannot.
SCRIPT_DIR=${SCRIPT_DIR:-/shared/scripts/drugclip_scripts/screening}

if [ -z "$LIBRARY" ]; then
    echo "Usage: sbatch $0 <library> [out_dir]"
    echo "  e.g. sbatch $0 Enamine_Hit_Locator_460K"
    exit 1
fi

OUT_DIR=${OUT_DIR:-/fsx/output/${LIBRARY}/screen}
EMB_DIR=/fsx/output/${LIBRARY}/drugclip
INPUT_DIR=/fsx/input/${LIBRARY}
TARGETS_BASES=${TARGETS_BASES:-"/fsx/input/ai2050_targets"}
TOP_N=${TOP_N:-1000}

echo "=========================================="
echo "DrugCLIP screen"
echo "=========================================="
echo "Library     : $LIBRARY"
echo "Embeddings  : $EMB_DIR"
echo "Inputs      : $INPUT_DIR"
echo "Pocket sets : $TARGETS_BASES"
echo "Out dir     : $OUT_DIR"
echo "Top N       : $TOP_N"
echo "Node        : $(hostname)   CPUs: $(nproc)"
echo "=========================================="

if [ ! -d "$EMB_DIR" ]; then
    echo "ERROR: no embeddings at $EMB_DIR"
    exit 1
fi
N_H5=$(ls "$EMB_DIR"/${LIBRARY}_drugclip_*.h5 2>/dev/null | wc -l)
if [ "$N_H5" -eq 0 ]; then
    echo "ERROR: no ${LIBRARY}_drugclip_*.h5 under $EMB_DIR"
    exit 1
fi
echo "Found $N_H5 embedding chunk(s)"

# The row-order remap needs the chunk CSVs; without them _load_pairs drops the chunk.
N_CSV=$(ls "$INPUT_DIR"/${LIBRARY}_chunk_*.csv 2>/dev/null | wc -l)
echo "Found $N_CSV chunk CSV(s) in $INPUT_DIR"
if [ "$N_CSV" -eq 0 ]; then
    echo "WARN: no chunk CSVs found - see _loader_row_order; chunks may be skipped"
fi

BASE_ARGS=()
for B in $TARGETS_BASES; do
    if [ ! -d "$B" ]; then
        echo "WARN: pocket set not found, skipping: $B"
        continue
    fi
    BASE_ARGS+=(--targets-base "$B")
done
if [ ${#BASE_ARGS[@]} -eq 0 ]; then
    echo "ERROR: no pocket sets available"
    exit 1
fi

SCREEN_PY="${SCRIPT_DIR}/screen_library.py"
if [ ! -f "$SCREEN_PY" ]; then
    echo "ERROR: screen_library.py not found at $SCREEN_PY"
    echo "       Set SCRIPT_DIR if the screening scripts live elsewhere."
    exit 1
fi

mkdir -p "$OUT_DIR"
echo ""
# `|| RC=$?` rather than a bare call: under `set -e` a non-zero exit terminates the
# script immediately, so a plain `RC=$?` on the next line is unreachable and the error
# message never prints -- which is exactly how job 402577 failed silently.
RC=0
"$PY" "$SCREEN_PY" \
    --library "$LIBRARY" \
    --emb-dir "$EMB_DIR" \
    --input-dir "$INPUT_DIR" \
    "${BASE_ARGS[@]}" \
    --out-dir "$OUT_DIR" \
    --top-n "$TOP_N" || RC=$?

if [ $RC -ne 0 ]; then
    echo "ERROR: screen_library.py exited $RC (see the .err log for the traceback)"
    exit $RC
fi

echo ""
echo "=========================================="
ls -la "$OUT_DIR"
echo "=========================================="
echo "Done. Pull results to the laptop with:"
echo "  aws s3 sync s3://ai2050-ersilia-cluster/${OUT_DIR#/fsx/}/ ./output/$(basename "$OUT_DIR")_${LIBRARY}/"
