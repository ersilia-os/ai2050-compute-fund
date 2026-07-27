#!/bin/bash
# =============================================================================
# Wave scheduler — sequential multi-model driver.
# =============================================================================
# Reads a queue of models and runs each one's wave orchestrator back-to-back so
# the cluster stays busy with minimal idle time. For each queue line it dispatches
# submit-ersilia-waves.sh or submit-singularity-waves.sh (both BLOCK until the
# model's whole library is processed), captures the exit code, and maintains an
# atomic status file that scheduler-status.sh renders.
#
# Runs on the HEAD NODE inside tmux (a full queue can take days):
#   tmux new -s scheduler
#   S3_BUCKET=ai2050-ersilia-cluster ./run-model-queue.sh models.queue Enamine_Real_Sample_1.4B
# ...or launch it detached with start-scheduler-tmux.sh.
#
# Usage:
#   run-model-queue.sh <queue_file> [default_library] [default_wave_size] [default_queue] [--dry-run]
#
# Queue file: one job per line; blank lines and '#' comments (incl. indented) ignored;
# whitespace-separated:
#   <model_id> <mode> [library] [wave_size] [queue]      mode = ersilia | singularity
#   * library optional  -> default_library (alias-resolved; e.g. real -> Enamine_Real_Sample_10.4M)
#   * wave_size optional -> default_wave_size (1..1000)
#   * queue optional     -> default_queue
#
# Env:
#   S3_BUCKET        (default ai2050-ersilia-cluster)   passed through to the orchestrators
#   POLL_SECONDS     (default 30)                        passed through to the orchestrators
#   ON_FAIL          continue | halt   (default continue)
#   AUTO_FETCH_SIF   0 | 1             (default 0 — do NOT download; missing SIF => missing-files)
#   LOG_DIR          (default /shared/logs/scheduler)
#   STATE_FILE       (default $LOG_DIR/state.tsv)
#   SCHED_FAKE_RC    (dry-run only) space-separated fake exit codes by queue index, for testing
# =============================================================================

set -uo pipefail

usage() {
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
}

# ---- args: separate --dry-run flag from positionals ----
DRY_RUN=0
POS=()
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *)         POS+=("$a") ;;
    esac
done
QUEUE_FILE="${POS[0]:-}"
DEFAULT_LIBRARY="${POS[1]:-}"
DEFAULT_WAVE_SIZE="${POS[2]:-1000}"
DEFAULT_QUEUE="${POS[3]:-cpu-queue}"

# ---- env / config ----
S3_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"
POLL_SECONDS="${POLL_SECONDS:-30}"
ON_FAIL="${ON_FAIL:-continue}"
AUTO_FETCH_SIF="${AUTO_FETCH_SIF:-0}"
LOG_DIR="${LOG_DIR:-/shared/logs/scheduler}"
STATE_FILE="${STATE_FILE:-${LOG_DIR}/state.tsv}"
declare -a FAKE_RC=(${SCHED_FAKE_RC:-})   # dry-run test hook (empty in normal use)

if [ -z "$QUEUE_FILE" ]; then usage; exit 1; fi
[ -f "$QUEUE_FILE" ] || { echo "ERROR: queue file not found: $QUEUE_FILE"; exit 1; }

# ---- locate + source the shared lib ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/scheduler-lib.sh"
[ -f "$LIB" ] || LIB="/shared/scripts/large_library_scripts/scheduler/scheduler-lib.sh"
# shellcheck source=/dev/null
source "$LIB" || { echo "ERROR: cannot source scheduler-lib.sh ($LIB)"; exit 1; }

# ---- library-aliases (resolve_library); passthrough if not deployed ----
for cand in /shared/scripts/library-aliases.sh \
            "${SCRIPT_DIR}/../../AWS_templates/library-aliases.sh" \
            /shared/scripts/AWS_templates/library-aliases.sh; do
    # shellcheck source=/dev/null
    [ -f "$cand" ] && { source "$cand"; break; }
done
if ! declare -F resolve_library >/dev/null; then
    resolve_library() { echo "$1"; }   # no alias table -> pass names through unchanged
fi

# ---- locate the wave orchestrators (one dir up; /shared fallback) ----
WAVES_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
[ -f "${WAVES_DIR}/submit-ersilia-waves.sh" ] || WAVES_DIR="/shared/scripts/large_library_scripts"

mkdir -p "$LOG_DIR"

