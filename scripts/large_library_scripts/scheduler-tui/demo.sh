#!/bin/bash
# =============================================================================
# Try the dashboard with no cluster, no AWS, no SSH.
# =============================================================================
# Spins up a throwaway scheduler in a temp dir: a real driver in --dry-run mode
# with stubbed S3 counts, a queue with a mix of statuses, and the TUI on top.
# Everything is fake except the code — the driver, sched-ctl.sh and the dashboard
# are exactly the ones that run on the cluster.
#
# Use it to see the interface, click around, and check the keybindings before
# pointing it at the real thing. Nothing here can touch the cluster: the driver
# runs with --dry-run and SCHED_FAKE_S3=1, so it never calls aws or sbatch.
#
# Usage: ./demo.sh            # sets up, runs the TUI, cleans up on exit
#        ./demo.sh --keep     # leave the temp dir behind to poke at with ctl
# =============================================================================

set -uo pipefail

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHED="${HERE}/../scheduler"
[ -f "${SCHED}/run-model-queue.sh" ] || { echo "ERROR: cannot find ../scheduler next to $HERE"; exit 1; }

DEMO="$(mktemp -d "${TMPDIR:-/tmp}/scheduler-demo.XXXXXX")"
export LOG_DIR="${DEMO}/logs"
export SCHED_FAKE_S3=1
export SCHED_FAKE_DURATION=100000     # the "running" model just keeps running
export CTL_POLL=1 IDLE_POLL=2 REFRESH_SECONDS=5
mkdir -p "$LOG_DIR"

QUEUE="${DEMO}/demo.queue"
cat > "$QUEUE" <<'EOF'
# Demo queue — Enamine REAL 1.4B descriptor sweep
# (this banner stays on top when you reorder things)

# the standardizer, already finished
eos4k4f_v1          ersilia      Enamine_Real_Sample_1.4B
eos12x7_v1          ersilia      Enamine_Real_Sample_1.4B
eos11sm_v1          ersilia      Enamine_Real_Sample_1.4B
# parked on purpose — select it and press h to un-park
eos6ojg_v1          ersilia      Enamine_Real_Sample_1.4B                     hold
eos74km_v1          ersilia      Enamine_Real_Sample_1.4B
mtb-public-models   singularity  molport                    500
EOF

# Stubbed S3 inventory: what the driver would otherwise learn from `aws s3 ls`.
cat > "${LOG_DIR}/fake-s3.txt" <<'EOF'
input Enamine_Real_Sample_1.4B 13644
input Molport_Screening_Compounds_5.3M 53
output eos4k4f_v1 Enamine_Real_Sample_1.4B ersilia 13644
output eos12x7_v1 Enamine_Real_Sample_1.4B ersilia 4102
EOF

cleanup() {
    [ -n "${DRV:-}" ] && kill "$DRV" 2>/dev/null
    wait "${DRV:-}" 2>/dev/null
    if [ "$KEEP" -eq 1 ]; then
        echo ""
        echo "Kept the demo scheduler at: $DEMO"
        echo "Poke at it with:"
        echo "  LOG_DIR=$LOG_DIR ${SCHED}/sched-ctl.sh -q $QUEUE list"
        echo "Remove it with:  rm -rf $DEMO"
    else
        rm -rf "$DEMO"
    fi
}
trap cleanup EXIT

echo "Starting a fake scheduler in $DEMO ..."
"${SCHED}/run-model-queue.sh" "$QUEUE" Enamine_Real_Sample_1.4B --dry-run \
    > "${DEMO}/driver.out" 2>&1 &
DRV=$!
sleep 3

# Give the "running" model some orchestrator output so the log pane (key: l,
# or double-click a row) has something real-looking to show.
RUNNING_LOG="${LOG_DIR}/eos12x7_v1_Enamine_Real_Sample_1.4B.log"
cat >> "$RUNNING_LOG" <<'EOF'
==========================================
Ersilia Wave Orchestrator
==========================================
Model      : eos12x7_v1
Library    : Enamine_Real_Sample_1.4B
Wave size  : 1000 chunks/wave
----- Wave 5/14 : chunks 4001-5000 of 13644 remaining -----
  Submitted array job 118432 (1000 tasks); waiting ...
  Verifying 1000 outputs ...
  Wave 5 done, synced to S3, evicted from /fsx.
----- Wave 6/14 : chunks 5001-6000 of 13644 remaining -----
  Submitted array job 118433 (1000 tasks); waiting ...
EOF

if ! kill -0 "$DRV" 2>/dev/null; then
    echo "ERROR: the demo driver exited immediately. Its output:" >&2
    cat "${DEMO}/driver.out" >&2
    exit 1
fi

echo ""
echo "Try: a=add  t=top  K/J=move  h=hold  c=cancel  l=log  p=pause  q=quit"
echo "     or just click the buttons / double-click a row / right-click a row."
echo ""
sleep 1

# Prefer an installed entry point; fall back to running from this checkout.
if command -v scheduler-tui >/dev/null 2>&1; then
    scheduler-tui --log-dir "$LOG_DIR" --queue-file "$QUEUE" --refresh 1
elif python3 -c 'import textual' >/dev/null 2>&1; then
    cd "$HERE" && python3 -m scheduler_tui --log-dir "$LOG_DIR" --queue-file "$QUEUE" --refresh 1
else
    echo "Textual is not installed, so the dashboard cannot run. Install it with:" >&2
    echo "  pipx install $HERE      # or: pip install -e $HERE" >&2
    echo "" >&2
    echo "Showing the plain-text table instead:" >&2
    LOG_DIR="$LOG_DIR" "${SCHED}/sched-ctl.sh" -q "$QUEUE" list
    exit 1
fi
