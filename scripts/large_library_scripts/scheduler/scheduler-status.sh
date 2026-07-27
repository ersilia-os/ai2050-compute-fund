#!/bin/bash
# =============================================================================
# Wave scheduler — status renderer.
# =============================================================================
# Reads the driver's state TSV and prints a table. For rows that ran (or are
# running), it recomputes done/total LIVE from S3, so a currently-running model
# shows live progress even though the driver only rewrites the state file on
# transitions. Read-only and safe to run anytime, including under:
#   watch -n 30 scheduler-status.sh
#
# Usage: scheduler-status.sh [state_file]
# Env:   S3_BUCKET (default ai2050-ersilia-cluster), LOG_DIR / STATE_FILE for the default path.
# =============================================================================

set -uo pipefail

S3_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"
LOG_DIR="${LOG_DIR:-/shared/logs/scheduler}"
STATE_FILE="${1:-${STATE_FILE:-${LOG_DIR}/state.tsv}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/scheduler-lib.sh"
[ -f "$LIB" ] || LIB="/shared/scripts/large_library_scripts/scheduler/scheduler-lib.sh"
# shellcheck source=/dev/null
source "$LIB" 2>/dev/null || { echo "ERROR: cannot source scheduler-lib.sh ($LIB)"; exit 1; }

if [ ! -f "$STATE_FILE" ]; then
    echo "No scheduler state found at: $STATE_FILE"
    exit 0
fi

echo ""
echo "Wave scheduler status   $(now_iso)"
echo "state: $STATE_FILE"
printf "=%.0s" {1..104}; echo ""
printf "%-4s %-16s %-11s %-30s %-13s %13s %5s  %s\n" \
    "#" "model" "mode" "library" "status" "done/total" "pct" "started(UTC)"
printf -- "-%.0s" {1..104}; echo ""

declare -A COUNT=()
while IFS=$'\t' read -r idx model mode lib status s_done s_total started fin log; do
    case "$idx" in ''|'#'*) continue ;; esac        # skip header / blanks
    dcount="$s_done"; tcount="$s_total"
    # live-recompute only where progress is meaningful (skip missing-files/skipped)
    case "$status" in
        pending|running|done|failed)
            tcount="$(s3_count_input "$lib")"
            dcount="$(s3_count_output "$model" "$lib" "$mode")"
            ;;
    esac
    if [ "${tcount:-0}" -gt 0 ] 2>/dev/null; then pct=$(( dcount * 100 / tcount )); else pct=0; fi
    printf "%-4s %-16s %-11s %-30s %-13s %6s/%-6s %4s%%  %s\n" \
        "$idx" "$model" "$mode" "$lib" "$status" "$dcount" "$tcount" "$pct" "$started"
    COUNT[$status]=$(( ${COUNT[$status]:-0} + 1 ))
done < "$STATE_FILE"

printf -- "-%.0s" {1..104}; echo ""
line=""
for s in done running pending failed missing-files skipped; do
    [ -n "${COUNT[$s]:-}" ] && line+="${s}=${COUNT[$s]}  "
done
echo "  ${line:-(no jobs)}"
printf "=%.0s" {1..104}; echo ""
echo ""
