#!/bin/bash
# Fast HYBRID variant of check-results.sh for models with MANY output columns
# (e.g. descriptor models with up to ~3200 columns).
#
# Strategy (hybrid = sample, then verify):
#   1. Missing chunks  -> pure file-presence check (no content read).
#   2. Sample every present output file: read only the first & last few DATA
#      rows (head/tail, so cost is independent of file size AND column count)
#      and check the first result column. A chunk is "suspect" if any sampled
#      value is blank, or if the file has no data rows (NODATA).
#   3. Verify suspects only: run the exact full-row empty-count scan (parallel
#      awk, whole-line $0 regex so it doesn't slow down with column count) on
#      just the suspect files.
#
# Chunks whose sampled rows are all populated are assumed clean (0 empty). This
# is fast when failures are rare; it can MISS empty rows that occur only in the
# interior of an otherwise-populated chunk. It does NOT check input/output row
# count mismatches.
#
# Tunables (env): CHECK_JOBS   parallelism (default: nproc)
#                 CHECK_SAMPLE rows sampled from head and from tail (default: 5)
#
# Usage: check-results-fast.sh <model_id>
# Example: check-results-fast.sh eos4k4f_v1

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
JOBS=${CHECK_JOBS:-$(nproc 2>/dev/null || echo 4)}
SAMPLE=${CHECK_SAMPLE:-5}
export SAMPLE   # used by the sampling workers spawned via xargs

echo ""
echo "Model: ${MODEL_ID}  (hybrid: sample ${SAMPLE}+${SAMPLE} rows, verify suspects; x${JOBS})"
printf "=%.0s" {1..91}; echo ""
printf "%-45s %7s %8s %8s %11s %7s\n" "Library" "Chunks" "Missing" "Suspect" "Empty rows" "Done"
printf -- "-%.0s" {1..91}; echo ""

