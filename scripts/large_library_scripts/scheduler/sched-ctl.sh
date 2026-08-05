#!/bin/bash
# =============================================================================
# Wave scheduler — control CLI.
# =============================================================================
# Safely mutates a LIVE queue while run-model-queue.sh is running. The driver
# re-reads the queue file before every job, so edits made here take effect at the
# next job boundary (immediately, for pause/cancel).
#
# Line order in the queue file IS the priority — "prioritize" means "move up".
# Every read/write takes the same flock the driver uses, so nothing interleaves.
#
# Comment/blank lines are treated as belonging to the job line BELOW them, and
# move with it. Your annotations follow their job.
#
# Usage:
#   sched-ctl.sh [-q <queue_file>] [--log-dir <dir>] <command> [args]
#
# Queue editing (takes effect at the next job boundary):
#   add <model> <mode> [library] [wave] [queue] [--top|--after <n>]
#   rm       <sel>...            remove job(s)
#   top      <sel>...            move to the front of the queue
#   up       <sel>...            move one position earlier
#   down     <sel>...            move one position later
#   move     <sel> <pos>         move to an absolute 1-based position
#   hold     <sel>...            park a job (driver skips it)
#   unhold   <sel>...            un-park it
#   retry    <sel>...            forget a failed/cancelled verdict so it runs again
#
# Live control (takes effect within CTL_POLL seconds):
#   pause | resume               stop/start picking up new jobs
#   cancel <sel>                 scancel + kill the RUNNING model; hold a pending one
#   stop-after-current           finish the current model, then exit the driver
#   shutdown                     cancel the current model and exit the driver
#   refresh                      ask the driver to re-count S3 progress now
#
# Inspection:
#   list                         the queue with live statuses (no S3 calls)
#   status                       delegates to scheduler-status.sh (live S3 counts)
#   dump [--log <path>] [--live|--live-all]
#                                one machine-readable snapshot (used by the TUI).
#                                --live     recount totals + the running row from S3
#                                --live-all recount every row (slower; on demand)
#
# <sel> is a model id (eos12x7_v1) or a 1-based queue position (3).
#
# Env: LOG_DIR (default /shared/logs/scheduler), S3_BUCKET, QUEUE_FILE.
#      With a driver running, the queue file is discovered from driver.info.
# =============================================================================

set -uo pipefail

usage() { sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- global options ---------------------------------------------------------
CLI_QUEUE=""
CLI_LOG_DIR=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -q|--queue)   CLI_QUEUE="${2:-}"; shift 2 ;;
        --log-dir)    CLI_LOG_DIR="${2:-}"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            break ;;
    esac
done
[ "$#" -ge 1 ] || { usage; exit 1; }
CMD="$1"; shift

LOG_DIR="${CLI_LOG_DIR:-${LOG_DIR:-/shared/logs/scheduler}}"
S3_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/scheduler-lib.sh"
[ -f "$LIB" ] || LIB="/shared/scripts/large_library_scripts/scheduler/scheduler-lib.sh"
# shellcheck source=/dev/null
source "$LIB" || { echo "ERROR: cannot source scheduler-lib.sh ($LIB)"; exit 1; }

STATE_FILE="${STATE_FILE:-${LOG_DIR}/state.tsv}"
STATUS_FILE="${STATUS_FILE:-${LOG_DIR}/status.tsv}"

# ---- library-aliases (resolve_library) ----
# The driver resolves aliases BEFORE keying the status store, so `molport` in the
# queue is stored as Molport_Screening_Compounds_5.3M. We must resolve identically
# or every status lookup for an aliased entry silently misses and reads "pending".
for cand in /shared/scripts/library-aliases.sh \
            "${SCRIPT_DIR}/../../AWS_templates/library-aliases.sh" \
            /shared/scripts/AWS_templates/library-aliases.sh; do
    # shellcheck source=/dev/null
    [ -f "$cand" ] && { source "$cand"; break; }
