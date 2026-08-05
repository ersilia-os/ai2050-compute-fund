"""Command-line entry point for ``scheduler-tui``."""

from __future__ import annotations

import argparse
import sys
from typing import List, Optional

from .runner import DEFAULT_REMOTE_CTL, RunnerError, build_runner

EPILOG = """\
examples:
  scheduler-tui --host ai2050-head        drive the cluster's scheduler from here
  scheduler-tui                           run on the head node itself, in tmux
  scheduler-tui --log-dir /tmp/schedtest  point at a test instance

Nothing needs to be installed on the cluster beyond the bash scheduler itself:
this client only ever runs `sched-ctl.sh`.
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="scheduler-tui",
        description="Terminal dashboard for the Ersilia wave scheduler.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--host",
        help="SSH to this host and run sched-ctl.sh there (default: $SCHEDULER_HOST, "
             "else everything runs locally)",
    )
    parser.add_argument(
        "--ctl",
        help=f"path to sched-ctl.sh on the target (default: $SCHEDULER_CTL, else "
             f"{DEFAULT_REMOTE_CTL}, else the copy next to this checkout)",
    )
    parser.add_argument(
        "--log-dir",
        help="scheduler LOG_DIR to inspect (default: $LOG_DIR, else the ctl default)",
    )
    parser.add_argument(
        "--queue-file",
        help="queue file to edit (default: discovered from the running driver)",
    )
    parser.add_argument("--s3-bucket", help="override S3_BUCKET for ctl calls")
    parser.add_argument(
        "--refresh",
        type=float,
        default=None,
        metavar="SECONDS",
        help="refresh interval (default: 2 locally, 5 over SSH)",
    )
    parser.add_argument(
        "--ssh-opt",
        action="append",
        default=[],
        metavar="OPT",
        help="extra ssh argument, repeatable (e.g. --ssh-opt -p --ssh-opt 2222)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the transport and print one snapshot summary, then exit "
             "(no UI — useful for debugging an SSH setup)",
    )
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)

    runner = build_runner(
        host=args.host,
        ctl=args.ctl,
        log_dir=args.log_dir,
        queue_file=args.queue_file,
        s3_bucket=args.s3_bucket,
        ssh_opts=args.ssh_opt,
    )

    refresh = args.refresh
    if refresh is None:
        # Over SSH each tick is a round-trip; locally it is a fork. Pace accordingly.
        refresh = 5.0 if args.host or runner.location != "local" else 2.0

    if args.check:
        return _check(runner)

    # Imported here so --check and --help work even if Textual is missing.
    from .app import SchedulerTUI

    SchedulerTUI(runner, refresh_interval=refresh).run()
    return 0


def _check(runner) -> int:
    from .model import parse_dump

    print(f"transport : {runner.location}")
    print(f"ctl       : {runner.ctl}")
    try:
        text = runner.dump()
    except RunnerError as exc:
        print(f"FAILED    : {exc}", file=sys.stderr)
        return 1
    snap = parse_dump(text)
    if snap.error:
        print(f"FAILED    : {snap.error}", file=sys.stderr)
        return 1
    print(f"driver    : {snap.driver_state}"
          + (f" (pid {snap.driver_pid})" if snap.driver_alive else ""))
    print(f"queue     : {snap.queue_file}")
    print(f"jobs      : {len(snap.jobs)}  {snap.counts()}")
    print(f"libraries : {len(snap.libraries)}")
    for job in snap.jobs:
        print(f"  {job.pos:>3} {job.model:<20} {job.status:<10} "
              f"{job.done}/{job.total} ({job.pct}%)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