for LIBRARY in "${LIBRARIES[@]}"; do
    INPUT_DIR="/fsx/input/${LIBRARY}"
    OUTPUT_DIR="/fsx/output/${LIBRARY}/${MODEL_ID}"

    if [ ! -d "$INPUT_DIR" ] || [ ! -d "$OUTPUT_DIR" ]; then
        printf "%-45s %7s %8s %8s %11s %7s\n" "$LIBRARY" "—" "—" "—" "—" "NOT RUN"
        continue
    fi

    mapfile -t INPUT_CHUNKS < <(ls "${INPUT_DIR}"/*_chunk_*.csv 2>/dev/null | sort)
    TOTAL=${#INPUT_CHUNKS[@]}

    if [ "$TOTAL" -eq 0 ]; then
        printf "%-45s %7s %8s %8s %11s %7s\n" "$LIBRARY" "—" "—" "—" "—" "NO INPUT"
        continue
    fi

    # ── Missing chunks: pure file-presence check (no content read) ────────────
    MISSING_CHUNKS=()
    PRESENT_OUTPUT_FILES=()
    for INPUT_FILE in "${INPUT_CHUNKS[@]}"; do
        CHUNK_NUM=$(basename "$INPUT_FILE" .csv | grep -oP '\d+$')
        OUTPUT_FILE="${OUTPUT_DIR}/${MODEL_ID}_results_${CHUNK_NUM}.csv"
        if [ ! -f "$OUTPUT_FILE" ]; then
            MISSING_CHUNKS+=("$CHUNK_NUM")
        else
            PRESENT_OUTPUT_FILES+=("$OUTPUT_FILE")
        fi
    done
    DONE=${#PRESENT_OUTPUT_FILES[@]}

    N_SUSPECT=0
    TOTAL_EMPTY=0
    EMPTY_CHUNK_SUMMARY=""
    NODATA_SUMMARY=""

    if [ "$DONE" -gt 0 ]; then
        # ── First result column index R (from one header; schema is shared) ──
        R=$(head -n1 "${PRESENT_OUTPUT_FILES[0]}" | awk -F',' -v skip="$INPUT_COLS" '
            {
                split(skip, a, " ")
                for (j in a) s[tolower(a[j])] = 1
                for (i = 1; i <= NF; i++) {
                    c = tolower($i); gsub(/^[ \t\r]+|[ \t\r]+$/, "", c)
                    if (!(c in s)) { print i; exit }
                }
            }')
        [ -z "$R" ] && R=2   # fallback: assume results start after "key"
        export R

        # ── PHASE 1 (sampling): flag suspect chunks, cheap head/tail reads ────
        # Each worker samples the first & last $SAMPLE data rows of each file
        # and checks column R. Emits "NODATA <chunk>" (no data rows) or
        # "SUSPECT <chunk>" (a sampled result value is blank).
        SUSPECT_CHUNKS=$(printf '%s\n' "${PRESENT_OUTPUT_FILES[@]}" \
            | xargs -d '\n' -P "$JOBS" -n 200 bash -c '
                for f in "$@"; do
                    b=${f##*/}; chunk=${b##*_results_}; chunk=${chunk%.csv}
                    top=$(head -n $((SAMPLE + 1)) "$f" | tail -n +2)
                    if [ -z "$top" ]; then echo "NODATA $chunk"; continue; fi
                    if { printf "%s\n" "$top"; tail -n "$SAMPLE" "$f"; } \
                         | cut -d, -f"$R" \
                         | grep -qE "^[[:space:]]*$"; then
                        echo "SUSPECT $chunk"
                    fi
                done
            ' _)

        # Split into NODATA (reported as-is) and blank-sampled (need rescan)
        SUSPECT_FILES=()
        while IFS=' ' read -r TAG CH; do
            [ -z "$CH" ] && continue
            N_SUSPECT=$(( N_SUSPECT + 1 ))
            if [ "$TAG" = "NODATA" ]; then
                NODATA_SUMMARY="${NODATA_SUMMARY} ${CH}"
            else
                SUSPECT_FILES+=("${OUTPUT_DIR}/${MODEL_ID}_results_${CH}.csv")
            fi
        done <<< "$SUSPECT_CHUNKS"

        # ── PHASE 2 (verify): exact empty-row count on suspect files only ─────
        if [ ${#SUSPECT_FILES[@]} -gt 0 ]; then
            BATCH=$(( (${#SUSPECT_FILES[@]} + JOBS - 1) / JOBS ))
            [ "$BATCH" -lt 1 ] && BATCH=1
            EMPTY_RESULTS=$(printf '%s\n' "${SUSPECT_FILES[@]}" \
                | xargs -d '\n' -P "$JOBS" -n "$BATCH" \
                    awk -F',' -v skip_cols="$INPUT_COLS" '
                FNR == 1 {
                    # Locate first result column and build the "empty col R" regex
                    delete skipset
                    split(skip_cols, skip_arr, " ")
                    for (j in skip_arr) skipset[tolower(skip_arr[j])] = 1
                    R = 0
                    for (i = 1; i <= NF; i++) {
                        col = tolower($i); gsub(/^[ \t\r]+|[ \t\r]+$/, "", col)
                        if (!(col in skipset)) { R = i; break }
                    }
                    re = "^"
                    for (i = 0; i < R - 1; i++) re = re "[^,]*,"
                    re = re "(,|$)"
                    fname = FILENAME
                    sub(/.*_results_/, "", fname); sub(/\.csv$/, "", fname)
                    chunk = fname
                    total[chunk] = 0; empty[chunk] = 0
                    next
                }
                { total[chunk]++; if (R > 0 && $0 ~ re) empty[chunk]++ }
                END { for (c in total) print c, empty[c], total[c] }
                ' 2>/dev/null | sort)

            while IFS=' ' read -r CH EM TOTROWS; do
                [ -z "$CH" ] && continue
                if [ "${EM:-0}" -gt 0 ]; then
                    TOTAL_EMPTY=$(( TOTAL_EMPTY + EM ))
                    EMPTY_CHUNK_SUMMARY="${EMPTY_CHUNK_SUMMARY} ${CH}(${EM})"
                elif [ "${TOTROWS:-0}" -eq 0 ]; then
                    NODATA_SUMMARY="${NODATA_SUMMARY} ${CH}"
                fi
            done <<< "$EMPTY_RESULTS"
        fi
    fi

    printf "%-45s %7d %8d %8d %11d %7s\n" \
        "$LIBRARY" "$TOTAL" "${#MISSING_CHUNKS[@]}" "$N_SUSPECT" "$TOTAL_EMPTY" "${DONE}/${TOTAL}"

    if [ ${#MISSING_CHUNKS[@]} -gt 0 ]; then
        SHOWN=("${MISSING_CHUNKS[@]:0:20}")
        MSG=$(IFS=", "; echo "${SHOWN[*]}")
        [ ${#MISSING_CHUNKS[@]} -gt 20 ] && MSG="${MSG} ... (+$(( ${#MISSING_CHUNKS[@]} - 20 )) more)"
        echo "  MISSING chunks : $MSG"
    fi
    if [ -n "$EMPTY_CHUNK_SUMMARY" ]; then
        echo "  EMPTY row chunks:$(echo "$EMPTY_CHUNK_SUMMARY" | tr ' ' '\n' | grep -v '^$' | head -10 | tr '\n' ' ')"
    fi
    if [ -n "$NODATA_SUMMARY" ]; then
        echo "  NO-DATA chunks :$(echo "$NODATA_SUMMARY" | tr ' ' '\n' | grep -v '^$' | head -10 | tr '\n' ' ')"
    fi
done

printf "=%.0s" {1..91}; echo ""
echo ""
