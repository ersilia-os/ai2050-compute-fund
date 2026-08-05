# scheduler — dynamic multi-model wave scheduler

Runs many models over a chemical library back-to-back so the cluster stays busy
with minimal idle time. You give it a queue (model + how to run it: `ersilia` or
`singularity`); it launches each model's wave orchestrator, waits for it to finish,
then starts the next — keeping a status table you can check anytime.

**The queue is live.** The driver re-reads the queue file before every job, so you
can add, remove, reorder or park models while it runs — and cancel the model it is
running right now. Use `sched-ctl.sh` from any shell, or the
[Textual dashboard](../scheduler-tui/) from your laptop.

It wraps the existing wave orchestrators (`../submit-ersilia-waves.sh`,
`../submit-singularity-waves.sh`) **without modifying them**. Those block until a
model's whole library is processed, exit 0/1, and are resumable.

## Files
| File | Role |
|------|------|
| `run-model-queue.sh` | The driver: re-read queue → pre-flight → dispatch the orchestrator → poll it → record status. Runs in tmux. |
| `sched-ctl.sh` | Control CLI: add / rm / top / up / down / move / hold / retry / pause / cancel / list / dump. |
| `scheduler-status.sh` | Renders the status table; live-counts done/total from S3. Safe under `watch`. |
| `scheduler-lib.sh` | Shared helpers (S3 counting, queue parsing, status store, locking). Sourced, not run. |
| `start-scheduler-tmux.sh` | Starts the driver detached in a tmux session `scheduler`. |
| `scheduler-tui.sh` + `setup-tui-venv.sh` | Run the dashboard *on the head node* (optional; see the TUI README). |
| `example.queue` | Copy + edit into your own queue file. |

## Queue file
One job per line; `#`/blank lines ignored; whitespace-separated:
```
<model_id>  <mode>  [library]  [wave_size]  [queue]  [flags]
```
`mode ∈ {ersilia, singularity}`. `library` accepts aliases (`real`, `molport`,
`coconut`, `hit`, `liquid`) or full names; omit it to use the driver's
`default_library`. `wave_size` 1..1000 (default 1000); `queue` default `cpu-queue`.

**Line order is the priority** — jobs run top-to-bottom, so "prioritize" means
"move up". The only flag today is `hold`, which parks a job until you unhold it.
Flags are recognised by shape, so they can go anywhere after the model id:
`eos3b5e ersilia coconut hold` works.

## Run it
```bash
# detached (recommended): starts tmux session 'scheduler'
S3_BUCKET=ai2050-ersilia-cluster \
  ./start-scheduler-tmux.sh my.queue Enamine_Real_Sample_1.4B

# or manually in your own tmux session:
tmux new -s scheduler
S3_BUCKET=ai2050-ersilia-cluster ./run-model-queue.sh my.queue Enamine_Real_Sample_1.4B

# watch progress from any shell:
watch -n 30 ./scheduler-status.sh
```
Args: `run-model-queue.sh <queue_file> [default_library] [default_wave_size] [default_queue] [--dry-run] [--exit-when-empty]`.

## Steer it while it runs
```bash
./sched-ctl.sh list                              # the queue + current statuses
./sched-ctl.sh add eos2r5a ersilia coconut       # append
./sched-ctl.sh add eos2r5a ersilia coconut --top # run it next
./sched-ctl.sh top eos74km_v1                    # prioritize
./sched-ctl.sh up eos74km_v1                     # one position earlier
./sched-ctl.sh move eos74km_v1 3                 # absolute position
./sched-ctl.sh hold eos6ojg_v1                   # park it (driver skips it)
./sched-ctl.sh rm eos6ojg_v1                     # drop it from the queue
./sched-ctl.sh retry eos11sm_v1                  # clear a failed/cancelled verdict
./sched-ctl.sh cancel eos12x7_v1                 # scancel + kill the RUNNING model
./sched-ctl.sh pause ; ./sched-ctl.sh resume     # stop/start picking up new jobs
./sched-ctl.sh stop-after-current                # finish this model, then exit
```
A selector is a model id or a 1-based queue position. Queue edits land at the next
job boundary; `pause` and `cancel` take effect within `CTL_POLL` seconds.

No driver running? The same commands still work — they just edit the queue file, so
you can stage a queue before starting anything (pass `-q my.queue`).

Editing the file by hand is fine too: `sched-ctl.sh` and the driver take the same
lock, and rewrites preserve your comments — the file's top banner stays on top, and
a comment directly above a job moves with that job.

