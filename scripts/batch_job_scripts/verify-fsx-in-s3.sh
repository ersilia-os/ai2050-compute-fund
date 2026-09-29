#!/bin/bash
# READ-ONLY audit: confirm every file under FSx output already exists in S3
# with a matching byte size, so you know what is safe to delete from FSx.
#
# For each /fsx/output/<library>/<model_id>/ directory it compares every local
# file against s3://ai2050-ersilia-cluster/output/<library>/<model_id>/ by
# RELATIVE PATH + BYTE SIZE. It never uploads and never deletes anything.
#
# Exit status:
#   0  every scanned file is present in S3 with a matching size  -> safe to clean
#   1  one or more files are missing from S3 or differ in size   -> NOT safe
#   2  usage / environment error
#
# Usage:
#   bash verify-fsx-in-s3.sh [options] [model_id ...]
#
# Options:
#   --library NAME   Restrict to a library (repeatable). Default: all libraries.
#   --profile NAME   AWS profile to use. Default: ambient creds / instance role.
#   --bucket URI     S3 root. Default: s3://ai2050-ersilia-cluster
#   --fsx DIR        FSx output root. Default: /fsx/output
#   -q, --quiet      Suppress per-file OK lines; show summaries + problems only.
#   -h, --help       Show this help.
#
# Positional model_id args restrict the scan to those model IDs.
#
# Examples:
#   bash verify-fsx-in-s3.sh                       # audit everything in /fsx/output
#   bash verify-fsx-in-s3.sh eos7d58_v1 eos1af5_v1 # only these models
#   bash verify-fsx-in-s3.sh --library Coconut_715K
#   bash verify-fsx-in-s3.sh --profile default     # e.g. when running off-cluster

set -uo pipefail

BUCKET="s3://ai2050-ersilia-cluster"
FSX_OUTPUT="/fsx/output"
PROFILE=""
QUIET=false
LIBS=()
MODELS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --library) LIBS+=("$2"); shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --bucket)  BUCKET="$2"; shift 2 ;;
        --fsx)     FSX_OUTPUT="$2"; shift 2 ;;
        -q|--quiet) QUIET=true; shift ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *) MODELS+=("$1"); shift ;;
    esac
done

AWS_ARGS=()
[ -n "$PROFILE" ] && AWS_ARGS=(--profile "$PROFILE")

if [ ! -d "$FSX_OUTPUT" ]; then
    echo "ERROR: FSx output dir not found: $FSX_OUTPUT" >&2
    exit 2
fi

# Membership helper: is $1 present in the remaining args?
in_list() { local needle="$1"; shift; local x; for x in "$@"; do [ "$x" = "$needle" ] && return 0; done; return 1; }

