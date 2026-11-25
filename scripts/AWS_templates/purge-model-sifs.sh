#!/bin/bash
# purge-model-sifs.sh: remove legacy model SIFs from /shared/sif-files/.
#
# Since 2026-11-23 model SIFs come only from s3://models-sif (Ersilia account). This removes
# every eos*.sif in /shared/sif-files that was NOT downloaded from models-sif according to
# MANIFEST.tsv, so the next submit fetches the Ersilia build (download-ersilia-model.sh).
# Non-model SIFs (drugclip, unidock, ...) are never touched.
#
# DRY RUN BY DEFAULT. Every eos*.sif is classified as:
#   KEEP       downloaded from models-sif (MANIFEST.tsv): left alone
#   REFETCH    legacy copy whose name exists in models-sif: deleted, re-fetched on next submit
#   AI2050-S3  legacy copy not in models-sif, but still in s3://ai2050-ersilia-cluster
#              (sif-files/ or sif-archive/): deleted; the model can no longer run here
#   ONLY-COPY  legacy copy found in no bucket: kept unless --include-only-copies
#
# Usage:
#   purge-model-sifs.sh                          # dry run: print the table only
#   purge-model-sifs.sh --yes                    # delete REFETCH + AI2050-S3
#   purge-model-sifs.sh --yes --include-only-copies   # also delete ONLY-COPY (permanent)
#
# Refuses to delete while this cluster's Slurm queue has jobs. /shared is mounted by BOTH
# clusters (AL2 and AL2023), so check squeue on the other head node too before --yes.
#
# The table is saved to /shared/logs/purge-model-sifs-<timestamp>.tsv in both modes.

set -uo pipefail

SIF_DIR="${SIF_DIR:-/shared/sif-files}"
MODELS_BUCKET="models-sif"
LOCAL_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"
REGION="eu-north-1"
MANIFEST="${SIF_DIR}/MANIFEST.tsv"
LOG_DIR="/shared/logs"

DO_DELETE=0
INCLUDE_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --yes) DO_DELETE=1 ;;
        --include-only-copies) INCLUDE_ONLY=1 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown argument: $arg"; exit 2 ;;
    esac
done

if [ "$DO_DELETE" -eq 1 ]; then
    SQUEUE=$(command -v squeue || echo /opt/slurm/bin/squeue)
    NJOBS=$("$SQUEUE" -h 2>/dev/null | wc -l)
    if [ "$NJOBS" -gt 0 ]; then
        echo "ERROR: $NJOBS job(s) in this cluster's queue. Wait until it is empty."
        exit 1
    fi
    echo "This cluster's queue is empty. /shared is shared with the other cluster:"
    echo "make sure its queue is empty too. Continuing in 10 s (Ctrl-C to abort)..."
    sleep 10
fi

# Names (without .sif) present in the AI2050 bucket, sif-files/ and sif-archive/.
AI2050_NAMES=$(
    for prefix in sif-files sif-archive; do
        aws s3 ls "s3://${LOCAL_BUCKET}/${prefix}/" --region "$REGION" 2>/dev/null \
            | awk '{ print $4 }'
    done | grep '\.sif$' | sed 's/\.sif$//' | sort -u
)

from_models_sif() {
    [ -f "$MANIFEST" ] || return 1
    awk -F'\t' -v n="$1" '$2 == n { s = $3 } END { exit !(s ~ /^s3:\/\/models-sif\//) }' "$MANIFEST"
}

in_models_sif() {
    aws s3api head-object --bucket "$MODELS_BUCKET" --key "$1.sif" --region "$REGION" \
        >/dev/null 2>&1
}

mkdir -p "$LOG_DIR"
TABLE="${LOG_DIR}/purge-model-sifs-$(date +%Y%m%d-%H%M%S).tsv"
printf 'class\tname\tbytes\taction\n' > "$TABLE"

declare -A COUNT=()
declare -A BYTES=()
TO_DELETE=()

shopt -s nullglob
for f in "$SIF_DIR"/eos*.sif; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .sif)
    size=$(stat -c %s "$f")
    if from_models_sif "$name"; then
        class=KEEP
    elif in_models_sif "$name"; then
        class=REFETCH
    elif grep -qxF "$name" <<< "$AI2050_NAMES"; then
        class=AI2050-S3
    else
        class=ONLY-COPY
    fi

    action=keep
    if [ "$class" = REFETCH ] || [ "$class" = AI2050-S3 ] \
       || { [ "$class" = ONLY-COPY ] && [ "$INCLUDE_ONLY" -eq 1 ]; }; then
        action=delete
        TO_DELETE+=("$f")
    fi

    COUNT[$class]=$(( ${COUNT[$class]:-0} + 1 ))
    BYTES[$class]=$(( ${BYTES[$class]:-0} + size ))
    printf '%s\t%s\t%s\t%s\n' "$class" "$name" "$size" "$action" >> "$TABLE"
    printf '%-10s %-16s %8s  %s\n' "$class" "$name" "$(numfmt --to=iec "$size")" "$action"
done

echo ""
echo "Summary:"
for c in KEEP REFETCH AI2050-S3 ONLY-COPY; do
    printf '  %-10s %4d files  %8s\n' "$c" "${COUNT[$c]:-0}" "$(numfmt --to=iec "${BYTES[$c]:-0}")"
done
echo "  Table: $TABLE"

if [ "${COUNT[ONLY-COPY]:-0}" -gt 0 ] && [ "$INCLUDE_ONLY" -eq 0 ]; then
    echo ""
    echo "⚠ ${COUNT[ONLY-COPY]} ONLY-COPY file(s) exist in no bucket and will be kept."
    echo "  Archive them to s3://${LOCAL_BUCKET}/sif-archive/ first, or pass --include-only-copies."
fi

if [ "$DO_DELETE" -eq 0 ]; then
    echo ""
    echo "Dry run: nothing deleted. Re-run with --yes to delete ${#TO_DELETE[@]} file(s)."
    exit 0
fi

echo ""
echo "Deleting ${#TO_DELETE[@]} file(s)..."
FAILED=0
for f in "${TO_DELETE[@]}"; do
    rm -f "$f" || { echo "✗ could not delete $f"; FAILED=$((FAILED + 1)); }
done
echo "Done. Deleted $(( ${#TO_DELETE[@]} - FAILED )), failed $FAILED."