# ---- single-driver lock (atomic mkdir) ----
LOCK="${LOG_DIR}/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "ERROR: another driver holds the lock: $LOCK"
    echo "       If no scheduler is running, remove it:  rmdir $LOCK"
    exit 1
fi
cleanup() { rmdir "$LOCK" 2>/dev/null; rm -f "${STATE_FILE}.tmp.$$" 2>/dev/null; }
trap cleanup EXIT

# ---- state arrays (index-aligned) ----
Q_MODEL=(); Q_MODE=(); Q_LIB=(); Q_WAVE=(); Q_QUEUE=()
Q_STATUS=(); Q_DONE=(); Q_TOTAL=(); Q_START=(); Q_FIN=(); Q_LOG=(); Q_NOTE=()

log_line() { echo "[$(now_iso)] $*"; }
set_status() { Q_STATUS[$1]="$2"; write_state; }   # $1=index $2=status

add_job() {  # model mode library wave queue status note
    local i=${#Q_MODEL[@]}
    Q_MODEL[i]="$1"; Q_MODE[i]="$2"; Q_LIB[i]="$3"; Q_WAVE[i]="$4"; Q_QUEUE[i]="$5"
    Q_STATUS[i]="$6"; Q_NOTE[i]="$7"
    Q_DONE[i]=0; Q_TOTAL[i]=0; Q_START[i]="-"; Q_FIN[i]="-"
    Q_LOG[i]="${LOG_DIR}/$((i + 1))_${1}_${3:-NA}.log"
}

parse_queue() {
    local raw trimmed f_model f_mode f_lib f_wave f_queue
    while IFS= read -r raw || [ -n "$raw" ]; do
        trimmed="${raw#"${raw%%[![:space:]]*}"}"        # left-trim whitespace
        case "$trimmed" in ''|'#'*) continue ;; esac    # blank / comment
        read -r f_model f_mode f_lib f_wave f_queue _ <<< "$trimmed"
        [ -z "$f_model" ] && continue

        f_lib="${f_lib:-$DEFAULT_LIBRARY}"
        f_wave="${f_wave:-$DEFAULT_WAVE_SIZE}"
        f_queue="${f_queue:-$DEFAULT_QUEUE}"

        if [ "$f_mode" != "ersilia" ] && [ "$f_mode" != "singularity" ]; then
            add_job "$f_model" "${f_mode:-?}" "${f_lib:-NA}" "$f_wave" "$f_queue" \
                    skipped "unknown mode '${f_mode:-}' (want ersilia|singularity)"
            continue
        fi
        if [ -z "$f_lib" ]; then
            add_job "$f_model" "$f_mode" "NA" "$f_wave" "$f_queue" \
                    skipped "no library and no default_library given"
            continue
        fi
        f_lib="$(resolve_library "$f_lib")"
        if ! [[ "$f_wave" =~ ^[0-9]+$ ]] || [ "$f_wave" -lt 1 ] || [ "$f_wave" -gt 1000 ]; then
            add_job "$f_model" "$f_mode" "$f_lib" "$f_wave" "$f_queue" \
                    skipped "wave_size '$f_wave' out of 1..1000"
            continue
        fi
        add_job "$f_model" "$f_mode" "$f_lib" "$f_wave" "$f_queue" pending ""
    done < "$QUEUE_FILE"
}

ensure_sif() {  # $1=model $2=logfile ; 0 if present (or fetched), 1 otherwise
    local m="$1" logf="$2"
    [ -f "/shared/sif-files/${m}.sif" ] && return 0
    if [ "$AUTO_FETCH_SIF" = "1" ]; then
        if [ -x /shared/scripts/download-ersilia-model.sh ]; then
            /shared/scripts/download-ersilia-model.sh "$m" >>"$logf" 2>&1 && return 0
        else
            aws s3 cp "s3://${S3_BUCKET}/sif-files/${m}.sif" \
                "/shared/sif-files/${m}.sif" >>"$logf" 2>&1 && return 0
        fi
    fi
    return 1
}

