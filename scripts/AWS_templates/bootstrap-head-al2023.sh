#!/bin/bash
# ==========================================================================
# MINIMAL head-node bootstrap for the AL2023 cluster (ai2050-cluster-al2023)
# ==========================================================================
# This cluster mounts the EXISTING shared EFS (fs-0ac858f5db4a1fc9e), which is
# already fully populated by the old AL2 cluster with:
#   /shared/python39      (Python 3.9.18, built from source)
#   /shared/apptainer     (Apptainer 1.2.5, built from source)
#   /shared/scripts       (all helper scripts)
#   /shared/sif-files     (model SIFs)
#
# Therefore this bootstrap does NOT recreate ANY of that — it only wires up
# PATH/env. Recreating /shared/scripts here would CLOBBER the scripts the old
# cluster is still using (both clusters share the same EFS).
# ==========================================================================
set -e
set -x

echo "=========================================="
echo "MINIMAL HEAD BOOTSTRAP (AL2023)"
echo "Node: $(hostname)  Date: $(date)"
echo "=========================================="

# --------------------------------------------------------------------------
# AWS CLI v2 ships with AL2023, but install if somehow missing
# --------------------------------------------------------------------------
if ! command -v aws &>/dev/null; then
    echo "aws CLI not found — installing v2..."
    cd /tmp
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
    unzip -q awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip
fi
aws --version

# --------------------------------------------------------------------------
# Wait for the shared EFS to mount (it holds the toolchain)
# --------------------------------------------------------------------------
TIMEOUT=120
ELAPSED=0
while [ ! -d /shared/python39 ] && [ $ELAPSED -lt $TIMEOUT ]; do
    echo "Waiting for /shared to mount... (${ELAPSED}s)"
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ ! -d /shared/python39 ]; then
    echo "WARNING: /shared/python39 not found after ${TIMEOUT}s — EFS may not be mounted."
fi

# --------------------------------------------------------------------------
# Environment: point at the EXISTING shared toolchain. Create nothing else.
# --------------------------------------------------------------------------
cat > /etc/profile.d/cluster-env.sh << 'EOF'
export PATH=/shared/python39/bin:/shared/apptainer/bin:$PATH
export SHARED_DIR=/shared
export SIF_DIR=/shared/sif-files
export CLUSTER_SCRIPTS=/shared/scripts
export CLUSTER_LOGS=/shared/logs
export S3_BUCKET=ai2050-ersilia-cluster

alias list-models='ls -lh /shared/sif-files/'
alias download-model='/shared/scripts/download-ersilia-model.sh'
alias sync-models='/shared/scripts/sync-sif-from-s3.sh'
alias test-cluster='/shared/scripts/test-cluster.sh'
EOF
chmod 644 /etc/profile.d/cluster-env.sh

mkdir -p /shared/logs 2>/dev/null || true

# --------------------------------------------------------------------------
# Quick sanity check (informational — does NOT fail the bootstrap).
# If Python/Apptainer were compiled on AL2, they may need rebuilding on AL2023
# (see the ABI note in the deployment chat). Rebuild into SEPARATE paths
# (e.g. /shared/python39-al2023) so the old cluster's binaries stay intact.
# --------------------------------------------------------------------------
echo "----- toolchain sanity check (AL2 -> AL2023 ABI) -----"
/shared/python39/bin/python3.9 --version || echo "⚠ python3.9 failed to run — likely needs rebuild on AL2023"
/shared/python39/bin/python3.9 -c "import ssl; print('ssl OK:', ssl.OPENSSL_VERSION)" \
    || echo "⚠ Python ssl/openssl module failed — classic AL2->AL2023 OpenSSL mismatch; rebuild needed"
/shared/apptainer/bin/apptainer --version || echo "⚠ apptainer failed to run — likely needs rebuild on AL2023"
echo "------------------------------------------------------"

echo "=========================================="
echo "Minimal head bootstrap complete: $(date)"
echo "=========================================="