done
if ! declare -F resolve_library >/dev/null; then
    resolve_library() { echo "$1"; }
fi

# The library a job is actually keyed under: explicit field, else the driver's
# default, then alias-resolved — exactly the driver's own order of operations.
effective_library() {  # $1 = raw library field from the queue line
    local lib="$1"
    [ -n "$lib" ] || lib="${DI_default_library:-}"
    [ -n "$lib" ] || { echo ""; return 0; }
    resolve_library "$lib"
}

# ---- resolve the queue file -------------------------------------------------
# Priority: -q flag > $QUEUE_FILE > driver.info (the live driver's own queue).
resolve_queue_file() {
    if [ -n "$CLI_QUEUE" ]; then QUEUE_FILE="$CLI_QUEUE"; return 0; fi
    if [ -n "${QUEUE_FILE:-}" ]; then return 0; fi
    if read_driver_info && [ -n "${DI_queue_file:-}" ]; then
        QUEUE_FILE="$DI_queue_file"
        return 0
    fi
    return 1
}

need_queue() {
    resolve_queue_file || {
        echo "ERROR: no queue file. Pass -q <file>, set QUEUE_FILE, or start a driver." >&2
        exit 1
    }
    [ -f "$QUEUE_FILE" ] || { echo "ERROR: queue file not found: $QUEUE_FILE" >&2; exit 1; }
}

# =============================================================================
# Block model — a job line plus the comment/blank lines directly above it
# =============================================================================
# Reordering must not scramble a hand-annotated file, so the file is modelled as:
#
#   BLK_HEADER    the file's banner: leading comments/blanks up to and INCLUDING
#                 the last blank line before the first job. Always stays on top.
#   BLK_PRE[i]    the comments directly above job i (after that last blank line).
#                 Moves with the job — your per-job notes follow their job.
#   BLK_TAIL      comments/blanks after the last job. Always stays at EOF.
BLK_PRE=(); BLK_MODEL=(); BLK_MODE=(); BLK_LIB=(); BLK_WAVE=(); BLK_QUEUE=(); BLK_FLAGS=()
BLK_HEADER=""
BLK_TAIL=""

# Split the leading pending text into (header, job-attached comment) at the last
# blank line: a banner is separated from the first job's note by a blank line,
# which is exactly how these files are written by hand.
_split_header() {  # $1 = pending text ; sets SPLIT_HEADER / SPLIT_PRE
    local text="$1" line header="" pre="" seen_blank_at=""
    local -a lines=()
    while IFS= read -r line; do lines+=("$line"); done <<< "$text"
    # drop the trailing empty element `<<<` adds when text ends in a newline
    [ "${#lines[@]}" -gt 0 ] && [ -z "${lines[-1]}" ] && unset 'lines[-1]'
    local i
    for i in "${!lines[@]}"; do
        [[ "${lines[i]}" =~ ^[[:space:]]*$ ]] && seen_blank_at="$i"
    done
    for i in "${!lines[@]}"; do
        if [ -n "$seen_blank_at" ] && [ "$i" -le "$seen_blank_at" ]; then
            header+="${lines[i]}"$'\n'
        else
            pre+="${lines[i]}"$'\n'
        fi
    done
    SPLIT_HEADER="$header"; SPLIT_PRE="$pre"
}

