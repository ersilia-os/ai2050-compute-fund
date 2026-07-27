# scheduler — sequential multi-model wave scheduler

Runs many models over a chemical library back-to-back so the cluster stays busy
with minimal idle time. You give it a queue (model + how to run it: `ersilia` or
`singularity`); it launches each model's wave orchestrator, waits for it to finish,
then starts the next — keeping a status table you can check anytime.

It wraps the existing wave orchestrators (`../submit-ersilia-waves.sh`,
`../submit-singularity-waves.sh`) **without modifying them**. Those block until a
model's whole library is processed, exit 0/1, and are resumable — so the scheduler
is a thin sequential loop that tracks status.

## Files
| File | Role |
|------|------|
| `run-model-queue.sh` | The driver: parse queue → per-job pre-flight → dispatch the right wave orchestrator → record status. Runs in tmux. |
| `scheduler-status.sh` | Renders the status table; live-counts done/total from S3. Safe under `watch`. |
| `scheduler-lib.sh` | Shared helpers (S3 counting, atomic state write). Sourced, not run. |
| `start-scheduler-tmux.sh` | Starts the driver detached in a tmux session `scheduler`. |
| `example.queue` | Copy + edit into your own queue file. |

## Queue file
One job per line; `#`/blank lines ignored; whitespace-separated:
```
<model_id>  <mode>  [library]  [wave_size]  [queue]
```
`mode ∈ {ersilia, singularity}`. `library` accepts aliases (`real`, `molport`,
`coconut`, `hit`, `liquid`) or full names; omit it to use the driver's
`default_library`. `wave_size` 1..1000 (default 1000); `queue` default `cpu-queue`.

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
Args: `run-model-queue.sh <queue_file> [default_library] [default_wave_size] [default_queue] [--dry-run]`.

## Behavior
- **Sequential**: one orchestrator at a time (two would fight over the node cap and FSx).
- **On failure → continue** (default): the model is marked `failed`, the queue proceeds. Set `ON_FAIL=halt` to stop on the first failure.
- **Missing SIF → `missing-files`, skip** (default): a model without `/shared/sif-files/<model>.sif` is skipped, never stalling the queue. (Set `AUTO_FETCH_SIF=1` to try pulling it from `s3://<bucket>/sif-files/` first.)
- **Resumable**: re-running the same queue instantly re-marks finished models `done` (checked from S3) and re-dispatches interrupted ones (the orchestrator resumes only remaining chunks). Survives driver restart and Spot preemption.
- **Works for any library** whose chunks are in `s3://<bucket>/input/<lib>/` (all six current libraries are). Results land in S3 `output/<lib>/<model>/`.

## Status values
`pending` · `running` · `done` · `failed` · `missing-files` (SIF or input absent) · `skipped` (bad queue line: unknown mode, no library, wave_size out of range).

## Env
`S3_BUCKET` (default `ai2050-ersilia-cluster`), `POLL_SECONDS` (30), `ON_FAIL`
(`continue`|`halt`), `AUTO_FETCH_SIF` (`0`|`1`), `LOG_DIR`
(`/shared/logs/scheduler`), `STATE_FILE` (`$LOG_DIR/state.tsv`).

## Deploy (same as the rest of large_library_scripts)
```bash
# local -> S3
aws s3 sync <repo>/scripts/large_library_scripts/scheduler/ \
  s3://ai2050-ersilia-cluster/scripts/large_library_scripts/scheduler/ --exclude "__pycache__/*"
# head node -> /shared
aws s3 sync s3://ai2050-ersilia-cluster/scripts/large_library_scripts/scheduler/ \
  /shared/scripts/large_library_scripts/scheduler/ && \
  chmod +x /shared/scripts/large_library_scripts/scheduler/*.sh
```

## Dry run (no cluster jobs)
```bash
./run-model-queue.sh example.queue Enamine_Real_Sample_1.4B --dry-run
./scheduler-status.sh /shared/logs/scheduler/state.tsv
```
Prints the exact dispatch line for each job instead of running it, and exercises
the state file + renderer. (For failure-path tests, `SCHED_FAKE_RC="0 1 0"` injects
fake exit codes per job index under `--dry-run`.)