echo "=========================================="
echo "FSx -> S3 verification (READ-ONLY)"
echo "=========================================="
echo "Date    : $(date)"
echo "FSx root: $FSX_OUTPUT"
echo "S3 root : ${BUCKET}/output"
[ -n "$PROFILE" ]      && echo "Profile : $PROFILE"
[ ${#LIBS[@]} -gt 0 ]  && echo "Libs    : ${LIBS[*]}"
[ ${#MODELS[@]} -gt 0 ] && echo "Models  : ${MODELS[*]}"
echo "=========================================="
echo ""

# Discover every <library>/<model_id> directory.
mapfile -t MODEL_DIRS < <(find "$FSX_OUTPUT" -mindepth 2 -maxdepth 2 -type d | sort)

if [ ${#MODEL_DIRS[@]} -eq 0 ]; then
    echo "Nothing to scan: no <library>/<model_id> dirs under $FSX_OUTPUT"
    exit 0
fi

TOTAL_FILES=0
TOTAL_OK=0
TOTAL_MISSING=0
TOTAL_MISMATCH=0
SCANNED_DIRS=0
LISTING_ERRORS=0
PROBLEMS=()   # "LIBRARY/MODEL/relpath : reason"

for LOCAL_DIR in "${MODEL_DIRS[@]}"; do
    MODEL_ID=$(basename "$LOCAL_DIR")
    LIBRARY=$(basename "$(dirname "$LOCAL_DIR")")

    # Apply optional filters.
    if [ ${#LIBS[@]} -gt 0 ]   && ! in_list "$LIBRARY" "${LIBS[@]}";   then continue; fi
    if [ ${#MODELS[@]} -gt 0 ] && ! in_list "$MODEL_ID" "${MODELS[@]}"; then continue; fi

    S3_PREFIX="${BUCKET}/output/${LIBRARY}/${MODEL_ID}"
    KEY_PREFIX="output/${LIBRARY}/${MODEL_ID}/"
    SCANNED_DIRS=$(( SCANNED_DIRS + 1 ))

    echo "------------------------------------------"
    echo "  ${LIBRARY}/${MODEL_ID}"

    # Build map of S3 relative-path -> byte size (one recursive listing).
    # NOTE: expand AWS_ARGS with the ${arr[@]+...} idiom so an *empty* array is
    # safe under `set -u` on bash < 4.4 (Amazon Linux 2 ships bash 4.2). A plain
    # "${AWS_ARGS[@]}" there throws "unbound variable", killing this subshell so
    # aws never runs and every file looks MISSING.
    # Capture stderr so a real S3 error is surfaced, never silently treated as
    # "all files missing".
    unset S3SIZE; declare -A S3SIZE
    S3_ERR=$(mktemp)
    while read -r _d _t size key; do
        [ -z "${key:-}" ] && continue
        rel="${key#"$KEY_PREFIX"}"
        S3SIZE["$rel"]="$size"
    done < <(aws s3 ls "${S3_PREFIX}/" --recursive ${AWS_ARGS[@]+"${AWS_ARGS[@]}"} 2>"$S3_ERR")

    if [ -s "$S3_ERR" ]; then
        echo "    ERROR: could not list S3 — $(head -1 "$S3_ERR")"
        echo "           NOT treating this dir as verified; do not clean it."
        rm -f "$S3_ERR"
        LISTING_ERRORS=$(( LISTING_ERRORS + 1 ))
        continue
    fi
    rm -f "$S3_ERR"

    local_files=0; ok=0; missing=0; mismatch=0
    while IFS=$'\t' read -r size rel; do
        [ -z "${rel:-}" ] && continue
        local_files=$(( local_files + 1 ))
        s3s="${S3SIZE[$rel]-__ABSENT__}"
        if [ "$s3s" = "__ABSENT__" ]; then
            missing=$(( missing + 1 ))
            PROBLEMS+=("${LIBRARY}/${MODEL_ID}/${rel} : MISSING in S3")
            [ "$QUIET" = false ] && echo "    MISSING  $rel"
        elif [ "$s3s" != "$size" ]; then
            mismatch=$(( mismatch + 1 ))
            PROBLEMS+=("${LIBRARY}/${MODEL_ID}/${rel} : SIZE local=${size} s3=${s3s}")
            [ "$QUIET" = false ] && echo "    SIZE!=   $rel (local=${size} s3=${s3s})"
        else
            ok=$(( ok + 1 ))
            [ "$QUIET" = false ] && echo "    ok       $rel"
        fi
    done < <(find "$LOCAL_DIR" -type f -printf '%s\t%P\n')

    if [ "$local_files" -eq 0 ]; then
        echo "    (no files)"
    else
        printf "    files=%d  ok=%d  missing=%d  size-mismatch=%d\n" \
            "$local_files" "$ok" "$missing" "$mismatch"
    fi

    TOTAL_FILES=$((    TOTAL_FILES + local_files ))
    TOTAL_OK=$((       TOTAL_OK + ok ))
    TOTAL_MISSING=$((  TOTAL_MISSING + missing ))
    TOTAL_MISMATCH=$(( TOTAL_MISMATCH + mismatch ))
done

echo ""
echo "=========================================="
echo "SUMMARY"
echo "=========================================="
printf "  dirs scanned   : %d\n" "$SCANNED_DIRS"
printf "  files checked  : %d\n" "$TOTAL_FILES"
printf "  in S3 (ok)     : %d\n" "$TOTAL_OK"
printf "  missing in S3  : %d\n" "$TOTAL_MISSING"
printf "  size-mismatch  : %d\n" "$TOTAL_MISMATCH"
printf "  S3 list errors : %d\n" "$LISTING_ERRORS"
echo "------------------------------------------"

# A dir whose S3 listing failed was not verified — never report SAFE then.
if [ "$LISTING_ERRORS" -gt 0 ]; then
    echo "  RESULT: NOT SAFE — S3 could not be listed for $LISTING_ERRORS dir(s)"
    echo "          (see ERROR lines above). Resolve access/region before cleaning."
    if [ "${#PROBLEMS[@]}" -gt 0 ]; then
        for p in "${PROBLEMS[@]}"; do echo "    - $p"; done
    fi
    echo "=========================================="
    exit 2
fi

# Guard against false confidence: filters that matched no directories, or
# directories that held no files, must NOT report "SAFE".
if [ "$SCANNED_DIRS" -eq 0 ]; then
    echo "  RESULT: NOTHING MATCHED — no <library>/<model_id> dirs matched your"
    echo "          filters. Check the library/model names; nothing was verified."
    echo "=========================================="
    exit 2
fi

if [ "$TOTAL_FILES" -eq 0 ]; then
    echo "  RESULT: NOTHING TO CHECK — matched dir(s) contained no files."
    echo "          Nothing was verified; not reporting safe."
    echo "=========================================="
    exit 2
fi

if [ "$(( TOTAL_MISSING + TOTAL_MISMATCH ))" -eq 0 ]; then
    echo "  RESULT: SAFE — every FSx file is in S3 with a matching size."
    echo "=========================================="
    exit 0
else
    echo "  RESULT: NOT SAFE — do NOT clean these until resolved:"
    for p in "${PROBLEMS[@]}"; do echo "    - $p"; done
    echo "=========================================="
    exit 1
fi