load_blocks() {
    BLK_PRE=(); BLK_MODEL=(); BLK_MODE=(); BLK_LIB=(); BLK_WAVE=(); BLK_QUEUE=(); BLK_FLAGS=()
    BLK_HEADER=""; BLK_TAIL=""
    local raw pending="" n first=1
    while IFS= read -r raw || [ -n "$raw" ]; do
        if parse_queue_line "$raw"; then
            n=${#BLK_MODEL[@]}
            if [ "$first" -eq 1 ]; then
                first=0
                if [ -n "$pending" ]; then
                    _split_header "$pending"
                    BLK_HEADER="$SPLIT_HEADER"
                    BLK_PRE[n]="$SPLIT_PRE"
                else
                    BLK_PRE[n]=""
                fi
            else
                BLK_PRE[n]="$pending"
            fi
            BLK_MODEL[n]="$QL_MODEL"; BLK_MODE[n]="$QL_MODE"; BLK_LIB[n]="$QL_LIB"
            BLK_WAVE[n]="$QL_WAVE";   BLK_QUEUE[n]="$QL_QUEUE"; BLK_FLAGS[n]="$QL_FLAGS"
            pending=""
        else
            pending+="${raw}"$'\n'
        fi
    done < "$QUEUE_FILE"
    if [ "$first" -eq 1 ]; then
        BLK_HEADER="$pending"       # a queue with no jobs at all is all header
    else
        BLK_TAIL="$pending"         # comments/blanks after the last job stay at EOF
    fi
}

write_blocks() {
    local tmp="${QUEUE_FILE}.tmp.$$" i
    {
        printf '%s' "$BLK_HEADER"
        for i in "${!BLK_MODEL[@]}"; do
            printf '%s' "${BLK_PRE[i]}"
            format_queue_line "${BLK_MODEL[i]}" "${BLK_MODE[i]}" "${BLK_LIB[i]}" \
                              "${BLK_WAVE[i]}" "${BLK_QUEUE[i]}" "${BLK_FLAGS[i]}"
        done
        printf '%s' "$BLK_TAIL"
    } > "$tmp" && mv -f "$tmp" "$QUEUE_FILE"
}

# Move the block at $1 to position $2 (both 0-based), preserving everything else.
move_block() {
    local from="$1" to="$2" n=${#BLK_MODEL[@]} i
    [ "$to" -lt 0 ] && to=0
    [ "$to" -ge "$n" ] && to=$((n - 1))
    [ "$from" -eq "$to" ] && return 0
    local p="${BLK_PRE[from]}" m="${BLK_MODEL[from]}" md="${BLK_MODE[from]}"
    local l="${BLK_LIB[from]}" w="${BLK_WAVE[from]}" q="${BLK_QUEUE[from]}" f="${BLK_FLAGS[from]}"
    local NP=() NM=() NMD=() NL=() NW=() NQ=() NF=()
    local j=0
    for ((i = 0; i < n; i++)); do
        [ "$i" -eq "$from" ] && continue
        NP[j]="${BLK_PRE[i]}"; NM[j]="${BLK_MODEL[i]}"; NMD[j]="${BLK_MODE[i]}"
        NL[j]="${BLK_LIB[i]}"; NW[j]="${BLK_WAVE[i]}";  NQ[j]="${BLK_QUEUE[i]}"
        NF[j]="${BLK_FLAGS[i]}"
        j=$((j + 1))
    done
    BLK_PRE=(); BLK_MODEL=(); BLK_MODE=(); BLK_LIB=(); BLK_WAVE=(); BLK_QUEUE=(); BLK_FLAGS=()
    j=0
    for ((i = 0; i < n; i++)); do
        if [ "$i" -eq "$to" ]; then
            BLK_PRE+=("$p"); BLK_MODEL+=("$m"); BLK_MODE+=("$md")
            BLK_LIB+=("$l"); BLK_WAVE+=("$w"); BLK_QUEUE+=("$q"); BLK_FLAGS+=("$f")
            continue
        fi
        BLK_PRE+=("${NP[j]}"); BLK_MODEL+=("${NM[j]}"); BLK_MODE+=("${NMD[j]}")
        BLK_LIB+=("${NL[j]}"); BLK_WAVE+=("${NW[j]}"); BLK_QUEUE+=("${NQ[j]}")
        BLK_FLAGS+=("${NF[j]}")
        j=$((j + 1))
    done
}

# Resolve a selector (model id or 1-based position) to 0-based block indices.
# Echoes one index per line; empty output means "no match".
resolve_sel() {  # $1 = selector
    local sel="$1" i found=0
    if [[ "$sel" =~ ^[0-9]+$ ]]; then
        i=$((sel - 1))
        if [ "$i" -ge 0 ] && [ "$i" -lt "${#BLK_MODEL[@]}" ]; then echo "$i"; return 0; fi
        return 1
    fi
    for i in "${!BLK_MODEL[@]}"; do
        if [ "${BLK_MODEL[i]}" = "$sel" ]; then echo "$i"; found=1; fi
    done
    [ "$found" -eq 1 ]
}

# Set or clear the `hold` flag on a block, leaving unknown flags untouched.
set_hold_flag() {  # $1 = index, $2 = 1|0
    local i="$1" want="$2" f out=""
    for f in ${BLK_FLAGS[i]}; do
        case "$f" in hold|hold=1|hold=true|hold=0|hold=false) continue ;; esac
        out="${out}${out:+ }${f}"
    done
    [ "$want" = "1" ] && out="${out}${out:+ }hold"
    BLK_FLAGS[i]="$out"
}

# =============================================================================
# Commands
# =============================================================================

cmd_add() {
    local model="" mode="" lib="" wave="" queue="" where="end" after=""
    local pos=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --top)   where="top"; shift ;;
            --after) where="after"; after="${2:-}"; shift 2 ;;
            *)       pos+=("$1"); shift ;;
        esac
    done
    model="${pos[0]:-}"; mode="${pos[1]:-}"; lib="${pos[2]:-}"
    wave="${pos[3]:-}";  queue="${pos[4]:-}"
    [ -n "$model" ] || { echo "ERROR: add needs <model> <mode> [library] [wave] [queue]" >&2; return 1; }
    [ -n "$mode" ]  || { echo "ERROR: add needs a mode (ersilia|singularity)" >&2; return 1; }
    case "$mode" in ersilia|singularity) ;; *)
        echo "ERROR: mode must be ersilia or singularity (got '$mode')" >&2; return 1 ;;
    esac
    if [ -n "$wave" ] && { ! [[ "$wave" =~ ^[0-9]+$ ]] || [ "$wave" -lt 1 ] || [ "$wave" -gt 1000 ]; }; then
        echo "ERROR: wave_size must be 1..1000 (got '$wave')" >&2; return 1
    fi

    _do() {
        load_blocks
        local i
        for i in "${!BLK_MODEL[@]}"; do
            if [ "${BLK_MODEL[i]}" = "$model" ] && [ "${BLK_MODE[i]}" = "$mode" ] \
               && [ "${BLK_LIB[i]}" = "$lib" ]; then
                echo "already queued at position $((i + 1)): $model $mode ${lib:-<default>}" >&2
                return 1
            fi
        done
        local n=${#BLK_MODEL[@]}
        BLK_PRE[n]=""; BLK_MODEL[n]="$model"; BLK_MODE[n]="$mode"; BLK_LIB[n]="$lib"
        BLK_WAVE[n]="$wave"; BLK_QUEUE[n]="$queue"; BLK_FLAGS[n]=""
        case "$where" in
            top)   move_block "$n" 0 ;;
            after) [[ "$after" =~ ^[0-9]+$ ]] && move_block "$n" "$after" ;;
        esac
        write_blocks
        echo "added: $model $mode ${lib:-<default library>} (${where})"
    }
    queue_locked _do
}

