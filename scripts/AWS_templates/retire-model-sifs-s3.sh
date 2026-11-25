#!/bin/bash
# retire-model-sifs-s3.sh: take every model SIF out of s3://ai2050-ersilia-cluster/sif-files/.
#
# Since 2026-11-23 model SIFs come only from s3://models-sif (Ersilia account). This removes
# the 94 eos*.sif objects that were in the AI2050 sif-files/ folder (inventory of 2026-11-23):
#
#   ARCHIVE (7)  models with NO image of any version in models-sif. Copied to
#                s3://ai2050-ersilia-cluster/sif-archive/ as GLACIER DEEP_ARCHIVE, size-checked,
#                then removed from sif-files/. Deep Archive keeps them for well under $1/month,
#                but has a 180-day minimum charge and takes 12-48 h to restore.
#   DELETE (87)  everything else. Their exact name or a newer major is in models-sif.
#                The 48 older majors among them (e.g. eos5eya_v2/_v3) will exist NOWHERE after this.
#
# The lists are explicit (no wildcards), so anything uploaded later is never touched.
# Non-model SIFs (drugclip.sif, drugclip_pocket.sif, unidock.sif) stay where they are.
# The AI2050 bucket has no versioning: deletes are PERMANENT.
#
# Usage (from a machine with AI2050-account credentials, e.g. your laptop or the head node):
#   bash retire-model-sifs-s3.sh            # dry run: show what would happen
#   bash retire-model-sifs-s3.sh --yes      # archive the 7, then delete the 87
#   AWS_PROFILE=default bash retire-model-sifs-s3.sh --yes
#
# Run it AFTER download-ersilia-model.sh is deployed and tested on the cluster.

set -uo pipefail

BUCKET="ai2050-ersilia-cluster"
SRC_PREFIX="sif-files"
ARCHIVE_PREFIX="sif-archive"
REGION="eu-north-1"

ARCHIVE=(
    eos0h1a_v1.sif
    eos0h1b_v1.sif
    eos0h2a_v1.sif
    eos0p1a_v1.sif
    eos0p2a_v1.sif
    eos3nn9_v1.sif
    eos7d58_v1.sif
)

DELETE=(
    eos11sm_v1.sif eos12x7_v1.sif eos18ie_v1.sif eos19mt_v2.sif eos1klk_v1.sif eos1lb5_v2.sif
    eos1n4b_v1.sif eos1soi_v1.sif eos21dr_v3.sif eos21dr_v4.sif eos2e3s_v2.sif eos2e3s_v3.sif
    eos2egp_v1.sif eos2ta5_v1.sif eos2xeq_v1.sif eos3804_v1.sif eos3dys_v1.sif eos3l5f_v1.sif
    eos3lyd_v1.sif eos3mk2_v1.sif eos3ujl_v1.sif eos42ez_v1.sif eos43d6_v2.sif eos43d6_v3.sif
    eos46ev_v1.sif eos4an7_v2.sif eos4an7_v3.sif eos4djh_v1.sif eos4e40_v1.sif eos4ex3_v1.sif
    eos4k4f_v1.sif eos4n4d_v1.sif eos4r1g_v1.sif eos4u6p_v1.sif eos5axz.sif eos5axz_v2.sif
    eos5bsw_v1.sif eos5eya_v2.sif eos5eya_v3.sif eos5f0j_v1.sif eos5jv3_v1.sif eos5jv3_v2.sif
    eos5nqn_v2.sif eos5q52_v2.sif eos5q52_v3.sif eos5qya_v2.sif eos5qya_v3.sif eos69jj_v1.sif
    eos6ojg_v1.sif eos6wb7_v2.sif eos6wb7_v3.sif eos74km_v1.sif eos7dg4_v1.sif eos7iak_v2.sif
    eos7iak_v3.sif eos7ike_v1.sif eos7kpb_v1.sif eos7l5m_v1.sif eos7m30_v1.sif eos7ye0_v1.sif
    eos7ye0_v2.sif eos80ch_v1.sif eos817d_v1.sif eos81zy_v3.sif eos81zy_v4.sif eos82v1_v1.sif
    eos8aa5_v1.sif eos8d8a_v2.sif eos8jx6_v2.sif eos8jx6_v3.sif eos8lcw_v2.sif eos8lcw_v3.sif
    eos8v1a_v2.sif eos8v1a_v3.sif eos96f4_v1.sif eos9bpi_v2.sif eos9bpi_v3.sif eos9cvt_v1.sif
    eos9eyo_v2.sif eos9eyo_v3.sif eos9ivc_v1.sif eos9ivc_v2.sif eos9n1s_v1.sif eos9o72_v1.sif
    eos9p4a_v1.sif eos9x3z_v1.sif eos9ym3_v1.sif   
)

