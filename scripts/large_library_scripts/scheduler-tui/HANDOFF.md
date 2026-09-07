# Handoff — scheduler + scheduler-tui

_Written 2026-08-07, after the first production cutover. Read this before changing
either component._

You are picking up a **two-layer** system. Most mistakes here come from not knowing
which layer owns what, so start with that.

---

## 1. What this is

`scheduler/` runs many Ersilia models over a chemical library back-to-back on the
AWS ParallelCluster, one at a time. `scheduler-tui/` is a Textual dashboard that
watches and steers it, normally from a laptop over SSH.

```
  laptop                                     head node (ai2050cluster)
  ┌───────────────────┐                      ┌──────────────────────────────────┐
  │ scheduler-tui     │   ssh (ControlMaster)│ sched-ctl.sh   ← the ONLY API     │
  │  (Python/Textual) ├─────────────────────►│   dump / add / top / hold / …     │
  └───────────────────┘                      │        │                          │
                                             │        ├── queue file (priority)  │
                                             │        ├── status.tsv (verdicts)   │
                                             │        └── control/ (pause,cancel) │
                                             │ run-model-queue.sh  ← the driver  │
                                             │        └─ setsid → submit-*-waves │
                                             │                      └─ sbatch     │
                                             └──────────────────────────────────┘
```

**The TUI never touches AWS, SLURM, or the queue file.** It does exactly two things:
run `sched-ctl.sh dump` to read, and `sched-ctl.sh <verb>` to write. Keep it that
way — it is why the same code works locally and over SSH, and why locking has one
implementation.

### File map

| Path | Role |
|---|---|
| `scheduler/run-model-queue.sh` | The driver. Re-reads the queue before every job, dispatches the orchestrator, polls it. Runs in tmux on the head node. |
| `scheduler/sched-ctl.sh` | Control CLI **and the TUI's only server-side dependency**. |
| `scheduler/scheduler-lib.sh` | Shared helpers: S3 counting, queue parsing, status store, locking. Sourced, never executed. |
| `scheduler/scheduler-status.sh` | Plain-text table, live S3 counts. Pre-dates the TUI, still the fallback. |
| `scheduler/start-scheduler-tmux.sh` | Starts the driver detached in tmux session `scheduler`. |
| `scheduler/scheduler-tui.sh`, `setup-tui-venv.sh` | Optional: run the TUI *on* the head node. |
| `scheduler-tui/scheduler_tui/runner.py` | `LocalRunner` / `SshRunner` — the transport seam. |
| `scheduler-tui/scheduler_tui/model.py` | Pure dump-blob → dataclasses. No I/O, no Textual. Where the tests live. |
| `scheduler-tui/scheduler_tui/app.py` | The Textual app: workers, actions, rendering. |
| `scheduler-tui/scheduler_tui/widgets.py` | QueueTable, StatChips, Splitter, ContextMenu, cell renderers. |
| `scheduler-tui/scheduler_tui/theme.py` | Palette + the two registered Textual themes. |
| `scheduler-tui/demo.sh` | Spins up a throwaway fake scheduler + the TUI. Dev fixture only. |

Cluster paths: scripts at `/shared/scripts/large_library_scripts/scheduler/`,
state at `/shared/logs/scheduler/` (`LOG_DIR`).

---

## 2. Current state

Live on the cluster as of 2026-08-07. Driver running under tmux session `scheduler`
against `/shared/scripts/large_library_scripts/scheduler/models_large_library.queue`
(7 models: `mtb-public-models` on `Enamine_Real_h3d_selected`, then six `eos*` on
`Enamine_Real_Sample_1.4B`). Driven from a laptop with
`scheduler-tui --host ai2050cluster`.

30 tests pass (`tests/test_model.py`). Everything below has been exercised against a
faithful local replica, including a real pre-upgrade driver checked out of git.

**Not verified:** the SSH transport against a real `sshd` (only ever a stub `ssh`
that runs the command locally — it works in production, which is better evidence).
The light theme has had one screenshot, not a real review.

---

## 3. The dump contract

`sched-ctl.sh dump [--log P] [--live|--live-all]` returns one blob of sections
separated by `---8<--- <name>`. This is the whole API surface; if you change it,
change `model.py:split_sections`/`parse_dump` and the tests together.

| Section | Contents |
|---|---|
| `runtime` | `key=value`: `driver_alive`, `driver_legacy`, `legacy_pid`, `paused`, `stop_after_current`, `max_cpus_per_task`, paths, `now` |
| `driver.info` | `key=value` written by the live driver: `pid`, `queue_file`, defaults, `dry_run` |
| `queue` | the raw queue file |
| `jobs` | TSV, **authoritative** parsed view: `pos, model, mode, library, wave, queue, flags, lib_is_default, cpus` — libraries already alias-resolved. New columns are **appended**, never inserted, so an older client's fixed slice still lines up |
| `state.tsv` | render view in queue order (what `scheduler-status.sh` reads) |
| `status.tsv` | durable verdict store, keyed `model\|mode\|library` |
| `libraries` | canonical library names for the add dialog |
| `counts` | TSV `key, done, total`; only present with `--live*`. Blank `done` = "not recounted, keep what you had" |
| `log` | tail of one job log (header carries the path) |
| `end` | sentinel |