# Apply a per-block mutation to every selector given.
apply_sel() {  # $1 = mutator fn name, rest = selectors
    local fn="$1"; shift
    [ "$#" -ge 1 ] || { echo "ERROR: $CMD needs at least one <sel>" >&2; return 1; }
    local sels=("$@")
    _do() {
        load_blocks
        local sel idx rc=0
        # Resolve every selector to a MODEL first: indices shift as we mutate, but
        # a model id stays valid across the whole batch.
        local models=()
        for sel in "${sels[@]}"; do
            if ! idx="$(resolve_sel "$sel" | head -n 1)"; then
                echo "ERROR: no queue entry matches '$sel'" >&2; rc=1; continue
            fi
            models+=("${BLK_MODEL[idx]}")
        done
        for sel in "${models[@]}"; do
            idx="$(resolve_sel "$sel" | head -n 1)" || continue
            "$fn" "$idx" || rc=1
        done
        write_blocks
        return "$rc"
    }
    queue_locked _do
}

mut_rm() {
    local i="$1" n=${#BLK_MODEL[@]} j=0
    local NP=() NM=() NMD=() NL=() NW=() NQ=() NF=() k
    echo "removed: ${BLK_MODEL[i]} (was position $((i + 1)))"
    for ((k = 0; k < n; k++)); do
        [ "$k" -eq "$i" ] && continue
        NP[j]="${BLK_PRE[k]}"; NM[j]="${BLK_MODEL[k]}"; NMD[j]="${BLK_MODE[k]}"
        NL[j]="${BLK_LIB[k]}"; NW[j]="${BLK_WAVE[k]}";  NQ[j]="${BLK_QUEUE[k]}"
        NF[j]="${BLK_FLAGS[k]}"
        j=$((j + 1))
    done
    BLK_PRE=("${NP[@]+"${NP[@]}"}"); BLK_MODEL=("${NM[@]+"${NM[@]}"}")
    BLK_MODE=("${NMD[@]+"${NMD[@]}"}"); BLK_LIB=("${NL[@]+"${NL[@]}"}")
    BLK_WAVE=("${NW[@]+"${NW[@]}"}"); BLK_QUEUE=("${NQ[@]+"${NQ[@]}"}")
    BLK_FLAGS=("${NF[@]+"${NF[@]}"}")
}
mut_top()    { echo "moved ${BLK_MODEL[$1]} to position 1"; move_block "$1" 0; }
mut_up()     { local t=$(( $1 - 1 )); [ "$t" -lt 0 ] && t=0
               echo "moved ${BLK_MODEL[$1]} to position $((t + 1))"; move_block "$1" "$t"; }
mut_down()   { local t=$(( $1 + 1 ))
               echo "moved ${BLK_MODEL[$1]} to position $((t + 1))"; move_block "$1" "$t"; }
mut_hold()   { set_hold_flag "$1" 1; echo "held: ${BLK_MODEL[$1]}"; }
mut_unhold() { set_hold_flag "$1" 0; echo "unheld: ${BLK_MODEL[$1]}"; }

cmd_move() {
    local sel="${1:-}" pos="${2:-}"
    [ -n "$sel" ] && [ -n "$pos" ] || { echo "ERROR: move <sel> <pos>" >&2; return 1; }
    [[ "$pos" =~ ^[0-9]+$ ]] || { echo "ERROR: <pos> must be a 1-based number" >&2; return 1; }
    _do() {
        load_blocks
        local idx
        idx="$(resolve_sel "$sel" | head -n 1)" || {
            echo "ERROR: no queue entry matches '$sel'" >&2; return 1; }
        move_block "$idx" "$((pos - 1))"
        write_blocks
        echo "moved ${sel} to position ${pos}"
    }
    queue_locked _do
}

cmd_retry() {
    [ "$#" -ge 1 ] || { echo "ERROR: retry needs at least one <sel>" >&2; return 1; }
    load_blocks
    local sel idx key rc=0
    for sel in "$@"; do
        idx="$(resolve_sel "$sel" | head -n 1)" || {
            echo "ERROR: no queue entry matches '$sel'" >&2; rc=1; continue; }
        # Reproduce the driver's key exactly: default applied, then alias-resolved.
        key="$(job_key "${BLK_MODEL[idx]}" "${BLK_MODE[idx]}" \
                       "$(effective_library "${BLK_LIB[idx]}")")"
        status_forget "$key"
        set_hold_flag "$idx" 0
        echo "retry: ${BLK_MODEL[idx]} (verdict cleared, unheld)"
    done
    _w() { write_blocks; }
    queue_locked _w
    return "$rc"
}

# Status of a model according to the render view (no S3 calls).
state_status_of() {  # $1 = model
    [ -f "$STATE_FILE" ] || return 1
    local idx model mode lib status rest
    while IFS=$'\t' read -r idx model mode lib status rest; do
        case "$idx" in ''|'#'*) continue ;; esac
        [ "$model" = "$1" ] && { echo "$status"; return 0; }
    done < "$STATE_FILE"
    return 1
}