## Behavior
- **Sequential**: one orchestrator at a time (two would fight over the node cap and FSx).
- **Idles instead of exiting** when nothing is runnable, so you can keep feeding it.
  Pass `--exit-when-empty` for the old exit-when-done behaviour.
- **Responsive**: the orchestrator runs in its own process group in the background
  and is polled, so the driver can act on `pause`/`cancel` mid-model instead of
  being blocked inside the child for hours.
- **On failure → continue** (default): the model is marked `failed`, the queue proceeds.
  Set `ON_FAIL=halt` to stop on the first failure.
- **Missing SIF → `missing-files`, skip** (default): a model without
  `/shared/sif-files/<model>.sif` is skipped, never stalling the queue. (Set
  `AUTO_FETCH_SIF=1` to try pulling it from `s3://<bucket>/sif-files/` first.)
- **Resumable**: re-running the same queue instantly re-marks finished models `done`
  (checked from S3) and re-dispatches interrupted ones (the orchestrator resumes only
  remaining chunks). Survives driver restart and Spot preemption. Cancelling keeps
  whatever chunks already reached S3, so `retry` picks up from there.
- **Works for any library** whose chunks are in `s3://<bucket>/input/<lib>/`.
  Results land in S3 `output/<lib>/<model>/`.

## Status values
`pending` · `running` · `done` · `failed` · `cancelled` (stopped by request) ·
`held` (parked with the `hold` flag) · `missing-files` (SIF or input absent) ·
`skipped` (bad queue line). The dashboard adds `stale` for a `running` row whose
driver is no longer alive.

## State on disk (all under `$LOG_DIR`)
| Path | What it is |
|------|-----------|
| `state.tsv` | Render view in queue order — what `scheduler-status.sh` reads. |
| `status.tsv` | Durable status store keyed `model\|mode\|library`. Survives restarts and queue edits. |
| `driver.info` | Facts about the live driver (pid, queue path, defaults) — how ctl and the TUI find it. |
| `control/` | `paused` / `stop-after-current` flag files plus one-shot request files. |
| `<model>_<library>.log` | Per-job orchestrator output. Named by identity, so it survives reordering. |
| `.queue.lock`, `.lock/` | Queue-file flock, and the single-driver lock. |

## Env
`S3_BUCKET` (default `ai2050-ersilia-cluster`), `POLL_SECONDS` (30), `ON_FAIL`
(`continue`|`halt`), `AUTO_FETCH_SIF` (`0`|`1`), `LOG_DIR`
(`/shared/logs/scheduler`), `STATE_FILE`, `STATUS_FILE`, `CTL_POLL` (15),
`IDLE_POLL` (30), `REFRESH_SECONDS` (300 — how often a running job's S3 progress is
re-counted), `EXIT_WHEN_EMPTY` (0).

## Deploy (same as the rest of large_library_scripts)
```bash
# local -> S3   (include scheduler-tui/ only if you want the TUI on the head node)
aws s3 sync <repo>/scripts/large_library_scripts/scheduler/ \
  s3://ai2050-ersilia-cluster/scripts/large_library_scripts/scheduler/ --exclude "__pycache__/*"
# head node -> /shared
aws s3 sync s3://ai2050-ersilia-cluster/scripts/large_library_scripts/scheduler/ \
  /shared/scripts/large_library_scripts/scheduler/ && \
  chmod +x /shared/scripts/large_library_scripts/scheduler/*.sh
```

## Dry run (no cluster jobs, no AWS)
```bash
export LOG_DIR=/tmp/schedtest SCHED_FAKE_S3=1
mkdir -p $LOG_DIR
printf 'input Coconut_715K 10\n' > $LOG_DIR/fake-s3.txt   # stub the S3 counts
./run-model-queue.sh example.queue Coconut_715K --dry-run
./sched-ctl.sh list
```
`--dry-run` prints the dispatch line instead of running it, skips the SIF
pre-flight, and runs a real sleeping child so `pause`/`cancel` are genuinely
exercised. `SCHED_FAKE_S3=1` reads chunk counts from `$LOG_DIR/fake-s3.txt`
(`input <lib> <n>` / `output <model> <lib> <mode> <n>`) instead of calling S3, so the
whole thing runs with no credentials. `SCHED_FAKE_RC="0 1 0"` injects per-index exit
codes; `SCHED_FAKE_DURATION` sets how long the fake child sleeps.
