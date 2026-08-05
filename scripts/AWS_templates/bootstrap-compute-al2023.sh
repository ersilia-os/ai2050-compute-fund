#!/bin/bash
# ==========================================================================
# Bootstrap for COMPUTE NODES on the AL2023 GPU cluster (ai2050-cluster-al2023)
# ==========================================================================
# Compute nodes are in a PRIVATE subnet (no internet) and consume the toolchain
# from the shared EFS that the AL2 cluster populated:
#   /shared/apptainer   (Apptainer, built on AL2)
#   /shared/python39     (Python 3.9 + ersilia_apptainer, built on AL2)
#   /shared/sif-files    (model SIFs)
#
# DO NOT edit the AL2 cluster's bootstrap-compute.sh for AL2023 — both configs
# would share one S3 object and you'd break the live AL2 compute nodes. This is
# a SEPARATE file referenced only by cluster-config-al2023.yaml.
#
# Key differences vs the AL2 bootstrap-compute.sh:
#   * NO `set -e` — an AL2-built binary that fails its version check on AL2023
#     must NOT abort node configuration (that would fail the whole build/scale).
#   * dnf instead of yum; no from-source Apptainer build (no internet here).
#   * Prefers AL2023-rebuilt toolchain paths if present, else falls back to the
#     AL2 ones with a warning.
# ==========================================================================
set -uo pipefail   # deliberately NOT -e: bootstrap must be resilient

echo "=========================================="
echo "COMPUTE NODE Bootstrap (AL2023)"
echo "Node: $(hostname)  Date: $(date)"
echo "No internet access — using shared toolchain from /shared"
echo "=========================================="

S3_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"

# --------------------------------------------------------------------------
# Wait for the shared EFS to mount (it holds the toolchain)
# --------------------------------------------------------------------------
TIMEOUT=120; ELAPSED=0
while [ ! -d /shared/apptainer ] && [ ! -d /shared/apptainer-al2023 ] && [ $ELAPSED -lt $TIMEOUT ]; do
    echo "Waiting for /shared to mount... (${ELAPSED}s)"
    sleep 5; ELAPSED=$((ELAPSED + 5))
done

# --------------------------------------------------------------------------
# Resolve Apptainer: prefer an AL2023 rebuild, fall back to the AL2 build.
# --------------------------------------------------------------------------
APPTAINER_BIN=""
if [ -x /shared/apptainer-al2023/bin/apptainer ]; then
    APPTAINER_BIN=/shared/apptainer-al2023/bin/apptainer
    echo "✓ Using AL2023 Apptainer: $APPTAINER_BIN"
elif [ -x /shared/apptainer/bin/apptainer ]; then
    APPTAINER_BIN=/shared/apptainer/bin/apptainer
    echo "⚠ Using AL2-built Apptainer on AL2023: $APPTAINER_BIN"
    echo "  If jobs fail with loader/libseccomp/openssl errors, rebuild into"
    echo "  /shared/apptainer-al2023 (keeps the AL2 cluster's binary intact)."
else
    echo "✗ No Apptainer found in /shared — GPU jobs will fail until one is provided."
fi

# Non-fatal version probe (never aborts the bootstrap)
if [ -n "$APPTAINER_BIN" ]; then
    "$APPTAINER_BIN" --version \
        || echo "⚠ '$APPTAINER_BIN --version' failed — likely AL2->AL2023 ABI; rebuild needed."
fi