cmd_cancel() {
    local sel="${1:-}"
    [ -n "$sel" ] || { echo "ERROR: cancel <sel>" >&2; return 1; }
    load_blocks
    local idx model st
    idx="$(resolve_sel "$sel" | head -n 1)" || {
        echo "ERROR: no queue entry matches '$sel'" >&2; return 1; }
    model="${BLK_MODEL[idx]}"
    st="$(state_status_of "$model" || echo unknown)"
    if [ "$st" = "running" ]; then
        control_post cancel "$model"
        echo "cancel requested for RUNNING model ${model} — the driver will scancel its"
        echo "in-flight SLURM array and move on (within ${CTL_POLL:-15}s)."
    else
        _do() { load_blocks; local i; i="$(resolve_sel "$model" | head -n 1)" || return 1
                set_hold_flag "$i" 1; write_blocks; }
        queue_locked _do
        echo "${model} is not running (status: ${st}) — held instead, so it will not start."
        echo "Use 'rm ${model}' to drop it from the queue entirely."
    fi
}

cmd_pause()  { mkdir -p "$(control_dir)"; : > "$(paused_flag)"; echo "paused — the driver will not start new jobs"; }
cmd_resume() { rm -f "$(paused_flag)"; echo "resumed"; }
cmd_stop_after() {
    mkdir -p "$(control_dir)"; : > "$(stopafter_flag)"
    echo "stop-after-current armed — the driver exits when the current model finishes"
}
cmd_shutdown() { control_post shutdown ""; echo "shutdown requested — current model will be cancelled"; }
cmd_refresh()  { control_post refresh "";  echo "S3 recount requested"; }