run_queue() {
    local i model mode lib wave queue script rc total_jobs=${#Q_MODEL[@]}
    local fails=0
    for i in "${!Q_MODEL[@]}"; do
        model="${Q_MODEL[i]}"; mode="${Q_MODE[i]}"; lib="${Q_LIB[i]}"
        wave="${Q_WAVE[i]}"; queue="${Q_QUEUE[i]}"

        if [ "${Q_STATUS[i]}" != "pending" ]; then
            log_line "job $((i + 1))/${total_jobs}: ${model} (${mode}) -> ${Q_STATUS[i]} :: ${Q_NOTE[i]}"
            continue
        fi

        log_line "----- job $((i + 1))/${total_jobs} : ${model} (${mode}) on ${lib} -----"

        # resume fast-skip: already complete in S3?
        Q_TOTAL[i]="$(s3_count_input "$lib")"
        Q_DONE[i]="$(s3_count_output "$model" "$lib" "$mode")"
        write_state
        if [ "${Q_TOTAL[i]}" -gt 0 ] && [ "${Q_DONE[i]}" -ge "${Q_TOTAL[i]}" ]; then
            set_status "$i" done
            log_line "  already complete in S3 (${Q_DONE[i]}/${Q_TOTAL[i]}) — skipping dispatch"
            continue
        fi

        Q_START[i]="$(now_iso)"
        set_status "$i" running

        # pre-flight: SIF present (no download unless AUTO_FETCH_SIF=1)
        if ! ensure_sif "$model" "${Q_LOG[i]}"; then
            Q_FIN[i]="$(now_iso)"; set_status "$i" missing-files
            log_line "  SIF not found: /shared/sif-files/${model}.sif — missing-files, continuing"
            continue
        fi
        # pre-flight: input library must have chunks in S3
        if [ "${Q_TOTAL[i]}" -le 0 ]; then
            Q_FIN[i]="$(now_iso)"; set_status "$i" missing-files
            log_line "  no input chunks in s3://${S3_BUCKET}/input/${lib}/ — missing-files, continuing"
            continue
        fi

        script="${WAVES_DIR}/$(mode_script "$mode")"
        if [ "$DRY_RUN" -eq 1 ]; then
            log_line "  [dry-run] S3_BUCKET=$S3_BUCKET POLL_SECONDS=$POLL_SECONDS $script $model $lib $wave $queue"
            rc="${FAKE_RC[i]:-0}"
        else
            log_line "  dispatch: $script $model $lib $wave $queue  (log: ${Q_LOG[i]})"
            S3_BUCKET="$S3_BUCKET" POLL_SECONDS="$POLL_SECONDS" \
                "$script" "$model" "$lib" "$wave" "$queue" 2>&1 | tee -a "${Q_LOG[i]}"
            rc="${PIPESTATUS[0]}"
        fi

        Q_FIN[i]="$(now_iso)"
        Q_DONE[i]="$(s3_count_output "$model" "$lib" "$mode")"
        if [ "$rc" -eq 0 ]; then
            set_status "$i" done
            log_line "  done (${Q_DONE[i]}/${Q_TOTAL[i]})"
        else
            set_status "$i" failed; fails=$((fails + 1))
            log_line "  FAILED rc=$rc (${Q_DONE[i]}/${Q_TOTAL[i]})"
            if [ "$ON_FAIL" = "halt" ]; then
                log_line "ON_FAIL=halt — stopping the queue at job $((i + 1))."
                return 1
            fi
        fi
    done
    [ "$fails" -eq 0 ] && return 0 || return 1
}

summary() {
    local i s
    declare -A c=()
    for i in "${!Q_MODEL[@]}"; do s="${Q_STATUS[i]}"; c[$s]=$(( ${c[$s]:-0} + 1 )); done
    local line=""
    for s in done running pending failed missing-files skipped; do
        [ -n "${c[$s]:-}" ] && line+="${s}=${c[$s]}  "
    done
    echo "=========================================="
    echo "Scheduler summary: ${line:-(no jobs)}"
    echo "  State file : $STATE_FILE"
    echo "  Live table : ${SCRIPT_DIR}/scheduler-status.sh $STATE_FILE"
    echo "=========================================="
}

# ---- run ----
echo "=========================================="
echo "Wave scheduler (driver)"
echo "  Queue      : $QUEUE_FILE"
echo "  Default lib: ${DEFAULT_LIBRARY:-<none>}   wave=$DEFAULT_WAVE_SIZE   queue=$DEFAULT_QUEUE"
echo "  Orchestr.  : $WAVES_DIR/submit-{ersilia,singularity}-waves.sh"
echo "  On fail    : $ON_FAIL     Auto-fetch SIF: $AUTO_FETCH_SIF     Dry-run: $DRY_RUN"
echo "  State file : $STATE_FILE"
echo "=========================================="

parse_queue
if [ "${#Q_MODEL[@]}" -eq 0 ]; then
    echo "Queue is empty (all blank/comment lines) — nothing to do."
    exit 0
fi
write_state
run_queue; RC=$?
summary
exit "$RC"