DO_IT=0
case "${1:-}" in
    --yes) DO_IT=1 ;;
    "") ;;
    *) echo "Usage: $0 [--yes]"; exit 2 ;;
esac

size_of() {   # prints ContentLength, or nothing if the object does not exist
    aws s3api head-object --bucket "$BUCKET" --key "$1" --region "$REGION" \
        --query ContentLength --output text 2>/dev/null
}

echo "Bucket: s3://$BUCKET/$SRC_PREFIX/   mode: $([ $DO_IT -eq 1 ] && echo DELETE || echo DRY-RUN)"
echo ""

# ---------------------------------------------------------------- archive the 7 orphans
echo "== ARCHIVE ${#ARCHIVE[@]} -> s3://$BUCKET/$ARCHIVE_PREFIX/ (DEEP_ARCHIVE)"
ARCH_FAIL=0
for f in "${ARCHIVE[@]}"; do
    src="$SRC_PREFIX/$f"; dst="$ARCHIVE_PREFIX/$f"
    s=$(size_of "$src")
    if [ -z "$s" ]; then
        d=$(size_of "$dst")
        [ -n "$d" ] && echo "  = $f already archived" || { echo "  ✗ $f in neither place"; ARCH_FAIL=1; }
        continue
    fi
    if [ $DO_IT -eq 0 ]; then echo "  would archive $f ($s bytes)"; continue; fi
    if ! aws s3 cp "s3://$BUCKET/$src" "s3://$BUCKET/$dst" --storage-class DEEP_ARCHIVE \
            --region "$REGION" --only-show-errors; then
        echo "  ✗ copy failed: $f (original kept)"; ARCH_FAIL=1; continue
    fi
    d=$(size_of "$dst")
    if [ "$d" != "$s" ]; then
        echo "  ✗ archived size $d != original $s: $f (original kept)"; ARCH_FAIL=1; continue
    fi
    aws s3 rm "s3://$BUCKET/$src" --region "$REGION" --only-show-errors \
        && echo "  ✓ archived $f" || { echo "  ✗ archived but could not remove original: $f"; ARCH_FAIL=1; }
done

if [ $ARCH_FAIL -ne 0 ]; then
    echo ""
    echo "Archive step had failures: stopping before any deletion."
    exit 1
fi

# ---------------------------------------------------------------- delete the 87
echo ""
echo "== DELETE ${#DELETE[@]} from s3://$BUCKET/$SRC_PREFIX/"
N_DEL=0; N_GONE=0; N_FAIL=0
for f in "${DELETE[@]}"; do
    case "$f" in eos*.sif) ;; *) echo "  ✗ refusing non-model name: $f"; N_FAIL=$((N_FAIL+1)); continue ;; esac
    s=$(size_of "$SRC_PREFIX/$f")
    if [ -z "$s" ]; then N_GONE=$((N_GONE+1)); continue; fi
    if [ $DO_IT -eq 0 ]; then echo "  would delete $f ($s bytes)"; N_DEL=$((N_DEL+1)); continue; fi
    if aws s3 rm "s3://$BUCKET/$SRC_PREFIX/$f" --region "$REGION" --only-show-errors; then
        N_DEL=$((N_DEL+1))
    else
        echo "  ✗ delete failed: $f"; N_FAIL=$((N_FAIL+1))
    fi
done

echo ""
echo "$([ $DO_IT -eq 1 ] && echo Deleted || echo 'Would delete'): $N_DEL   already gone: $N_GONE   failed: $N_FAIL"
echo ""
echo "Remaining in s3://$BUCKET/$SRC_PREFIX/:"
aws s3 ls "s3://$BUCKET/$SRC_PREFIX/" --region "$REGION" | awk '{ print "  " $4 }'
[ $DO_IT -eq 0 ] && echo "" && echo "Dry run: nothing changed. Re-run with --yes."
exit $(( N_FAIL > 0 ))