cmd_list() {
    load_blocks
    status_load
    printf '%-4s %-19s %-12s %-34s %-13s %14s  %s\n' \
        "#" "model" "mode" "library" "status" "done/total" "flags"
    printf -- "-%.0s" {1..108}; echo ""
    local i lib key st dn tt
    for i in "${!BLK_MODEL[@]}"; do
        lib="$(effective_library "${BLK_LIB[i]}")"
        key="$(job_key "${BLK_MODEL[i]}" "${BLK_MODE[i]}" "$lib")"
        st="${ST_STATUS[$key]:-pending}"
        dn="${ST_DONE[$key]:-0}"; tt="${ST_TOTAL[$key]:-0}"
        case " ${BLK_FLAGS[i]} " in *" hold "*) st="held" ;; esac
        printf '%-4s %-19s %-12s %-34s %-13s %6s/%-7s %s\n' \
            "$((i + 1))" "${BLK_MODEL[i]}" "${BLK_MODE[i]}" "${lib:-<no default>}" \
            "$st" "$dn" "$tt" "${BLK_FLAGS[i]}"
    done
    printf -- '-%.0s' {1..100}; echo ""
    if driver_alive; then
        if [ -f "$(paused_flag)" ]; then echo "  driver: PAUSED (pid ${DI_pid})"
        else echo "  driver: running (pid ${DI_pid})"; fi
    else
        echo "  driver: not running"
    fi
    echo "  queue : $QUEUE_FILE"
}

cmd_status() {
    local s="${SCRIPT_DIR}/scheduler-status.sh"
    [ -x "$s" ] || s="/shared/scripts/large_library_scripts/scheduler/scheduler-status.sh"
    S3_BUCKET="$S3_BUCKET" LOG_DIR="$LOG_DIR" "$s" "$STATE_FILE"
}