Everything before the first marker is ignored, so an SSH banner cannot break
parsing. A truncated blob degrades to fewer sections, never an exception.

---

## 4. Invariants — do not break these

These were each paid for with a production bug. The comments in the code say why;
this is the index.

1. **The queue file is the source of truth, and line order IS priority.** The driver
   re-reads it before every job. "Prioritize" means "move the line up".


2. **`hold` outranks only `pending`.** A running job reads `running`; a cancelled one
   reads `cancelled`. Enforced in three places that must agree:
   `sched-ctl.sh:cmd_list`, `run-model-queue.sh:merge_status`, `model.py:parse_dump`.
   Overriding unconditionally makes a job you just cancelled read as "held".


3. **Control messages are drained at startup, not just in the loop.** `drain_control`
   runs on the driver's first tick, so anything left in `control/` from before it
   started gets consumed by the *new* driver: a stale `shutdown` makes it exit on
   startup, a stale `cancel` kills the named model when the queue reaches it. Hence
   `discard_stale_control` before the loop, and `require_driver` in ctl so the
   messages are not posted in the first place. `paused` is deliberately exempt —
   bringing a driver up idle is a real workflow.


4. **Kill the orchestrator BEFORE `scancel`.** See `cancel_child`. Reverse the order
   and the orchestrator sees its array vanish, concludes the wave finished, verifies,
   finds the wave missing from S3, and fires its own *"resubmitting once"* retry — you
   cancel a wave and a fresh one appears.


5. **The driver must kill its orchestrator on exit.** The orchestrator runs under
   `setsid` (so `cancel` can kill the tree), which also means it does *not* die with
   the driver. The `EXIT`/`INT`/`TERM` traps handle it. Without them, stopping the
   driver leaves an orphan submitting waves, and the next driver runs a **second
   model concurrently**.


6. **One lock, and it is not re-entrant by accident.** All queue/status reads and
   writes go through `queue_locked`. Nesting would re-run `exec 9>>`, replacing fd 9
   and silently *releasing* the outer flock — hence the `QUEUE_LOCK_DEPTH` guard.
   Never load state outside the lock and write it back inside.


7. **Queue flags are recognised by shape, not position.** `hold` and any `key=value`
   are flags anywhere after the model id, so `eos1 ersilia mylib hold` works.
   `scheduler-lib.sh:is_queue_flag` and `model.py:is_queue_flag` must stay in step.


8. **Empty positional fields cannot be written.** Fields are whitespace-delimited, so
   a blank middle field is invisible on re-read and later values shift left
   (`model mode <blank> 500` → `library=500`). `cmd_add` fills from the driver's
   defaults or refuses.


9. **`status.tsv` is the authority; `state.tsv` is only a fallback** when there is no
   status store at all (a pre-upgrade driver). Falling back per-job resurrects
   verdicts that `retry` just cleared.


10. **Comment blocks move with their job.** The queue file is modelled as
    header / per-job `pre` / tail — see the block model at the top of `sched-ctl.sh`.
    The top-of-file banner always stays on top.


11. **The client never calls AWS.** S3 counting is paced by ctl in three tiers: cheap
    2s refresh (recorded values), 60s (`--live`: totals per *library* + the running
    row), and `R` (`--live-all`: every row). Totals are per library, never per row.


12. **A recount must not be cancelled by a refresh.** The dump worker is
    `exclusive`, so `_tick()` stands aside while `_live_in_flight` is set. Otherwise
    the 2s tick discards the very numbers the user asked for.


