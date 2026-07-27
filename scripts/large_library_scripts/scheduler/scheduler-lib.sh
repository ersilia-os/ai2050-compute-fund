#!/bin/bash
# =============================================================================
# Shared helpers for the wave scheduler.
# =============================================================================
# SOURCED (not executed) by run-model-queue.sh (driver) and scheduler-status.sh
# (renderer). Keeping the per-mode S3-counting logic here means the driver and the
# renderer can never drift on how "done" is measured.
#
# The caller must have S3_BUCKET set before calling the s3_* helpers.
# write_state() additionally operates on the driver's Q_* arrays + STATE_FILE.
# =============================================================================

# ISO-8601 UTC timestamp, e.g. 2026-07-23T09:01:22Z
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Count a library's input chunks in S3:  <lib>_chunk_<NNN>.csv
# Digit-count agnostic (3-digit small libs and 6-digit 1.4B both match).
s3_count_input() {  # $1 = library
    aws s3 ls "s3://${S3_BUCKET}/input/${1}/" 2>/dev/null \
        | grep -cP '_chunk_[0-9]+\.csv$' || true
}

# Count a model's result files in S3, per run mode.
#   ersilia     -> <model>_results_<NNN>.csv
#   singularity -> <model>_<NNN>.csv         (NO _results_)
# The two patterns never cross-count: after "<model>_", ersilia has the letters
# "results", not a digit, so the singularity regex can't match an ersilia file.
s3_count_output() {  # $1 = model  $2 = library  $3 = mode
    local pat
    case "$3" in
        ersilia)     pat="${1}_results_[0-9]+\.csv$" ;;
        singularity) pat="${1}_[0-9]+\.csv$" ;;
        *)           echo 0; return 0 ;;
    esac
    aws s3 ls "s3://${S3_BUCKET}/output/${2}/${1}/" 2>/dev/null \
        | grep -cP "$pat" || true
}

# Map a run mode to its wave-orchestrator script basename.
mode_script() {  # $1 = mode
    case "$1" in
        ersilia)     echo "submit-ersilia-waves.sh" ;;
        singularity) echo "submit-singularity-waves.sh" ;;
        *)           return 1 ;;
    esac
}

# Atomically (re)write the whole state TSV from the driver's Q_* arrays.
# Temp file in the SAME dir + mv -f == atomic rename, so the renderer never
# reads a half-written table.
# Globals: STATE_FILE, Q_MODEL Q_MODE Q_LIB Q_STATUS Q_DONE Q_TOTAL Q_START Q_FIN Q_LOG
write_state() {
    local tmp="${STATE_FILE}.tmp.$$" i
    {
        printf '#idx\tmodel\tmode\tlibrary\tstatus\tdone\ttotal\tstarted\tfinished\tlog\n'
        for i in "${!Q_MODEL[@]}"; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$((i + 1))" "${Q_MODEL[i]}" "${Q_MODE[i]}" "${Q_LIB[i]}" \
                "${Q_STATUS[i]}" "${Q_DONE[i]}" "${Q_TOTAL[i]}" \
                "${Q_START[i]}" "${Q_FIN[i]}" "${Q_LOG[i]}"
        done
    } > "$tmp" && mv -f "$tmp" "$STATE_FILE"
}