# Recount progress from S3, the same way scheduler-status.sh does.
#
# Cost control matters here: an `aws s3 ls` over a 13,644-object prefix takes about
# a second, so the two halves are counted differently.
#   * TOTALS are per LIBRARY, not per job — one listing serves every row sharing a
#     library, so they are always counted (usually 1-2 calls for a whole queue).
#   * DONE counts are per model, so by default only the RUNNING row is recounted
#     (one call); `--all` recounts every row, for an explicit user-requested refresh.
# An empty done field means "not recounted — keep whatever was recorded".
emit_counts() {  # $1 = scope: running | all
    local scope="$1"
    load_blocks
    status_load
    declare -A INPUT_CACHE=()
    local i lib key st dn tt
    for i in "${!BLK_MODEL[@]}"; do
        lib="$(effective_library "${BLK_LIB[i]}")"
        [ -n "$lib" ] || continue
        key="$(job_key "${BLK_MODEL[i]}" "${BLK_MODE[i]}" "$lib")"
        if [ -z "${INPUT_CACHE[$lib]+x}" ]; then
            INPUT_CACHE[$lib]="$(s3_count_input "$lib")"
        fi
        tt="${INPUT_CACHE[$lib]}"
        st="${ST_STATUS[$key]:-}"
        # No status store means a pre-upgrade driver: fall back to its state.tsv so
        # we still know which row is the running one.
        [ -n "$st" ] || st="$(state_status_of "${BLK_MODEL[i]}" 2>/dev/null || echo pending)"
        dn=""
        if [ "$scope" = "all" ] || [ "$st" = "running" ]; then
            dn="$(s3_count_output "${BLK_MODEL[i]}" "$lib" "${BLK_MODE[i]}")"
        fi
        printf '%s\t%s\t%s\n' "$key" "$dn" "$tt"
    done
}

