#!/bin/bash
# =============================================================================
# Build the head-node venv for the scheduler TUI (one-off).
# =============================================================================
# Creates /shared/venvs/scheduler-tui from the head node's SYSTEM python3 and
# installs the scheduler-tui package (which pulls in Textual).
#
# Why a separate path: /shared/python39 was built on AL2 against OpenSSL 1.0, so
# `import ssl` fails on AL2023 — and it cannot be rebuilt in place because the
# live AL2 cluster needs it as it is. A venv off the system python3 links the
# platform's own OpenSSL and stays independent of that whole problem.
#
# Only needed if you want the TUI ON the head node. Driving it from your laptop
# (`scheduler-tui --host <head-node>`) needs nothing here.
#
# Usage: setup-tui-venv.sh [venv_dir]
# =============================================================================

set -euo pipefail

VENV="${1:-/shared/venvs/scheduler-tui}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for cand in "${SCRIPT_DIR}/../scheduler-tui" \
            "/shared/scripts/large_library_scripts/scheduler-tui"; do
    if [ -f "${cand}/pyproject.toml" ]; then PKG_DIR="$(cd "$cand" && pwd)"; break; fi
done
if [ -z "${PKG_DIR:-}" ]; then
    echo "ERROR: cannot find the scheduler-tui package (looked next to this script" >&2
    echo "       and in /shared/scripts/large_library_scripts/scheduler-tui)." >&2
    exit 1
fi

SYS_PY="$(command -v python3 || true)"
[ -n "$SYS_PY" ] || { echo "ERROR: no python3 on PATH." >&2; exit 1; }

# Textual needs 3.9+; so does the package metadata.
if ! "$SYS_PY" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
    echo "ERROR: $SYS_PY is $("$SYS_PY" -V 2>&1); Textual needs Python >= 3.9." >&2
    exit 1
fi
# Guard against someone pointing PATH at the broken shared build.
if ! "$SYS_PY" -c 'import ssl' >/dev/null 2>&1; then
    echo "ERROR: $SYS_PY cannot 'import ssl' — pip will not be able to fetch anything." >&2
    echo "       This is the /shared/python39-on-AL2023 problem; use the OS python3." >&2
    exit 1
fi

echo "System python : $SYS_PY  ($("$SYS_PY" -V 2>&1))"
echo "Package       : $PKG_DIR"
echo "Venv          : $VENV"
echo ""

mkdir -p "$(dirname "$VENV")"
"$SYS_PY" -m venv "$VENV"
"${VENV}/bin/python" -m pip install --upgrade pip >/dev/null
"${VENV}/bin/python" -m pip install "$PKG_DIR"

echo ""
echo "Done. Launch it with:"
echo "  ${SCRIPT_DIR}/scheduler-tui.sh"
echo ""
echo "Inside tmux, enable mouse support once so clicking works:"
echo "  tmux set -g mouse on"
