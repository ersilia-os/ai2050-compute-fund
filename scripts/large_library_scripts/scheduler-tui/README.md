# scheduler-tui

Terminal dashboard for the [Ersilia wave scheduler](../scheduler/) — see and steer a
running model queue on the AWS cluster, from one screen.

Run it on your laptop and it reaches the cluster over SSH. Nothing but the bash
scheduler needs to be installed there.

```
 ● RUNNING  ·  pid 41288  ·  ai2050-head
 queue …/scheduler/enamine.queue   default lib Enamine_Real_Sample_1.4B   wave 1000
   all 4     ● running 1     ○ pending 2     ✓ done 1
   + add   run next   ↑   ↓   hold   retry   log   cancel   remove      pause queue
 #   MODEL          MODE      LIBRARY                   STATUS      CHUNKS DONE      PROGRESS
 1   eos4k4f_v1     ersilia   Enamine_Real_Sample_1.4B  ✓ done       13644 / 13644   ████████████████ 100%
 2   eos12x7_v1     ersilia   Enamine_Real_Sample_1.4B  ● running     4102 / 13644   ████▊░░░░░░░░░░░  30%
 3   eos11sm_v1     ersilia   Enamine_Real_Sample_1.4B  ○ pending        0 / 13644   ░░░░░░░░░░░░░░░░   0%
 4   eos6ojg_v1     ersilia   Enamine_Real_Sample_1.4B  ‖ held           0 / 13644   ░░░░░░░░░░░░░░░░   0%
 log · eos12x7_v1    [follow ✓]
 Wave 5/14 : chunks 4001-5000 of 13644 remaining
   Submitted array job 118432 (1000 tasks); waiting ...
```

The palette follows one rule: **the running row is the only luminous thing on
screen, and warmth always means attention.** Settled rows (pending, done) are
low-chroma and recede; anything warm — held, missing-files, failed, cancelled,
stale — wants a human. Progress bars carry a partial-block leading edge, so at
13,644 chunks across 16 cells you can still see a wave land. `D` switches between
the dark and light theme.

## Install

On your laptop:

```bash
pipx install "git+https://github.com/ersilia-os/AI2050-Compute-Fund#subdirectory=scripts/large_library_scripts/scheduler-tui"
# or, from a checkout:
pipx install scripts/large_library_scripts/scheduler-tui
# or, while iterating on the code:
pip install -e scripts/large_library_scripts/scheduler-tui
```

Then point it at the cluster:

```bash
scheduler-tui --host ai2050-head
```

`ai2050-head` is whatever you call the head node in `~/.ssh/config`. That is the
only setup: the dashboard runs `sched-ctl.sh` over SSH and reads nothing else.

Check the transport before opening the UI — useful when an SSH alias is wrong:

```bash
scheduler-tui --host ai2050-head --check
```

### On the head node instead

If you are already SSH'd in, `../scheduler/scheduler-tui.sh` launches the same app
there. It needs a Python with Textual, which `../scheduler/setup-tui-venv.sh` builds
once at `/shared/venvs/scheduler-tui`. It deliberately does **not** use
`/shared/python39` — that build's `ssl` is broken on AL2023 and the AL2 cluster
depends on it unchanged. Inside tmux, run `tmux set -g mouse on` so clicks work.

## Using it

Every action has both a key and a click. Nothing is keyboard-only.

| Key | Click | Does |
|-----|-------|------|
| `a` | `+ add` | Add a model (dialog: id, mode, library, wave, partition, run-next) |
| `t` | `run next` | Prioritize — move to the front of the queue |
| `K` / `J` | `↑` / `↓` | Move one position earlier / later |
| `h` | `hold` | Park or un-park the selected job |
| `r` | `retry` | Clear a `failed`/`cancelled` verdict so it runs again |
| `c` | `cancel` | Cancel the **running** model (scancel + kill); hold a pending one |
| `x` | `remove` | Delete the queue line |
| `p` | `pause queue` | Stop / resume picking up new jobs |
| `s` | — | Arm stop-after-current: finish this model, then exit the driver |
| `D` | — | Switch between the dark and light theme |
| `l` | `log` | Toggle the log pane (or double-click a row) |
| `f` | — | Freeze / follow the log tail |
| `R` | `recount` | Recount every row from S3 now (matches `scheduler-status.sh`) |
| `q` | — | Quit the dashboard (the scheduler keeps running) |

Also mouse-driven: click a row to select, **double-click** to open its log,
**right-click** for the same verbs as a menu, click a status chip to filter the
table, click a column header to sort, drag the divider to resize the log pane,
scroll wheel anywhere. Destructive verbs (cancel, remove) ask first and name the
model.

Reading the table: a library shown with a trailing `*` came from the driver's
`default_library` rather than the queue line. Aliases (`molport`) are displayed
resolved, the same way the scheduler keys them. `stale` means a row claims to be
running but no driver is alive — usually a driver that was killed mid-job.

Quitting the dashboard does not touch the scheduler — it is a viewer plus a remote
control, and holds no state of its own.

## How it works

The app does exactly two things: run `sched-ctl.sh dump` to read a snapshot, and run
`sched-ctl.sh <verb>` to change something. Both go through one `Runner` seam, which
is why the same code works locally and over SSH.

* **One round-trip per refresh.** `dump` returns the driver info, queue file, both
  status tables, the library list and a log tail in a single delimited blob, so a
  tick is one SSH exchange — not four. The connection is reused via
  `ControlMaster`/`ControlPersist`, so each call costs milliseconds after the first.
* **S3 counting is paced, not skipped.** Listing a 13,644-object prefix takes about
  a second, so the counts come in three tiers: the 2s refresh reads only what the
  driver recorded; once a minute ctl recounts *totals* (one listing per library, not
  per row) plus the running row; and `R` recounts every row on demand. That way the
  numbers match `scheduler-status.sh` without hammering S3 — which matters most
  against an old driver, whose recorded counts never move mid-job.
* **Every mutation goes through `sched-ctl.sh`.** The queue file is never written by
  this client, so file locking and the comment-preserving rewrite rules have exactly
  one implementation — and the CLI stays fully usable on its own.
* **Nothing blocks the UI.** Polling and mutations run in worker threads. A dropped
  VPN or a slow shared filesystem shows a stale banner rather than freezing, and a
  `running` row whose driver has died is shown as `stale`, not as progress.

## Options

```
--host HOST         SSH to HOST and run sched-ctl.sh there ($SCHEDULER_HOST)
--ctl PATH          path to sched-ctl.sh on the target ($SCHEDULER_CTL)
--log-dir DIR       scheduler LOG_DIR to inspect ($LOG_DIR)
--queue-file PATH   queue file to edit (default: discovered from the live driver)
--s3-bucket NAME    override S3_BUCKET for ctl calls
--refresh SECONDS   refresh interval (default 2 locally, 5 over SSH)
--ssh-opt OPT       extra ssh argument, repeatable
--check             verify the transport, print one snapshot, exit (no UI)
```

## Development

```bash
pip install -e ".[dev]"
pytest                        # parser tests (no cluster needed)
textual run --dev scheduler_tui.app:SchedulerTUI    # with the Textual devtools
```

The scheduler can be run entirely off-cluster for testing — see the dry-run section
of the [scheduler README](../scheduler/README.md#dry-run-no-cluster-jobs-no-aws).
Point the dashboard at it with `--log-dir /tmp/schedtest`.
