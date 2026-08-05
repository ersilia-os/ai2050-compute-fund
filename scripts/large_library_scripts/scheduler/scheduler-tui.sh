#!/bin/bash
# =============================================================================
# Launch the scheduler TUI on the HEAD NODE (the fallback path).
# =============================================================================
# The primary way to use the TUI is from your laptop:
#     scheduler-tui --host <head-node>
# which needs nothing installed on the cluster. This script is for when you are
# already SSH'd in and want the dashboard right there next to the driver.
#
# It finds a Python that has Textual, in this order:
#   1. $SCHEDULER_TUI_PYTHON            (explicit override)
#   2. /shared/venvs/scheduler-tui/bin/python
#   3. python3 on PATH
# and refuses to touch /shared/python39 — on AL2023 that build's `ssl` is broken,
# and the AL2 cluster depends on it as-is.
#
# If no Python has Textual, it says how to build the venv and falls back to the
# plain-text status table, so you always get *a* view.
#
# Usage: scheduler-tui.sh [args passed through to scheduler-tui]
# Env:   LOG_DIR, QUEUE_FILE, S3_BUCKET  (as for the rest of the scheduler)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="/shared/venvs/scheduler-tui/bin/python"

# The package lives one directory up in the repo, or beside us once deployed.
for cand in "${SCRIPT_DIR}/../scheduler-tui" \
            "/shared/scripts/large_library_scripts/scheduler-tui"; do
    [ -d "$cand" ] && { PKG_DIR="$(cd "$cand" && pwd)"; break; }
done

has_textual() { "$1" -c 'import textual' >/dev/null 2>&1; }

PY=""
for cand in "${SCHEDULER_TUI_PYTHON:-}" "$VENV_PY" "$(command -v python3 2>/dev/null)"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    if has_textual "$cand"; then PY="$cand"; break; fi
done

if [ -z "$PY" ]; then
    echo "No Python with Textual found, so the TUI cannot start here." >&2
    echo "" >&2
    echo "Build the dedicated venv once (needs head-node internet access):" >&2
    echo "  ${SCRIPT_DIR}/setup-tui-venv.sh" >&2
    echo "" >&2
    echo "Or drive it from your laptop instead, which needs nothing on the cluster:" >&2
    echo "  pipx install <repo>/scripts/large_library_scripts/scheduler-tui" >&2
    echo "  scheduler-tui --host \$(hostname -s)" >&2
    echo "" >&2
    echo "Falling back to the plain status table:" >&2
    echo "" >&2
    exec "${SCRIPT_DIR}/scheduler-status.sh"
fi

# Textual needs mouse reporting from the terminal. Inside tmux that is off by
# default, so clicks would do nothing and the cause would be invisible.
if [ -n "${TMUX:-}" ]; then
    if [ "$(tmux show-options -gv mouse 2>/dev/null)" != "on" ]; then
        echo "NOTE: tmux mouse mode is off, so clicking will not work." >&2
        echo "      Enable it with:  tmux set -g mouse on" >&2
        echo "      (keyboard shortcuts work either way)" >&2
        echo "" >&2
        sleep 2
    fi
fi

# Run from the package directory when it is not installed, so `python -m` finds it.
if "$PY" -c 'import scheduler_tui' >/dev/null 2>&1; then
    exec "$PY" -m scheduler_tui "$@"
elif [ -n "${PKG_DIR:-}" ]; then
    cd "$PKG_DIR" || exit 1
    exec "$PY" -m scheduler_tui "$@"
else
    echo "ERROR: the scheduler_tui package is not importable and its source dir" >&2
    echo "       was not found next to this script. Deploy scheduler-tui/ too:" >&2
    echo "       aws s3 sync s3://<bucket>/scripts/large_library_scripts/scheduler-tui/ \\" >&2
    echo "           /shared/scripts/large_library_scripts/scheduler-tui/" >&2
    exit 1
fi
