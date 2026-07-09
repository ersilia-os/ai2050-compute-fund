#!/bin/bash
# Check input vs output line counts for all libraries for a given model.
# Reports missing chunks and chunks with fully-empty result rows.
#
# Row counts use wc -l (fast, no Python file I/O).
# Empty row detection uses awk (fast, single pass per library).
#
# Usage: check-results.sh <model_id>
# Example: check-results.sh eos4k4f_v1

MODEL_ID=$1

if [ -z "$MODEL_ID" ]; then
    echo "Usage: $0 <model_id>"
    echo "Example: $0 eos4k4f_v1"
    exit 1
fi

LIBRARIES=(
    "Enamine_Hit_Locator_460K"
    "Coconut_715K"
    "Enamine_Liquid_Stock_2.5M"
    "Molport_Screening_Compounds_5.3M"
    "Enamine_Real_Sample_10.4M"
)

INPUT_COLS="key input smiles canonical_smiles"

echo ""
echo "Model: ${MODEL_ID}"
printf "=%.0s" {1..75}; echo ""
printf "%-45s %7s %8s %11s %7s\n" "Library" "Chunks" "Missing" "Empty rows" "Done"
printf -- "-%.0s" {1..75}; echo ""

for LIBRARY in "${LIBRARIES[@]}"; do
    INPUT_DIR="/fsx/input/${LIBRARY}"
    OUTPUT_DIR="/fsx/output/${LIBRARY}/${MODEL_ID}"

    if [ ! -d "$INPUT_DIR" ] || [ ! -d "$OUTPUT_DIR" ]; then
        printf "%-45s %7s %8s %11s %7s\n" "$LIBRARY" "—" "—" "—" "NOT RUN"
        continue
    fi

    mapfile -t INPUT_CHUNKS < <(ls "${INPUT_DIR}"/*_chunk_*.csv 2>/dev/null | sort)
    TOTAL=${#INPUT_CHUNKS[@]}

    if [ "$TOTAL" -eq 0 ]; then
        printf "%-45s %7s %8s %11s %7s\n" "$LIBRARY" "—" "—" "—" "NO INPUT"
        continue
    fi

    # ── Collect present output files and their chunk numbers ──────────────────
    MISSING_CHUNKS=()
    MISMATCH_CHUNKS=()
    PRESENT_OUTPUT_FILES=()
    PRESENT_CHUNK_NUMS=()

    for INPUT_FILE in "${INPUT_CHUNKS[@]}"; do
        CHUNK_NUM=$(basename "$INPUT_FILE" .csv | grep -oP '\d+$')
        OUTPUT_FILE="${OUTPUT_DIR}/${MODEL_ID}_results_${CHUNK_NUM}.csv"

        if [ ! -f "$OUTPUT_FILE" ]; then
            MISSING_CHUNKS+=("$CHUNK_NUM")
        else
            PRESENT_OUTPUT_FILES+=("$OUTPUT_FILE")
            PRESENT_CHUNK_NUMS+=("$CHUNK_NUM")
        fi
    done

    # ── Fast row counts via wc -l (one call for all input, one for all output) ─
    DONE=0
    declare -A IN_COUNTS OUT_COUNTS

    if [ ${#PRESENT_OUTPUT_FILES[@]} -gt 0 ]; then
        # Input counts for present chunks only
        PRESENT_INPUT_FILES=()
        for CHUNK_NUM in "${PRESENT_CHUNK_NUMS[@]}"; do
            for INPUT_FILE in "${INPUT_CHUNKS[@]}"; do
                if [[ "$INPUT_FILE" == *"_${CHUNK_NUM}.csv" ]]; then
                    PRESENT_INPUT_FILES+=("$INPUT_FILE")
                    break
                fi
            done
        done

        # wc -l on all input files at once, parse results
        while IFS= read -r LINE; do
            COUNT=$(echo "$LINE" | awk '{print $1}')
            FILE=$(echo "$LINE" | awk '{print $2}')
            [ "$FILE" = "total" ] && continue
            CHUNK=$(basename "$FILE" .csv | grep -oP '\d+$')
            IN_COUNTS[$CHUNK]=$COUNT
        done < <(wc -l "${PRESENT_INPUT_FILES[@]}" 2>/dev/null)

        # wc -l on all output files at once
        while IFS= read -r LINE; do
            COUNT=$(echo "$LINE" | awk '{print $1}')
            FILE=$(echo "$LINE" | awk '{print $2}')
            [ "$FILE" = "total" ] && continue
            CHUNK=$(basename "$FILE" .csv | grep -oP '\d+$')
            OUT_COUNTS[$CHUNK]=$COUNT
        done < <(wc -l "${PRESENT_OUTPUT_FILES[@]}" 2>/dev/null)

        for CHUNK_NUM in "${PRESENT_CHUNK_NUMS[@]}"; do
            IN_ROWS=$(( ${IN_COUNTS[$CHUNK_NUM]:-1} - 1 ))
            OUT_ROWS=$(( ${OUT_COUNTS[$CHUNK_NUM]:-0} - 1 ))
            if [ "$IN_ROWS" -ne "$OUT_ROWS" ]; then
                MISMATCH_CHUNKS+=("$CHUNK_NUM")
            else
                DONE=$(( DONE + 1 ))
            fi
        done
    fi

    # ── Empty row detection via awk (one pass per library across all output files) ─
    # Reads header from first file to find result column indices, then counts
    # rows where ALL result columns are empty across all output files.
    TOTAL_EMPTY=0
    EMPTY_CHUNK_SUMMARY=""

    if [ ${#PRESENT_OUTPUT_FILES[@]} -gt 0 ]; then
        # Build space-separated list of input col names for awk
        AWK_SKIP_COLS="$INPUT_COLS"

        EMPTY_RESULTS=$(awk -F',' \
            -v skip_cols="$AWK_SKIP_COLS" \
            '
            FNR == 1 {
                # Reset result column indices for each file
                delete result_idx
                n_result = 0
                split(skip_cols, skip_arr)
                for (i = 1; i <= NF; i++) {
                    col = tolower($i)
                    gsub(/^[ \t\r]+|[ \t\r]+$/, "", col)
                    is_skip = 0
                    for (j in skip_arr) {
                        if (skip_arr[j] == col) { is_skip = 1; break }
                    }
                    if (!is_skip) { result_idx[++n_result] = i }
                }
                # Extract chunk number from filename
                fname = FILENAME
                sub(/.*_results_/, "", fname)
                sub(/\.csv$/, "", fname)
                current_chunk = fname
                chunk_empty[current_chunk] = 0
                next
            }
            {
                if (n_result == 0) next
                all_empty = 1
                for (k = 1; k <= n_result; k++) {
                    val = $(result_idx[k])
                    gsub(/^[ \t\r]+|[ \t\r]+$/, "", val)
                    if (val != "") { all_empty = 0; break }
                }
                if (all_empty) chunk_empty[current_chunk]++
            }
            END {
                for (chunk in chunk_empty) {
                    if (chunk_empty[chunk] > 0)
                        print chunk, chunk_empty[chunk]
                }
            }
            ' "${PRESENT_OUTPUT_FILES[@]}" 2>/dev/null | sort)

        while IFS= read -r LINE; do
            [ -z "$LINE" ] && continue
            CHUNK=$(echo "$LINE" | awk '{print $1}')
            COUNT=$(echo "$LINE" | awk '{print $2}')
            TOTAL_EMPTY=$(( TOTAL_EMPTY + COUNT ))
            EMPTY_CHUNK_SUMMARY="${EMPTY_CHUNK_SUMMARY} ${CHUNK}(${COUNT})"
        done <<< "$EMPTY_RESULTS"
    fi

    printf "%-45s %7d %8d %11d %7s\n" \
        "$LIBRARY" "$TOTAL" "${#MISSING_CHUNKS[@]}" "$TOTAL_EMPTY" "${DONE}/${TOTAL}"

    if [ ${#MISSING_CHUNKS[@]} -gt 0 ]; then
        SHOWN=("${MISSING_CHUNKS[@]:0:20}")
        MSG=$(IFS=", "; echo "${SHOWN[*]}")
        [ ${#MISSING_CHUNKS[@]} -gt 20 ] && MSG="${MSG} ... (+$(( ${#MISSING_CHUNKS[@]} - 20 )) more)"
        echo "  MISSING chunks : $MSG"
    fi

    if [ ${#MISMATCH_CHUNKS[@]} -gt 0 ]; then
        SHOWN=("${MISMATCH_CHUNKS[@]:0:20}")
        MSG=$(IFS=", "; echo "${SHOWN[*]}")
        [ ${#MISMATCH_CHUNKS[@]} -gt 20 ] && MSG="${MSG} ... (+$(( ${#MISMATCH_CHUNKS[@]} - 20 )) more)"
        echo "  MISMATCH chunks: $MSG"
    fi

    if [ -n "$EMPTY_CHUNK_SUMMARY" ]; then
        echo "  EMPTY row chunks:$(echo "$EMPTY_CHUNK_SUMMARY" | tr ' ' '\n' | grep -v '^$' | head -10 | tr '\n' ' ')"
    fi

    unset IN_COUNTS OUT_COUNTS
done

printf "=%.0s" {1..75}; echo ""
echo ""
