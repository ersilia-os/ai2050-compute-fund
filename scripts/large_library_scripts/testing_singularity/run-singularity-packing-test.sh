#!/bin/bash
# =============================================================================
# Singularity packing test — how many jobs fit on ONE EC2 instance?
# =============================================================================
# Runs <num_jobs> singularity model jobs CONCURRENTLY on the machine that executes
# this script (i.e. one node / one EC2 instance), samples system RAM + CPU load while
# they run, then verifies every output. Use it to pick the right packing lever for
# run-singularity-wave-job.sh (`--exclusive` vs `--cpus-per-task=N`).
#
# It does NOT use SLURM arrays and does NOT touch the real S3 output / pipeline —
# outputs land in a throwaway workdir. Run it ON a compute node of the target
# instance type, e.g.:
#     srun --partition=cpu-queue --exclusive --pty bash      # grab a whole node
#     bash run-singularity-packing-test.sh <model_id> 4      # try 4 concurrent jobs
#     bash run-singularity-packing-test.sh <model_id> 8      # then 8, 16, ...
# Increase <num_jobs> until RAM runs out, outputs start failing, or load per job
# climbs above ~1 core/job.
#
# Usage: run-singularity-packing-test.sh <model_id> <num_jobs> [library] [source_dir]
#
#   <model_id>    e.g. mtb-public-models  (needs /shared/sif-files/<model_id>.sif)
#   <num_jobs>    how many jobs to run in parallel (each on a distinct input chunk)
#   [library]     default Enamine_Real_Sample_1.4B
#   [source_dir]  where to take input chunks from (default /fsx/input/<library>);
#                 if it has fewer than <num_jobs> chunks, they are pulled from S3.
#
# Env: S3_BUCKET (default ai2050-ersilia-cluster), WORKDIR (default
#      /fsx/output/_packing_test/<model_id>/<stamp>), SAMPLE_SECONDS (default 2).
# =============================================================================

set -uo pipefail

MODEL_ID="${1:-}"
NUM_JOBS="${2:-}"
LIBRARY="${3:-Enamine_Real_Sample_1.4B}"
SRC_DIR="${4:-/fsx/input/${LIBRARY}}"
S3_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-2}"

if [ -z "$MODEL_ID" ] || [ -z "$NUM_JOBS" ]; then
    echo "Usage: $0 <model_id> <num_jobs> [library] [source_dir]"
    echo "Example: $0 mtb-public-models 4"
    exit 1
