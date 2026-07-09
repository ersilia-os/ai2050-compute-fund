#!/bin/bash
# Check input vs output line counts for a singularity model.
# Reports missing chunks and row count mismatches.
#
# Usage: check-singularity-results.sh <model_id>
# Example: check-singularity-results.sh mtb-public-models

MODEL_ID=$1

if [ -z "$MODEL_ID" ]; then
    echo "Usage: $0 <model_id>"
    exit 1
fi

INPUT_DIR="/fsx/input/batch_inputs"
OUTPUT_DIR="/fsx/output/batch_outputs"

mapfile -t INPUT_CHUNKS < <(ls "${INPUT_DIR}"/smiles_*.csv 2>/dev/null | sort)
TOTAL=${#INPUT_CHUNKS[@]}

if [ "$TOTAL" -eq 0 ]; then
    echo "ERROR: No input chunks found in $INPUT_DIR"
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
echo "Model: $MODEL_ID"
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