# --------------------------------------------------------------------------
# squashfuse: required for apptainer to MOUNT .sif images unprivileged on
# AL2023. AL2023 base repos don't ship squashfuse and there's no EPEL, so we
# ship binaries we built once on the AL2023 head node (statically linked
# against libsquashfuse; only need libfuse3/liblz4/libzstd, all on the AMI).
# Installed into /usr/local/bin so it's on the default PATH even under sbatch
# (which does NOT source /etc/profile.d). Without this, apptainer fails with
# "squashfuse not found / container creation failed".
# --------------------------------------------------------------------------
if [ ! -x /usr/local/bin/squashfuse ] && [ -d /shared/tools-al2023/bin ]; then
    echo "Installing squashfuse from /shared/tools-al2023/bin ..."
    cp -a /shared/tools-al2023/bin/squashfuse /shared/tools-al2023/bin/squashfuse_ll /usr/local/bin/ 2>/dev/null \
        && chmod 755 /usr/local/bin/squashfuse /usr/local/bin/squashfuse_ll \
        && echo "✓ squashfuse installed: $(/usr/local/bin/squashfuse --help 2>&1 | head -1)" \
        || echo "⚠ squashfuse copy failed — SIF mounts will fail on this node."
elif [ -x /usr/local/bin/squashfuse ]; then
    echo "✓ squashfuse already present: /usr/local/bin/squashfuse"
else
    echo "✗ /shared/tools-al2023/bin missing squashfuse — SIF mounts will fail."
fi

# --------------------------------------------------------------------------
# Resolve the Python/ersilia_apptainer toolchain the same way
# --------------------------------------------------------------------------
PY_PREFIX=""
if [ -x /shared/python39-al2023/bin/python3.9 ]; then
    PY_PREFIX=/shared/python39-al2023
    echo "✓ Using AL2023 Python: $PY_PREFIX"
elif [ -x /shared/python39/bin/python3.9 ]; then
    PY_PREFIX=/shared/python39
    echo "⚠ Using AL2-built Python on AL2023: $PY_PREFIX (watch for openssl/ssl import errors)"
fi

if [ -n "$PY_PREFIX" ]; then
    "$PY_PREFIX/bin/python3.9" -c "import ssl; print('ssl OK:', ssl.OPENSSL_VERSION)" \
        || echo "⚠ Python ssl import failed — classic AL2->AL2023 OpenSSL mismatch; rebuild needed."
fi

# --------------------------------------------------------------------------
# System Python 3 (for anything that shells out to a plain python3).
# AL2023 ships python3; dnf is the native package manager.
# --------------------------------------------------------------------------
if ! command -v python3 &>/dev/null; then
    echo "Installing system python3 via dnf..."
    dnf install -y python3 python3-pip || echo "⚠ dnf python3 install failed (non-fatal)"
fi

# --------------------------------------------------------------------------
# Environment: put the resolved toolchain on PATH for jobs.
# --------------------------------------------------------------------------
cat > /etc/profile.d/cluster-env.sh << EOF
# AL2023 compute node environment
export SHARED_DIR=/shared
export SIF_DIR=/shared/sif-files
export S3_BUCKET=${S3_BUCKET}
export PATH=${PY_PREFIX:+$PY_PREFIX/bin:}${APPTAINER_BIN:+$(dirname "$APPTAINER_BIN"):}\$PATH
export APPTAINER_CACHEDIR=/tmp/apptainer-cache
mkdir -p \$APPTAINER_CACHEDIR
EOF
chmod 644 /etc/profile.d/cluster-env.sh

mkdir -p /tmp/job-scratch && chmod 1777 /tmp/job-scratch

# --------------------------------------------------------------------------
# Verification (informational only)
# --------------------------------------------------------------------------
echo "----- verification -----"
command -v python3 &>/dev/null && echo "✓ system python3: $(python3 --version)" || echo "✗ no system python3"
[ -n "$APPTAINER_BIN" ] && echo "✓ apptainer: $APPTAINER_BIN" || echo "✗ no apptainer"
[ -d /shared ] && echo "✓ /shared mounted" || echo "⚠ /shared NOT mounted"
[ -d /fsx ] && echo "✓ /fsx mounted" || echo "⚠ /fsx NOT mounted"
aws s3 ls s3://$S3_BUCKET/ --region eu-north-1 &>/dev/null \
    && echo "✓ S3 access working" || echo "⚠ S3 access failed"
echo "------------------------"

echo "AL2023 compute node bootstrap complete: $(date)"
