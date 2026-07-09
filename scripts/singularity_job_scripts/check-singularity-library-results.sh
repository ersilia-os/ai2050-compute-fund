#!/bin/bash
# Check input vs output line counts for a singularity library job.
# Reports missing chunks and row count mismatches.
#
# Usage: check-singularity-library-results.sh <model_id> <library_name>
# Example: check-singularity-library-results.sh mtb-public-models Coconut_715K

MODEL_ID=$1
LIBRARY_NAME=$2

if [ -z "$MODEL_ID" ] || [ -z "$LIBRARY_NAME" ]; then
    echo "Usage: $0 <model_id> <library_name>"
    echo "Example: $0 mtb-public-models Coconut_715K"
    exit 1
fi

INPUT_DIR="/fsx/input/${LIBRARY_NAME}"
OUTPUT_DIR="/fsx/output/${LIBRARY_NAME}/${MODEL_ID}"

mapfile -t INPUT_CHUNKS < <(ls "${INPUT_DIR}"/${LIBRARY_NAME}_chunk_*.csv 2>/dev/null | sort)
TOTAL=${#INPUT_CHUNKS[@]}

if [ "$TOTAL" -eq 0 ]; then
    echo "ERROR: No ${LIBRARY_NAME}_chunk_*.csv files found in $INPUT_DIR"
    exit 1
fi

MISSING=()
MISMATCH=()
DONE=0

for INPUT_FILE in "${INPUT_CHUNKS[@]}"; do
    CHUNK_NUM=$(basename "$INPUT_FILE" .csv | grep -oP '\d+$')
    OUTPUT_FILE="${OUTPUT_DIR}/${MODEL_ID}_${CHUNK_NUM}.csv"

    if [ ! -f "$OUTPUT_FILE" ]; then
        MISSING+=("$CHUNK_NUM")
    else
        IN_ROWS=$(( $(wc -l < "$INPUT_FILE") - 1 ))
        OUT_ROWS=$(( $(wc -l < "$OUTPUT_FILE") - 1 ))
        if [ "$IN_ROWS" -ne "$OUT_ROWS" ]; then
            MISMATCH+=("$CHUNK_NUM")
        else
            DONE=$(( DONE + 1 ))
        fi
    fi
done

echo ""
echo "Model  : $MODEL_ID"
echo "Library: $LIBRARY_NAME"
printf "=%.0s" {1..60}; echo ""
printf "%-10s %-10s %-10s %-10s\n" "Chunks" "Missing" "Mismatch" "Done"
printf -- "-%.0s" {1..60}; echo ""
printf "%-10d %-10d %-10d %-10s\n" "$TOTAL" "${#MISSING[@]}" "${#MISMATCH[@]}" "${DONE}/${TOTAL}"

if [ ${#MISSING[@]} -gt 0 ]; then
    SHOWN=("${MISSING[@]:0:20}")
    MSG=$(IFS=", "; echo "${SHOWN[*]}")
    [ ${#MISSING[@]} -gt 20 ] && MSG="${MSG} ... (+$(( ${#MISSING[@]} - 20 )) more)"
    echo "  MISSING chunks : $MSG"
fi

if [ ${#MISMATCH[@]} -gt 0 ]; then
    SHOWN=("${MISMATCH[@]:0:20}")
    MSG=$(IFS=", "; echo "${SHOWN[*]}")
    [ ${#MISMATCH[@]} -gt 20 ] && MSG="${MSG} ... (+$(( ${#MISMATCH[@]} - 20 )) more)"
    echo "  MISMATCH chunks: $MSG"
fi

printf "=%.0s" {1..60}; echo ""
echo ""
