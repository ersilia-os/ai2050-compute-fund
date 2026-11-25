#!/bin/bash
# Bootstrap script for HEAD NODE (SIMPLIFIED - NO APPTAINER)
# Head node has internet access to download packages

set -e
set -x

echo "=========================================="
echo "HEAD NODE Bootstrap Script (SIMPLIFIED)"
echo "Node: $(hostname)"
echo "Date: $(date)"
echo "=========================================="

# Update system
echo "Updating system packages..."
yum update -y

# ==========================================
# Install Python and pip
# ==========================================
echo "Installing Python 3 and pip..."
yum install -y python3 python3-pip git

# Upgrade pip
python3 -m pip install --upgrade pip

# ==========================================
# Install AWS CLI v2 (if not present)
# ==========================================
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI v2..."
    cd /tmp
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip
fi

aws --version

# ==========================================
# Create shared directories
# ==========================================
echo "Creating shared directory structure..."

mkdir -p /shared/sif-files
mkdir -p /shared/scripts
mkdir -p /shared/data
mkdir -p /shared/logs
mkdir -p /shared/output

chmod 755 /shared/sif-files
chmod 755 /shared/scripts
chmod 755 /shared/data
chmod 755 /shared/logs
chmod 755 /shared/output

chown -R ec2-user:ec2-user /shared/sif-files
chown -R ec2-user:ec2-user /shared/scripts
chown -R ec2-user:ec2-user /shared/logs
chown -R ec2-user:ec2-user /shared/output

# ==========================================
# Create helper scripts
# ==========================================

# !! OUT OF DATE (2026-11-23): model SIFs now come only from s3://models-sif. The live
# !! download-ersilia-model.sh, sync-sif-from-s3.sh and submit-ersilia-batch.sh are the
# !! standalone copies in scripts/AWS_templates/. If this cluster is ever rebuilt, copy
# !! those over /shared/scripts/ instead of trusting the heredocs below.

# Script 1: Download Ersilia model (S3 ONLY - no DockerHub)
cat > /shared/scripts/download-ersilia-model.sh << 'DOWNLOAD_SCRIPT'
#!/bin/bash
# Download Ersilia model SIF file from S3
# Usage: download-ersilia-model.sh <model_id>

MODEL_ID=$1
S3_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"
SIF_PATH="/shared/sif-files/${MODEL_ID}.sif"

if [ -z "$MODEL_ID" ]; then
    echo "Usage: $0 <model_id>"
    echo "Example: $0 eos2r5a"
    exit 1
fi

echo "=========================================="
echo "Ersilia Model: $MODEL_ID"
echo "=========================================="

# Check if already exists
if [ -f "$SIF_PATH" ]; then
    echo "✓ Model already exists: $SIF_PATH"
    echo "File size: $(du -h $SIF_PATH | cut -f1)"
    exit 0
fi

# Download from S3
echo "Downloading from S3..."

if aws s3 ls s3://$S3_BUCKET/sif-files/${MODEL_ID}.sif 2>/dev/null; then
    echo "✓ Found in S3! Downloading..."
    
    if aws s3 cp s3://$S3_BUCKET/sif-files/${MODEL_ID}.sif $SIF_PATH; then
        echo "✓ Downloaded from S3: $SIF_PATH"
        echo "File size: $(du -h $SIF_PATH | cut -f1)"
        ls -lh $SIF_PATH
        exit 0
    else
        echo "✗ Failed to download from S3"
        exit 1
    fi
else
    echo "✗ Model not found in S3: s3://$S3_BUCKET/sif-files/${MODEL_ID}.sif"
    echo ""
    echo "Available models in S3:"
    aws s3 ls s3://$S3_BUCKET/sif-files/ | grep "\.sif$" || echo "  (none found)"
    echo ""
    echo "Please upload ${MODEL_ID}.sif to S3 first:"
    echo "  aws s3 cp ${MODEL_ID}.sif s3://$S3_BUCKET/sif-files/"
    exit 1
fi
DOWNLOAD_SCRIPT

chmod +x /shared/scripts/download-ersilia-model.sh

# Script 2: Sync SIF from S3
cat > /shared/scripts/sync-sif-from-s3.sh << 'SYNC_SCRIPT'
#!/bin/bash
S3_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"