# One machine-readable snapshot. The TUI's only read primitive: a single call
# (and over SSH, a single round-trip) returns everything it needs to render.
cmd_dump() {
    local logpath="" live=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --log)      logpath="${2:-}"; shift 2 ;;
            --live)     live="running"; shift ;;
            --live-all) live="all"; shift ;;
            *)          shift ;;
        esac
    done
    local alive=0 paused=0 stopafter=0 legacy=0 legacy_pid=""
    driver_alive && alive=1
    if driver_is_legacy; then legacy=1; legacy_pid="$(driver_pid_scan)"; fi
    [ -f "$(paused_flag)" ] && paused=1
    [ -f "$(stopafter_flag)" ] && stopafter=1

    echo "---8<--- runtime"
    echo "schema=1"
    echo "driver_alive=${alive}"
    echo "driver_legacy=${legacy}"
    echo "legacy_pid=${legacy_pid}"
    echo "paused=${paused}"
    echo "stop_after_current=${stopafter}"
    echo "log_dir=${LOG_DIR}"
    echo "queue_file=${QUEUE_FILE:-}"
    echo "state_file=${STATE_FILE}"
    echo "status_file=${STATUS_FILE}"
    echo "s3_bucket=${S3_BUCKET}"
    echo "now=$(now_iso)"

    echo "---8<--- driver.info"
    [ -f "$(driver_info)" ] && cat "$(driver_info)"

    echo "---8<--- queue"
    [ -n "${QUEUE_FILE:-}" ] && [ -f "$QUEUE_FILE" ] && cat "$QUEUE_FILE"

    # The authoritative parsed view: queue order with libraries already resolved
    # the way the driver resolves them. Clients read THIS rather than re-parsing
    # the raw queue above, so alias handling has exactly one implementation.
    echo "---8<--- jobs"
    if [ -n "${QUEUE_FILE:-}" ] && [ -f "$QUEUE_FILE" ]; then
        printf '#pos\tmodel\tmode\tlibrary\twave\tqueue\tflags\tlib_is_default\n'
        load_blocks
        local i lib
        for i in "${!BLK_MODEL[@]}"; do
            lib="$(effective_library "${BLK_LIB[i]}")"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$((i + 1))" "${BLK_MODEL[i]}" "${BLK_MODE[i]}" "$lib" \
                "${BLK_WAVE[i]}" "${BLK_QUEUE[i]}" "${BLK_FLAGS[i]}" \
                "$([ -z "${BLK_LIB[i]}" ] && echo 1 || echo 0)"
        done
    fi

    echo "---8<--- state.tsv"
    [ -f "$STATE_FILE" ] && cat "$STATE_FILE"

    echo "---8<--- status.tsv"
    [ -f "$STATUS_FILE" ] && cat "$STATUS_FILE"

    echo "---8<--- libraries"
    # Canonical library names for the add-dialog's dropdown. Two sources, unioned:
    # the alias table's canonical names (the `echo "Name"` arms of resolve_library),
    # and any library already referenced by this queue or status store — which is how
    # newer libraries not yet in the alias table (e.g. the 1.4B) still show up.
    {
        for cand in /shared/scripts/library-aliases.sh \
                    "${SCRIPT_DIR}/../../AWS_templates/library-aliases.sh" \
                    /shared/scripts/AWS_templates/library-aliases.sh; do
            [ -f "$cand" ] || continue
            grep -oP 'echo\s+"\K[A-Za-z][A-Za-z0-9_.]*(?=")' "$cand" 2>/dev/null
            break
        done
        [ -f "$STATE_FILE" ] && awk -F'\t' '$1 !~ /^#/ && $4 != "" {print $4}' "$STATE_FILE"
        [ -f "$STATUS_FILE" ] && awk -F'\t' '$1 !~ /^#/ {n=split($1,a,"|"); if (n==3) print a[3]}' "$STATUS_FILE"
    } 2>/dev/null | grep -vx 'NA' | sort -u

    echo "---8<--- counts ${live}"
    if [ -n "$live" ] && [ -n "${QUEUE_FILE:-}" ] && [ -f "$QUEUE_FILE" ]; then
        emit_counts "$live"
    fi

    echo "---8<--- log ${logpath}"
    [ -n "$logpath" ] && [ -f "$logpath" ] && tail -n "${DUMP_LOG_LINES:-300}" "$logpath"

    echo "---8<--- end"
}

# =============================================================================
# Dispatch
# =============================================================================
case "$CMD" in
    add)                need_queue; cmd_add "$@" ;;
    rm|remove)          need_queue; apply_sel mut_rm "$@" ;;
    top)                need_queue; apply_sel mut_top "$@" ;;
    up)                 need_queue; apply_sel mut_up "$@" ;;
    down)               need_queue; apply_sel mut_down "$@" ;;
    hold)               need_queue; apply_sel mut_hold "$@" ;;
    unhold)             need_queue; apply_sel mut_unhold "$@" ;;
    move)               need_queue; cmd_move "$@" ;;
    retry)              need_queue; read_driver_info >/dev/null 2>&1; cmd_retry "$@" ;;
    cancel)             need_queue; cmd_cancel "$@" ;;
    pause)              cmd_pause ;;
    resume)             cmd_resume ;;
    stop-after-current) cmd_stop_after ;;
    shutdown)           cmd_shutdown ;;
    refresh)            cmd_refresh ;;
    list|ls)            need_queue; read_driver_info >/dev/null 2>&1; cmd_list ;;
    status)             cmd_status ;;
    dump)               resolve_queue_file >/dev/null 2>&1 || true; cmd_dump "$@" ;;
    queue-file)         need_queue; echo "$QUEUE_FILE" ;;
    -h|--help|help)     usage ;;
    *)                  echo "ERROR: unknown command '$CMD'" >&2; echo ""; usage; exit 1 ;;
esac
