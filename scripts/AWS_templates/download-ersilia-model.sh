#!/bin/bash
# download-ersilia-model.sh: make sure a SIF image is present in /shared/sif-files/.
#
# Where images come from (since 2026-11-23):
#   eosXXXX_vN     -> s3://models-sif/eosXXXX_vN.sif  (Ersilia account, the ONLY source for models)
#   anything else  -> s3://ai2050-ersilia-cluster/sif-files/<name>.sif  (drugclip, unidock, ...)
# There is no fallback: a model that is not in models-sif cannot be fetched.
#
# Usage:
#   download-ersilia-model.sh <name> [--refresh]
#     <name>      eos7d58_v1, eos7d58_v1.sif, drugclip, ...
#     --refresh   re-check the source and replace the cached copy if the S3 object changed.
#                 Ersilia rebuilds images under the same name on minor releases, so this is
#                 never done automatically: a silent swap mid-library would mix two builds
#                 in one output folder.
#
# Every model submit script calls this before sbatch. If the image is already cached it
# exits 0 without touching S3, so it is cheap to call on every submission.
#
# Each download is appended to /shared/sif-files/MANIFEST.tsv
# (date, name, source, etag, bytes, host) so any result can be traced to the exact build.
#
# models-sif grants GetObject only (no ListBucket) to this account, so a missing image and
# a permissions problem look the same: head-object fails with 403.
#
# Downloads land in /shared/sif-files/.partial/ and are renamed into place, so jobs that
# already have the old image open keep reading it. A per-name lock stops two submits from
# downloading the same image at once.
#
# Exit: 0 present or downloaded, 1 fetch error, 2 usage error.

set -uo pipefail

SIF_DIR="${SIF_DIR:-/shared/sif-files}"
MODELS_BUCKET="models-sif"
LOCAL_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"
REGION="eu-north-1"
MANIFEST="${SIF_DIR}/MANIFEST.tsv"
PARTIAL_DIR="${SIF_DIR}/.partial"
LOCK_WAIT=1800   # seconds to wait for another download of the same image

usage() {
    echo "Usage: $(basename "$0") <name> [--refresh]"
    echo "  eosXXXX_vN  -> s3://${MODELS_BUCKET}/  (model SIFs: Ersilia account only)"
    echo "  other       -> s3://${LOCAL_BUCKET}/sif-files/"
    exit 2
}

NAME=""
REFRESH=0
for arg in "$@"; do
    case "$arg" in
        --refresh) REFRESH=1 ;;
        -h|--help) usage ;;
        -*) echo "ERROR: unknown option: $arg"; usage ;;
        *)  if [ -n "$NAME" ]; then echo "ERROR: one name at a time"; usage; fi
            NAME="$arg" ;;
    esac
done
[ -n "$NAME" ] || usage
NAME="${NAME%.sif}"

if [[ "$NAME" == eos* ]]; then
    if [[ ! "$NAME" =~ ^eos[0-9a-z]{4}_v[0-9]+$ ]]; then
        echo "ERROR: '$NAME' looks like an Ersilia model but is not of the form eosXXXX_vN."
        echo "       Model SIFs are named by major version, e.g. eos7d58_v1."
        exit 2
    fi
    BUCKET="$MODELS_BUCKET"
    KEY="${NAME}.sif"
else
    BUCKET="$LOCAL_BUCKET"
    KEY="sif-files/${NAME}.sif"
fi
SRC="s3://${BUCKET}/${KEY}"
DEST="${SIF_DIR}/${NAME}.sif"

# Last manifest field for this name (empty if never downloaded through this script).
manifest_field() {
    [ -f "$MANIFEST" ] || return 0
    awk -F'\t' -v n="$NAME" -v f="$1" '$2 == n { v = $f } END { print v }' "$MANIFEST"
}

warn_if_legacy() {
    if [[ "$NAME" == eos* ]] && [[ "$(manifest_field 3)" != "s3://${MODELS_BUCKET}/"* ]]; then
        echo "⚠ $DEST was not downloaded from models-sif (legacy AI2050 build)."
        echo "  Replace it with: $(basename "$0") $NAME --refresh   (or run purge-model-sifs.sh)"
    fi
}

# Fast path: already cached, no S3 call.
if [ -f "$DEST" ] && [ "$REFRESH" -eq 0 ]; then
    echo "✓ SIF present: $DEST"
    warn_if_legacy
    exit 0
fi

mkdir -p "$PARTIAL_DIR" || { echo "ERROR: cannot create $PARTIAL_DIR"; exit 1; }
exec 9>"${PARTIAL_DIR}/${NAME}.lock"
if ! flock -w "$LOCK_WAIT" 9; then
    echo "ERROR: another download of $NAME has held the lock for over ${LOCK_WAIT}s"
    exit 1
fi

# Another process may have finished the download while we waited for the lock.
if [ -f "$DEST" ] && [ "$REFRESH" -eq 0 ]; then
    echo "✓ SIF present: $DEST (downloaded by a concurrent call)"
    exit 0
fi

META=$(aws s3api head-object --bucket "$BUCKET" --key "$KEY" --region "$REGION" \
       --query '[ETag,ContentLength]' --output text 2>&1)
if [ $? -ne 0 ]; then
    echo "✗ Cannot read $SRC"
    echo "$META" | sed 's/^/    /' | head -3
    if [ "$BUCKET" = "$MODELS_BUCKET" ]; then
        echo "  Either ${KEY} is not in models-sif, or this account lost read access."
        echo "  (models-sif cannot be listed from here, so the two look the same.)"
        echo "  Model SIFs come ONLY from models-sif: ask the Ersilia team to publish it."
    fi
    exit 1
fi
ETAG=$(echo "$META" | awk '{ print $1 }' | tr -d '"')
SIZE=$(echo "$META" | awk '{ print $2 }')

if [ -f "$DEST" ]; then   # --refresh on a cached image
    if [ "$ETAG" = "$(manifest_field 4)" ] && [ "$SIZE" = "$(stat -c %s "$DEST")" ]; then
        echo "✓ $DEST is already the current build (ETag $ETAG)"
        exit 0
    fi
    echo "⚠ Replacing $DEST with a different build from $SRC."
    echo "  Libraries already partly run with this model will mix two builds from now on."
fi

TMP="${PARTIAL_DIR}/${NAME}.sif.$(hostname -s).$$"
trap 'rm -f "$TMP"' EXIT

echo "Downloading $SRC ($(numfmt --to=iec "$SIZE")) ..."
if ! aws s3 cp "$SRC" "$TMP" --region "$REGION" --only-show-errors; then
    echo "✗ Download failed: $SRC"
    exit 1
fi

GOT=$(stat -c %s "$TMP")
if [ "$GOT" != "$SIZE" ]; then
    echo "✗ Size mismatch for $SRC: got $GOT bytes, expected $SIZE"
    exit 1
fi

chmod 644 "$TMP"
mv -f "$TMP" "$DEST" || { echo "✗ Could not move download into $DEST"; exit 1; }
trap - EXIT

[ -f "$MANIFEST" ] || printf 'date\tname\tsource\tetag\tbytes\thost\n' > "$MANIFEST"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$NAME" "$SRC" "$ETAG" "$SIZE" \
    "$(hostname -s)" >> "$MANIFEST"

echo "✓ Downloaded: $DEST ($(numfmt --to=iec "$SIZE"), ETag $ETAG)"