echo "Syncing SIF files from S3..."
aws s3 sync s3://$S3_BUCKET/sif-files/ /shared/sif-files/ --exclude "*" --include "*.sif"
echo "✓ Sync complete!"
ls -lh /shared/sif-files/*.sif 2>/dev/null || echo "No SIF files found"
SYNC_SCRIPT

chmod +x /shared/scripts/sync-sif-from-s3.sh

# Script 3: Test cluster
cat > /shared/scripts/test-cluster.sh << 'TEST_SCRIPT'
#!/bin/bash
echo "=========================================="
echo "Cluster Test Script"
echo "=========================================="

echo "Test 1: Slurm"
sinfo &> /dev/null && echo "✓ Slurm running" || echo "✗ Slurm failed"

echo "Test 2: Storage"
[ -d /shared ] && echo "✓ /shared exists" || echo "✗ /shared missing"
[ -d /fsx ] && echo "✓ /fsx exists" || echo "✗ /fsx missing"

echo "Test 3: Python"
python3 --version &> /dev/null && echo "✓ Python: $(python3 --version)" || echo "✗ Python missing"

echo "Test 4: S3"
aws s3 ls &> /dev/null && echo "✓ S3 access working" || echo "✗ S3 failed"

echo ""
echo "NOTE: Apptainer not installed in simplified bootstrap"
echo "To install Apptainer, run /shared/scripts/install-apptainer.sh"

echo "=========================================="
TEST_SCRIPT

chmod +x /shared/scripts/test-cluster.sh

# Script 4: Run Ersilia job (supports both single and array job modes)
cat > /shared/scripts/run-ersilia-job.sh << 'RUN_SCRIPT'
#!/bin/bash
#SBATCH --job-name=ersilia
#SBATCH --partition=cpu-queue
#SBATCH --nodes=1
#SBATCH --cpus-per-task=2
#SBATCH --time=02:00:00
#SBATCH --output=/shared/logs/ersilia-%A_%a.out
#SBATCH --error=/shared/logs/ersilia-%A_%a.err

# Process a single chunk file with an Ersilia model
#
# Array job mode (used by submit-ersilia-batch.sh):
#   sbatch --array=0-N run-ersilia-job.sh <model_id> <chunk_list_file> <output_dir>
#
# Single job mode:
#   sbatch run-ersilia-job.sh <model_id> <input_file> <output_file>

MODEL_ID=$1

if [ -n "$SLURM_ARRAY_TASK_ID" ]; then
    # Array job: pick chunk by task index
    CHUNK_LIST=$2
    OUTPUT_BASE=$3
    INPUT_FILE=$(sed -n "$((SLURM_ARRAY_TASK_ID+1))p" "$CHUNK_LIST")
    CHUNK_NUM=$(basename "$INPUT_FILE" .csv | grep -oP '\d+$')
    OUTPUT_FILE="${OUTPUT_BASE}/${MODEL_ID}_results_${CHUNK_NUM}.csv"
else
    # Single job: paths passed directly
    INPUT_FILE=$2
    OUTPUT_FILE=$3
fi

echo "=========================================="
echo "Ersilia Job"
echo "=========================================="
echo "Job ID: $SLURM_JOB_ID  Array task: ${SLURM_ARRAY_TASK_ID:-N/A}"
echo "Node: $(hostname)"
echo "Date: $(date)"
echo "Model: $MODEL_ID"
echo "Input: $INPUT_FILE"
echo "Output: $OUTPUT_FILE"
echo "=========================================="

# Verify SIF file exists
SIF_FILE="/shared/sif-files/${MODEL_ID}.sif"
if [ ! -f "$SIF_FILE" ]; then
    echo "ERROR: SIF file not found: $SIF_FILE"
    echo "Please download it first: /shared/scripts/download-ersilia-model.sh $MODEL_ID"
    exit 1
fi

# Verify input file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: Input file not found: $INPUT_FILE"
    exit 1
fi

# Create output directory
OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
mkdir -p "$OUTPUT_DIR"

# Copy input to local /tmp to avoid FSx Lustre visibility issues in post-processing
LOCAL_INPUT="/tmp/$(basename $INPUT_FILE)"
cp "$INPUT_FILE" "$LOCAL_INPUT"

# Run ersilia-apptainer
echo "Starting ersilia-apptainer..."
echo "Processing $(wc -l < $LOCAL_INPUT) molecules..."

/shared/python39/bin/ersilia_apptainer \
    --sif "$SIF_FILE" \
    --input "$LOCAL_INPUT" \
    --output "$OUTPUT_FILE" --verbose

rm -f "$LOCAL_INPUT"

# Check if output was created
if [ -f "$OUTPUT_FILE" ]; then
    echo "✓ Success! Output: $OUTPUT_FILE"
    echo "Output size: $(wc -l < $OUTPUT_FILE) lines"

    # Upload to S3 if S3_BUCKET is set (preserve directory structure)
    if [ -n "$S3_BUCKET" ]; then
        RELATIVE_PATH=$(echo "$OUTPUT_FILE" | sed 's|^/fsx/output/||')
        S3_OUTPUT="s3://$S3_BUCKET/output/$RELATIVE_PATH"
        aws s3 cp "$OUTPUT_FILE" "$S3_OUTPUT"
        echo "✓ Uploaded to: $S3_OUTPUT"
    fi
else
    echo "✗ ERROR: Output file was not created"
    exit 1
fi

echo "=========================================="
echo "Job completed: $(date)"
echo "=========================================="
RUN_SCRIPT

chmod +x /shared/scripts/run-ersilia-job.sh

cat > /shared/scripts/submit-ersilia-batch.sh << 'BATCH_SCRIPT'
#!/bin/bash
# Submit Ersilia batch jobs for pre-chunked input files
# Usage: submit-ersilia-batch.sh <model_id> <library_name> [queue]
#
# Expected structure:
#   /fsx/input/<library_name>/chunk_0001.csv
#   /fsx/input/<library_name>/chunk_0002.csv
#   ...
#
# Output structure:
#   /fsx/output/<library_name>/<model_id>/<model_id>_results_0001.csv
#   /fsx/output/<library_name>/<model_id>/<model_id>_results_0002.csv
#   ...

MODEL_ID=$1
LIBRARY_NAME=$2
QUEUE=${3:-cpu-queue}

# Validation
if [ -z "$MODEL_ID" ] || [ -z "$LIBRARY_NAME" ]; then
    echo "Usage: $0 <model_id> <library_name> [queue]"
    echo ""
    echo "Arguments:"
    echo "  model_id      - Ersilia model ID (e.g., eos2r5a)"
    echo "  library_name  - Library folder name (e.g., library_001)"
    echo "  queue         - Optional: test-queue, cpu-queue (default), gpu-queue"
    echo ""
    echo "Expected input structure:"
    echo "  /fsx/input/<library_name>/chunk_0001.csv"
    echo "  /fsx/input/<library_name>/chunk_0002.csv"
    echo "  ..."
    echo ""
    echo "Output structure:"
    echo "  /fsx/output/<library_name>/<model_id>/<model_id>_results_0001.csv"
    echo "  /fsx/output/<library_name>/<model_id>/<model_id>_results_0002.csv"
    echo "  ..."
    echo ""
    echo "Example:"
    echo "  $0 eos2r5a library_001 cpu-queue"
    exit 1
fi

# Define paths
INPUT_DIR="/fsx/input/${LIBRARY_NAME}"
OUTPUT_DIR="/fsx/output/${LIBRARY_NAME}/${MODEL_ID}"

# Check if input directory exists
if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory not found: $INPUT_DIR"
    echo ""
    echo "Please ensure your chunks are uploaded to:"
    echo "  /fsx/input/${LIBRARY_NAME}/chunk_XXXX.csv"
    exit 1
fi

# Check if model SIF exists
if [ ! -f "/shared/sif-files/${MODEL_ID}.sif" ]; then
    echo "ERROR: Model SIF not found: /shared/sif-files/${MODEL_ID}.sif"
    echo "Download it first: /shared/scripts/download-ersilia-model.sh $MODEL_ID"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Find all chunk files (matches both chunk_0001.csv and Library_chunk_000.csv)
CHUNK_FILES=($(ls "$INPUT_DIR"/*.csv 2>/dev/null | grep '_chunk_'))
NUM_CHUNKS=${#CHUNK_FILES[@]}

if [ $NUM_CHUNKS -eq 0 ]; then
    echo "ERROR: No chunk files found in $INPUT_DIR"
    echo "Expected files containing '_chunk_': chunk_0001.csv or LibraryName_chunk_000.csv"
    exit 1
fi

echo "=========================================="
echo "Ersilia Batch Job Submission (Array)"
echo "=========================================="
echo "Model: $MODEL_ID"
echo "Library: $LIBRARY_NAME"
echo "Input directory: $INPUT_DIR"
echo "Output directory: $OUTPUT_DIR"
echo "Number of chunks: $NUM_CHUNKS"
echo "Queue: $QUEUE"
echo ""

# Write chunk list file (one path per line, used by array job tasks)
CHUNK_LIST="${OUTPUT_DIR}/chunk_list.txt"
printf '%s\n' "${CHUNK_FILES[@]}" > "$CHUNK_LIST"
echo "Chunk list written: $CHUNK_LIST"

# Submit as Slurm array job(s)
# Slurm's MaxArraySize=1000 limits both count and max index to 999.
# For larger libraries, split into multiple chunk list files and submit each as 0-N.
MAX_ARRAY_SIZE=1000
ARRAY_IDS=()
BATCH=0
START=0

while [ $START -lt $NUM_CHUNKS ]; do
    END=$(( START + MAX_ARRAY_SIZE - 1 ))
    if [ $END -ge $NUM_CHUNKS ]; then
        END=$(( NUM_CHUNKS - 1 ))
    fi
    BATCH_SIZE=$(( END - START + 1 ))

    # Write a sub-list for this batch (indices will be 0 to BATCH_SIZE-1)
    BATCH_LIST="${OUTPUT_DIR}/chunk_list_batch${BATCH}.txt"
    sed -n "$((START+1)),$((END+1))p" "$CHUNK_LIST" > "$BATCH_LIST"

    ARRAY_ID=$(sbatch \
        --partition="$QUEUE" \
        --array=0-$((BATCH_SIZE-1)) \
        /shared/scripts/run-ersilia-job.sh \
        "$MODEL_ID" \
        "$BATCH_LIST" \
        "$OUTPUT_DIR" \
        2>&1 | grep -oP 'Submitted batch job \K\d+')

    if [ -n "$ARRAY_ID" ]; then
        ARRAY_IDS+=("$ARRAY_ID")
        echo "Submitted array job $ARRAY_ID (chunks ${START}-${END}, batch list: $BATCH_LIST)"
    else
        echo "ERROR: Array job submission failed for chunks ${START}-${END}"
        exit 1
    fi

    START=$(( END + 1 ))
    BATCH=$(( BATCH + 1 ))
done

echo ""
echo "=========================================="
echo "Submission Summary"
echo "=========================================="
echo "Library: $LIBRARY_NAME"
echo "Model: $MODEL_ID"
echo "Total chunks: $NUM_CHUNKS"
echo "Array Job IDs: ${ARRAY_IDS[*]}"
echo ""
echo "Monitor jobs:"
echo "  squeue -u \$USER"
echo "  watch -n 5 'squeue -u \$USER'"
echo ""
echo "Cancel entire library:"
for ID in "${ARRAY_IDS[@]}"; do
    echo "  scancel $ID"
done

echo ""
echo "When complete, merge results:"
echo "  /shared/scripts/merge-results.sh $OUTPUT_DIR ${OUTPUT_DIR}/../${MODEL_ID}_final.csv"
echo ""
echo "Or upload individual results to S3:"
echo "  aws s3 sync $OUTPUT_DIR s3://\$S3_BUCKET/output/${LIBRARY_NAME}/${MODEL_ID}/"
echo "=========================================="

# Save job info
JOB_INFO_FILE="${OUTPUT_DIR}/job_info.txt"
cat > "$JOB_INFO_FILE" << EOF
Library: $LIBRARY_NAME
Model: $MODEL_ID
Input Directory: $INPUT_DIR
Output Directory: $OUTPUT_DIR
Number of Chunks: $NUM_CHUNKS
Queue: $QUEUE
Submitted: $(date)
Array Job ID: $ARRAY_ID
Chunk List: $CHUNK_LIST
EOF

echo "Job info saved: $JOB_INFO_FILE"
BATCH_SCRIPT

chmod +x /shared/scripts/submit-ersilia-batch.sh

# Script 6: Resubmit missing/mismatched chunks
cat > /shared/scripts/resubmit-missing.sh << 'RESUBMIT_SCRIPT'
#!/bin/bash
# Resubmit missing or mismatched chunks for a library/model
# Usage: resubmit-missing.sh <model_id> <library_name> [queue]
#
# Example:
#   resubmit-missing.sh eos4k4f_v1 Enamine_Hit_Locator_460K cpu-queue

MODEL_ID=$1
LIBRARY_NAME=$2
QUEUE=${3:-cpu-queue}

if [ -z "$MODEL_ID" ] || [ -z "$LIBRARY_NAME" ]; then
    echo "Usage: $0 <model_id> <library_name> [queue]"
    echo "Example: $0 eos4k4f_v1 Enamine_Hit_Locator_460K cpu-queue"
    exit 1
fi

INPUT_DIR="/fsx/input/${LIBRARY_NAME}"
OUTPUT_DIR="/fsx/output/${LIBRARY_NAME}/${MODEL_ID}"

if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory not found: $INPUT_DIR"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "=========================================="
echo "Scanning for missing/mismatched chunks"
echo "Library : $LIBRARY_NAME"
echo "Model   : $MODEL_ID"
echo "=========================================="

MISSING_LIST="${OUTPUT_DIR}/chunk_list_missing.txt"
> "$MISSING_LIST"

for INPUT_FILE in $(ls "$INPUT_DIR"/*_chunk_*.csv 2>/dev/null | sort); do
    CHUNK_NUM=$(basename "$INPUT_FILE" .csv | grep -oP '\d+$')
    OUTPUT_FILE="${OUTPUT_DIR}/${MODEL_ID}_results_${CHUNK_NUM}.csv"

    if [ ! -f "$OUTPUT_FILE" ]; then
        echo "  MISSING : chunk_${CHUNK_NUM}"
        echo "$INPUT_FILE" >> "$MISSING_LIST"
    else
        IN_ROWS=$(( $(wc -l < "$INPUT_FILE") - 1 ))
        OUT_ROWS=$(( $(wc -l < "$OUTPUT_FILE") - 1 ))
        if [ "$IN_ROWS" -ne "$OUT_ROWS" ]; then
            echo "  MISMATCH: chunk_${CHUNK_NUM} (input=$IN_ROWS, output=$OUT_ROWS)"
            echo "$INPUT_FILE" >> "$MISSING_LIST"
        fi
    fi
done

NUM_MISSING=$(wc -l < "$MISSING_LIST" | tr -d ' ')

if [ "$NUM_MISSING" -eq 0 ]; then
    echo "All chunks complete for $LIBRARY_NAME / $MODEL_ID"
    rm "$MISSING_LIST"
    exit 0
fi

echo ""
echo "Found $NUM_MISSING chunks to resubmit"

MAX_ARRAY_SIZE=1000
ARRAY_IDS=()
BATCH=0
START=0

while [ $START -lt $NUM_MISSING ]; do
    END=$(( START + MAX_ARRAY_SIZE - 1 ))
    if [ $END -ge $NUM_MISSING ]; then
        END=$(( NUM_MISSING - 1 ))
    fi
    BATCH_SIZE=$(( END - START + 1 ))

    BATCH_LIST="${OUTPUT_DIR}/chunk_list_missing_batch${BATCH}.txt"
    sed -n "$((START+1)),$((END+1))p" "$MISSING_LIST" > "$BATCH_LIST"

    ARRAY_ID=$(sbatch \
        --partition="$QUEUE" \
        --array=0-$((BATCH_SIZE-1)) \
        /shared/scripts/run-ersilia-job.sh \
        "$MODEL_ID" \
        "$BATCH_LIST" \
        "$OUTPUT_DIR" \
        2>&1 | grep -oP 'Submitted batch job \K\d+')

    if [ -n "$ARRAY_ID" ]; then
        ARRAY_IDS+=("$ARRAY_ID")
        echo "Submitted array job $ARRAY_ID (${BATCH_SIZE} chunks)"
    else
        echo "ERROR: Submission failed for batch $BATCH"
        exit 1
    fi

    START=$(( END + 1 ))
    BATCH=$(( BATCH + 1 ))
done

echo ""
echo "=========================================="
echo "Array Job IDs: ${ARRAY_IDS[*]}"
echo "Monitor: watch -n 5 'squeue -u \$USER'"
echo "Cancel all: scancel ${ARRAY_IDS[*]}"
echo "=========================================="
RESUBMIT_SCRIPT

chmod +x /shared/scripts/resubmit-missing.sh

# ==========================================
# Create Apptainer installation script (manual)
# ==========================================
cat > /shared/scripts/install-apptainer.sh << 'INSTALL_APPTAINER'
#!/bin/bash
# Manual Apptainer installation script
# Run this after cluster is up if you need Apptainer

set -e

echo "=========================================="
echo "Installing Apptainer..."
echo "This will take ~10-15 minutes"
echo "=========================================="

# Install dependencies
sudo yum install -y \
    wget \
    gcc \
    gcc-c++ \
    make \
    libuuid-devel \
    openssl-devel \
    libseccomp-devel \
    squashfs-tools \
    cryptsetup \
    rpm-build

# Install Go
cd /tmp
GO_VERSION="1.21.5"
echo "Downloading Go ${GO_VERSION}..."
wget -q https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin

# Make Go available system-wide
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh

# Download and build Apptainer
echo "Downloading Apptainer..."
APPTAINER_VERSION="1.2.5"
wget -q https://github.com/apptainer/apptainer/releases/download/v${APPTAINER_VERSION}/apptainer-${APPTAINER_VERSION}.tar.gz
tar -xzf apptainer-${APPTAINER_VERSION}.tar.gz
cd apptainer-${APPTAINER_VERSION}

echo "Building Apptainer (this takes ~10 minutes)..."
./mconfig --prefix=/shared/apptainer
make -C builddir
sudo make -C builddir install

# Add to PATH
echo 'export PATH=/shared/apptainer/bin:$PATH' | sudo tee /etc/profile.d/apptainer.sh
export PATH=/shared/apptainer/bin:$PATH

# Verify
/shared/apptainer/bin/apptainer --version

echo "=========================================="
echo "✓ Apptainer installed to /shared/apptainer"
echo "=========================================="
INSTALL_APPTAINER

chmod +x /shared/scripts/install-apptainer.sh

# ==========================================
# Environment configuration
# ==========================================
cat >> /etc/profile.d/cluster-env.sh << 'EOF'
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

# ==========================================
# Create README
# ==========================================
cat > /shared/README.md << 'README'
# Ersilia ParallelCluster - Simplified Bootstrap

## ⚠️ IMPORTANT: Apptainer Not Installed

This cluster was bootstrapped without Apptainer to avoid timeout issues.

### To install Apptainer manually:

```bash
# SSH to head node
ssh -i ~/.ssh/ersilia-key.pem ec2-user@HEAD_NODE_IP

# Run installation script (~10-15 minutes)
/shared/scripts/install-apptainer.sh
```

## Quick Start

1. **Test cluster:**
   ```bash
   /shared/scripts/test-cluster.sh
   ```

2. **Install Apptainer (if needed):**
   ```bash
   /shared/scripts/install-apptainer.sh
   ```

3. **Download SIF files from S3:**
   ```bash
   /shared/scripts/sync-sif-from-s3.sh
   ```

## Available Scripts

- `test-cluster.sh` - Validate cluster setup
- `install-apptainer.sh` - Install Apptainer manually (⚠️ required for processing)
- `sync-sif-from-s3.sh` - Download ALL SIF files from S3
- `download-ersilia-model.sh` - Download single SIF file from S3

## What Works Now

✓ Cluster creation (fast, no timeout)
✓ File system (EFS /shared, FSx /fsx)
✓ Slurm scheduler
✓ S3 access
✓ Python 3 + pip
✓ Helper scripts

## What Needs Manual Installation

⚠️ Apptainer (run `/shared/scripts/install-apptainer.sh`)
⚠️ ersilia-apptainer Python package (install after Apptainer)

## Next Steps After Cluster Creation

1. SSH to head node
2. Run `/shared/scripts/install-apptainer.sh`
3. Install ersilia-apptainer: `pip3 install ersilia-apptainer`
4. Download SIF files: `/shared/scripts/sync-sif-from-s3.sh`
5. Ready to process data!
README

chmod 644 /shared/README.md

# ==========================================
# Final verification
# ==========================================
echo "=========================================="
echo "Head Node Bootstrap Complete (SIMPLIFIED)!"
echo "=========================================="
echo "Python: $(python3 --version)"
echo "AWS CLI: $(aws --version)"
echo ""
echo "NOTE: Apptainer NOT installed (to avoid timeout)"
echo "To install Apptainer manually:"
echo "  /shared/scripts/install-apptainer.sh"
echo ""
echo "Helper scripts: /shared/scripts/"
echo "README: /shared/README.md"
echo "=========================================="