13. **Per-job `cpus` is a queue *flag*, and empty means "do not pass it".** `cpus=N`
    rides as a flag rather than a sixth positional precisely because of #8. It is
    lifted into `QL_CPUS` but *left in* `QL_FLAGS`, the way `hold` is — the flags
    string is what gets written back, so consuming the token would drop the override
    on the next rewrite. It reaches the orchestrator as the `CPUS_PER_TASK` env var
    (not a 5th positional: an out-of-date `/shared` copy then degrades to "no
    override" instead of misreading a partition). When empty, the orchestrator omits
    `--cpus-per-task` entirely so the worker's own `#SBATCH` stands — those defaults
    differ per mode (ersilia 10, singularity 4) and were tuned by hand, so baking a
    default in anywhere would silently re-pack every existing run.

14. **Stale `running` rows get reclaimed at startup.** The driver holds an exclusive
    lock, so anything still marked `running` was left by a driver that died mid-job.
    Without `reclaim_stale_running` that job is neither running nor pending, and is
    skipped forever while the driver idles.

---

## 5. Testing without a cluster

This is the part that makes the work tractable — use it.

**Fake S3.** `SCHED_FAKE_S3=1` makes `s3_count_input`/`s3_count_output` read
`$LOG_DIR/fake-s3.txt` instead of calling `aws`:

```
input  <library>                  <count>
output <model> <library> <mode>   <count>
```

**Fake dispatch.** `--dry-run` prints the dispatch line, **skips the SIF pre-flight**
(so you need no `/shared`), and runs a real `sleep ${SCHED_FAKE_DURATION:-30}` child
— so pause/cancel/trap paths are genuinely exercised. `SCHED_FAKE_RC="0 1 0"`
injects per-index exit codes.

```bash
export LOG_DIR=/tmp/schedtest SCHED_FAKE_S3=1 SCHED_FAKE_DURATION=600 CTL_POLL=1
mkdir -p $LOG_DIR && printf 'input lib 100\n' > $LOG_DIR/fake-s3.txt
printf 'a_v1 ersilia lib\nb_v1 ersilia lib\n' > /tmp/t.queue
./run-model-queue.sh /tmp/t.queue --dry-run &
./sched-ctl.sh -q /tmp/t.queue list
```

**Faking the rest.** Patterns already used, worth reusing:

- a stub `aws` on `PATH` that emits N fake object lines (and `sleep`s) to reproduce
  real timing — this is how the recount timeout was found
- a stub `scancel` that records whether the orchestrator was still alive when it ran
  — this is how the kill-before-scancel ordering was proven
- a stub `ssh` that just runs the command string through `bash -c`, to exercise
  `SshRunner` end to end
- `git show HEAD:...run-model-queue.sh` to stand up a **pre-upgrade** driver and test
  the legacy-detection path

**TUI tests.** `pytest` covers `model.py` only (it is pure by design — keep it that
way). For the UI, drive it headlessly:

```python
async with app.run_test(size=(150, 26)) as pilot:
    await pilot.press("a")                      # keys
    await pilot.click("#tb-hold")               # buttons
    await pilot.click("#table", offset=(10, 3), button=3)   # right-click
```

**Look at it.** `app.export_screenshot()` returns SVG; `cairosvg` converts to PNG.
Four real bugs (clipped progress column, overflowing footer, unreachable dialog
buttons, blank dropdowns) were only visible in a rendered image, not in
`tmux capture-pane` text.

---

## 6. Design rules for the UI

**Palette rule:** *the running row is the only luminous thing on screen, and warmth
always means attention.* A queue runs for days, so most rows are idle or finished;
giving every status an equally bright hue buries the one row that matters. Settled
statuses are low-chroma; warm hues (held, missing-files, failed, cancelled, stale)
mean a human is needed. All colour lives in `theme.py` — the TCSS pulls from the
registered themes so Textual's own widgets (footer, toasts, modals, Select overlays)
stay in palette.

**No emoji.** Emoji-presentation codepoints (`⚠ ⏸ 🗑`) render double-width in some
terminals and single in others, silently shifting every column after them. Glyphs
come from the geometric/dingbat ranges only.

**Every action has both a key and a click.** Nothing keyboard-only. Secondary
bindings are `show=False` so the footer fits one line.

**Textual gotchas already hit:**
- `width: auto` measures at compose time — a label that grows later gets clipped
  (hence `"all 0"` initial chip labels + `refresh(layout=True)`)
- a `Select` is compound; collapsing only the outer widget hides the value — style
  `SelectCurrent` too
- `height: 1` + `padding-top: 1` pushes text out of its own box; use `margin`
- `DataTable` has no flexible columns, so `_build_columns` recomputes on resize
- `RichLog` scrolls itself; wrapping it in a `VerticalScroll` nests scrollbars

---

## 7. Known gaps and next steps

**Small, well-defined:**
- Drag-to-reorder rows. Deliberately not done: `DataTable` has no native row drag and
  faking it is fragile. Currently select-then-`▲`/`▼`/`run next`.
- Header click-to-sort. Not implemented **on purpose** — the table is in queue order
  because that order *is* the run order.
- The right-click menu and the splitter drag have no automated coverage (both
  manually verified).
- `demo.sh` exists as a dev fixture; the user explicitly did not want a fake
  scheduler as a feature. Fine to delete.

**Worth doing:**
- A `--watch`/read-only mode that hides the mutating toolbar, for sharing a view.
- Show the wave number / ETA. The orchestrator logs `Wave 5/14`; parsing that from
  the log tail would give a far better progress signal than chunk counts alone.
- `retry` currently clears the verdict and unholds. Consider `retry --all-failed`.
- The `libraries` list in `dump` is best-effort (alias table + libraries already
  referenced). A library never used and not aliased won't appear in the add dialog.

**Cluster-side context that shapes the work:**
- `cpu-queue` is **Spot**, single subnet/AZ, `MaxCount: 33`, four 32-vCPU instance
  types. Deployed workers use `--cpus-per-task=8` → 4 tasks/node → **~132 concurrent
  tasks max**, so *reducing `wave_size` does not reduce peak node demand*. Expect
  `InsufficientInstanceCapacity` stalls; ParallelCluster resets after 600s and the
  driver waits through it correctly.
- `run-ersilia-wave-job.sh` says `--cpus-per-task=10` in the repo but the deployed
  copy is `8`. Redeploying that file silently cuts packing by 25%. See
  `../HANDOFF.md`. A `cpus=N` queue flag **overrides that directive** on the sbatch
  command line, so a job with `cpus=10` gets 10 even though the deployed default is
  8 — which is the point (explicit beats drifted), but it means `cpus=` is not a way
  to ask for "whatever the default is". Omit the flag for that.
- Raising `cpus` costs throughput proportionally: at `cpus=8` the partition tops out
  around 132 concurrent tasks, at `cpus=32` it is 33. Use it on models that OOM, not
  as a general setting.
- FSx is scratch and holds ≤1 wave; S3 is the durable store. Progress *is* the object
  count in S3, which is why every "resume" works and why nothing here is destructive.

---

## 8. Deploying

The bash layer must be synced; the TUI is normally `pip install -e` on the laptop and
needs nothing on the cluster.

```bash
# laptop → S3
aws s3 sync scripts/large_library_scripts/scheduler/ \
  s3://ai2050-ersilia-cluster/scripts/large_library_scripts/scheduler/
# head node → /shared
aws s3 sync s3://ai2050-ersilia-cluster/scripts/large_library_scripts/scheduler/ \
  /shared/scripts/large_library_scripts/scheduler/ && \
  chmod +x /shared/scripts/large_library_scripts/scheduler/*.sh
```

Safe while a driver runs — a running bash script has already loaded its code. But:
**`sched-ctl.sh` changes take effect immediately** (fresh process per call), while
**`run-model-queue.sh` changes need a driver restart**. Say which one you changed.

Never add `--delete` to that sync: live queue files live in the same directory.

Verify a sync landed rather than assuming — a partial sync has bitten twice:

```bash
grep -c ORDER\ MATTERS run-model-queue.sh   # 1
grep -c QUEUE_LOCK_DEPTH scheduler-lib.sh   # 5
grep -c emit_counts sched-ctl.sh            # 2
grep -c CPUS_PER_TASK run-model-queue.sh    # 4
grep -c is_valid_cpus scheduler-lib.sh      # 2
```

**Two deploy targets, not one.** The per-job `cpus` feature spans both: the
scheduler reads the flag, but the thing that turns it into `--cpus-per-task` is
`submit-{ersilia,singularity}-waves.sh`, which live **one directory up** and deploy
to `/shared/scripts/large_library_scripts/` (see `../HANDOFF.md`). Sync only
`scheduler/` and `cpus=N` is parsed, validated, logged, shown in the TUI — and
silently ignored at `sbatch`, because the old orchestrator does not read
`CPUS_PER_TASK`. Verify the other half landed too:

```bash
grep -c CPUS_PER_TASK /shared/scripts/large_library_scripts/submit-ersilia-waves.sh  # 7
```

Restarting the driver:

```bash
tmux attach -t scheduler   # Ctrl-C  (now kills the orchestrator too)
rmdir /shared/logs/scheduler/.lock 2>/dev/null
S3_BUCKET=ai2050-ersilia-cluster ./start-scheduler-tmux.sh <queue file>
```

Watch startup for `WARNING: a wave orchestrator is ALREADY RUNNING` (an orphan you
must kill) and `reclaimed interrupted job:` (expected, resumes from S3).

---

## 9. Environment traps

- **The laptop's `python3` is not fixed.** The `ersilia` conda env has no Textual;
  anaconda **base** (3.13) does. Cost us a confusing failure — check
  `python3 -c "import textual"` before believing an ImportError.
- **Do not touch `/shared/python39`.** Built on AL2 against OpenSSL 1.0, `import ssl`
  fails on AL2023, and the AL2 cluster depends on it unchanged. Head-node TUI use
  gets its own venv via `setup-tui-venv.sh`.
- **`pkill -f <pattern>` matches your own script's text.** It killed the test shell
  twice. Match on an exact process name or a recorded PID file instead.
- **Mouse in tmux** needs `tmux set -g mouse on`; the head-node launcher warns.