fi
if ! [[ "$NUM_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: num_jobs must be a positive integer (got '$NUM_JOBS')."
    exit 1
fi

SIF_FILE="/shared/sif-files/${MODEL_ID}.sif"
[ -f "$SIF_FILE" ] || { echo "ERROR: SIF not found: $SIF_FILE"; exit 1; }
command -v singularity >/dev/null 2>&1 || { echo "ERROR: singularity not on PATH."; exit 1; }

STAMP=$(date +%Y%m%d_%H%M%S)
WORKDIR="${WORKDIR:-/fsx/output/_packing_test/${MODEL_ID}/${STAMP}}"
IN="${WORKDIR}/inputs"; OUT="${WORKDIR}/outputs"; LOGS="${WORKDIR}/logs"
STATUS="${WORKDIR}/status"; METRICS="${WORKDIR}/metrics.tsv"
mkdir -p "$IN" "$OUT" "$LOGS" "$STATUS"

S3_INPUT="s3://${S3_BUCKET}/input/${LIBRARY}/"
NPROC=$(nproc)
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')

# Cap each job's math-library threads to its fair share of cores, so N concurrent
# jobs on this node mirror what --cpus-per-task=(NPROC/NUM_JOBS) enforces in production.
# Without this every job sees all $NPROC cores and oversubscribes, skewing the timing.
THREADS_PER_JOB=$(( NPROC / NUM_JOBS ))
[ "$THREADS_PER_JOB" -lt 1 ] && THREADS_PER_JOB=1

echo "=========================================="
echo "Singularity Packing Test"
echo "=========================================="
echo "Host        : $(hostname)"
echo "CPUs (nproc): $NPROC"
echo "Total RAM   : ${TOTAL_MEM_MB} MB"
echo "Model       : $MODEL_ID"
echo "Library     : $LIBRARY"
echo "Jobs        : $NUM_JOBS (concurrent)"
echo "Threads/job : $THREADS_PER_JOB (OMP/MKL cap = NPROC/NUM_JOBS)"
echo "Workdir     : $WORKDIR"
echo "=========================================="

# --- 1. Gather <num_jobs> distinct input chunks ----------------------------
INPUTS=()
LOCAL_AVAIL=$(ls "$SRC_DIR"/${LIBRARY}_chunk_*.csv 2>/dev/null | wc -l | tr -d ' ')
if [ "$LOCAL_AVAIL" -ge "$NUM_JOBS" ]; then
    echo "Taking $NUM_JOBS input chunk(s) from $SRC_DIR"
    while IFS= read -r f; do
        [ "${#INPUTS[@]}" -ge "$NUM_JOBS" ] && break
        INPUTS+=("$f")
    done < <(ls "$SRC_DIR"/${LIBRARY}_chunk_*.csv 2>/dev/null | sort)
else
    echo "Only $LOCAL_AVAIL local chunk(s) in $SRC_DIR — downloading $NUM_JOBS from $S3_INPUT"
    mapfile -t S3FILES < <(aws s3 ls "$S3_INPUT" | awk '{print $NF}' \
        | grep -E "${LIBRARY}_chunk_.*\.csv$" | sort | head -n "$NUM_JOBS")
    if [ "${#S3FILES[@]}" -lt "$NUM_JOBS" ]; then
        echo "ERROR: only found ${#S3FILES[@]} chunk(s) in S3, need $NUM_JOBS."
        exit 1
    fi
    for fn in "${S3FILES[@]}"; do
        echo "  downloading $fn"
        aws s3 cp "${S3_INPUT}${fn}" "${IN}/${fn}" >/dev/null || {
            echo "ERROR: failed to download $fn"; exit 1; }
        INPUTS+=("${IN}/${fn}")
    done
fi
echo "Prepared ${#INPUTS[@]} input chunk(s)."
echo ""

# --- 2. Background resource sampler -----------------------------------------
# Samples system memory + 1-min load + count of running `singularity run` procs.
SAMPLER_FLAG="${WORKDIR}/.sampling"
touch "$SAMPLER_FLAG"
printf 'epoch\tused_mb\tavail_mb\tload1\tn_sing\n' > "$METRICS"
(
    while [ -f "$SAMPLER_FLAG" ]; do
        read -r used avail < <(free -m | awk '/^Mem:/{print $3" "$7}')
        load=$(awk '{print $1}' /proc/loadavg)
        n=$(pgrep -c -f "singularity run" 2>/dev/null); n=${n:-0}
        printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$used" "$avail" "$load" "$n" >> "$METRICS"
        sleep "$SAMPLE_SECONDS"
    done
) &
SAMPLER_PID=$!

cleanup() { rm -f "$SAMPLER_FLAG"; kill "$SAMPLER_PID" 2>/dev/null; }
trap cleanup EXIT

BASELINE_USED=$(free -m | awk '/^Mem:/{print $3}')
echo "Baseline memory used: ${BASELINE_USED} MB"

# --- 3. Launch all jobs concurrently ---------------------------------------
echo "Launching $NUM_JOBS concurrent singularity job(s) at $(date) ..."
RUN_START=$(date +%s)
PIDS=()
i=0
for inpath in "${INPUTS[@]}"; do
    chunk=$(basename "$inpath" .csv | grep -oP '\d+$'); chunk=${chunk:-$i}
    outpath="${OUT}/${MODEL_ID}_${chunk}.csv"
    joblog="${LOGS}/job_${i}_chunk_${chunk}.log"
    (
        js=$(date +%s)
        singularity run \
            --env OMP_NUM_THREADS="$THREADS_PER_JOB" \
            --env MKL_NUM_THREADS="$THREADS_PER_JOB" \
            --bind /fsx:/fsx --bind /shared:/shared --bind "${WORKDIR}:${WORKDIR}" \
            "$SIF_FILE" "$inpath" "$outpath" > "$joblog" 2>&1
        rc=$?
        je=$(date +%s)
        printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$rc" "$((je - js))" "$inpath" "$outpath" \
            > "${STATUS}/job_${i}.status"
    ) &
    PIDS+=($!)
    i=$((i + 1))
done

# --- 4. Wait for all jobs ----------------------------------------------------
FAILED_WAIT=0
for pid in "${PIDS[@]}"; do
    wait "$pid" || FAILED_WAIT=$((FAILED_WAIT + 1))
done
RUN_END=$(date +%s)
cleanup
trap - EXIT
echo "All jobs finished at $(date) (wall ${RUN_END} - ${RUN_START} = $((RUN_END - RUN_START))s)."
echo ""

# --- 5. Verify outputs ------------------------------------------------------
PASS=0; FAIL=0
declare -a DURATIONS=()
echo "----- per-job results -----"
printf "%-5s %-10s %-6s %-8s %-10s %s\n" "job" "chunk" "rc" "secs" "rows" "status"
for sf in "$STATUS"/job_*.status; do
    [ -f "$sf" ] || continue
    IFS=$'\t' read -r jid rc secs inpath outpath < "$sf"
    chunk=$(basename "$inpath" .csv | grep -oP '\d+$'); chunk=${chunk:-$jid}
    DURATIONS+=("$secs")
    verdict="OK"
    rows="-"
    if [ "$rc" -ne 0 ]; then
        verdict="FAIL(rc=$rc)"
    elif [ ! -f "$outpath" ]; then
        verdict="FAIL(no-output)"
    else
        in_rows=$(( $(wc -l < "$inpath") - 1 ))
        out_rows=$(( $(wc -l < "$outpath") - 1 ))
        rows="${out_rows}/${in_rows}"
        [ "$in_rows" -ne "$out_rows" ] && verdict="FAIL(row-mismatch)"
    fi
    [ "$verdict" = "OK" ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
    printf "%-5s %-10s %-6s %-8s %-10s %s\n" "$jid" "$chunk" "$rc" "$secs" "$rows" "$verdict"
done

# --- 6. Resource summary from the sampler -----------------------------------
# peak used, min available, max load, max concurrent singularity procs.
read -r PEAK_USED MIN_AVAIL MAX_LOAD MAX_SING < <(
    awk -F'\t' 'NR>1{
        if($2>pu)pu=$2; if(mn==""||$3<mn)mn=$3;
        if($4>ml)ml=$4; if($5>ms)ms=$5
    } END{printf "%d %d %s %d", pu, mn, (ml==""?0:ml), ms}' "$METRICS"
)
DELTA_USED=$(( PEAK_USED - BASELINE_USED )); [ "$DELTA_USED" -lt 0 ] && DELTA_USED=0
PER_JOB_MB=$(( DELTA_USED / NUM_JOBS ))

# rough capacity estimates
RAM_FIT="n/a"
[ "$PER_JOB_MB" -gt 0 ] && RAM_FIT=$(( TOTAL_MEM_MB * 85 / 100 / PER_JOB_MB ))   # 85% of RAM
LOAD_PER_JOB=$(awk -v l="$MAX_LOAD" -v n="$NUM_JOBS" 'BEGIN{printf "%.2f", (n>0? l/n : 0)}')
CPU_FIT=$(awk -v p="$NPROC" -v lpj="$LOAD_PER_JOB" 'BEGIN{printf "%d", (lpj>0? p/lpj : 0)}')

echo ""
echo "=========================================="
echo "Packing summary  (model=$MODEL_ID, jobs=$NUM_JOBS)"
echo "------------------------------------------"
echo "Outputs OK / FAIL     : ${PASS} / ${FAIL}"
echo "Wall time (all jobs)  : $((RUN_END - RUN_START)) s"
echo "Slowest / fastest job : $(printf '%s\n' "${DURATIONS[@]}" | sort -n | tail -1)s / $(printf '%s\n' "${DURATIONS[@]}" | sort -n | head -1)s"
echo "Max concurrent procs  : ${MAX_SING} (expected ${NUM_JOBS})"
echo "------------------------------------------"
echo "RAM total             : ${TOTAL_MEM_MB} MB"
echo "RAM baseline used     : ${BASELINE_USED} MB"
echo "RAM peak used         : ${PEAK_USED} MB   (min available ${MIN_AVAIL} MB)"
echo "RAM used by $NUM_JOBS jobs   : ${DELTA_USED} MB  (~${PER_JOB_MB} MB/job)"
echo "Max 1-min load        : ${MAX_LOAD}  (~${LOAD_PER_JOB} cores/job over ${NPROC} CPUs)"
echo "------------------------------------------"
echo "Rough capacity on THIS instance type:"
echo "  RAM-bound  : ~${RAM_FIT} jobs   (85% of RAM / ${PER_JOB_MB} MB per job)"
echo "  CPU-bound  : ~${CPU_FIT} jobs   (${NPROC} CPUs / ${LOAD_PER_JOB} cores per job)"
echo "  => max concurrent ≈ the SMALLER of the two."
echo "     For run-singularity-wave-job.sh use --cpus-per-task=\$(( ${NPROC} / max_jobs ))"
echo "     (or keep --exclusive if max_jobs is ~1)."
echo "------------------------------------------"
echo "Details: $WORKDIR"
echo "  per-job logs   : $LOGS"
echo "  sampler metrics: $METRICS"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    echo "NOTE: $FAIL job(s) failed at this concurrency — likely OOM/contention. Back off num_jobs."
    exit 1
fi
