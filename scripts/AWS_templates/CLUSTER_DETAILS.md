# AI2050 Ersilia ParallelCluster - User Guide

---
## 🎯 Cluster Overview

**Cluster Name:** `ai2050-cluster`  
**Region:** `eu-north-1` (Stockholm)  
**Head Node:** Running 24/7  
**Compute Nodes:** Auto-scale on demand (0-35 nodes)

---

## 📂 Cluster Structure

### **Shared Storage (EFS -  /shared)**
- **Python 3.9:** ` /shared/python39/bin/python3.9`
- **Apptainer:** ` /shared/apptainer/bin/apptainer`
- **SIF Files:** ` /shared/sif-files/`
- **Scripts:** ` /shared/scripts/`
- **Logs:** ` /shared/logs/`

### **High-Performance Storage (FSx Lustre - /fsx)**
- **Input:** `/fsx/input/` (auto-syncs from S3)
- **Output:** `/fsx/output/` (manually uploaded to S3 by job scripts)

### **S3 Bucket Structure**
```
s3://ai2050-ersilia-cluster/
├── input/              ← Upload your chunked input files here
│   └── library_001/
│       ├── chunk_0001.csv
│       ├── chunk_0002.csv
│       └── ...
├── output/             ← Job results uploaded here
│   └── library_001/
│       └── eos2r5a/
│           ├── eos2r5a_results_0001.csv
│           └── ...
├── sif-files/          ← Upload your pre-built SIF files here ⭐
│   ├── eos2r5a.sif
│   ├── eos3b5e.sif
│   └── ...
├── scripts/            ← Bootstrap scripts
└── configs/            ← Cluster configs
```

## 📋 Available Queues

| Queue | Instance Types | vCPUs | RAM | Max Nodes | Cost/hr (Spot) | Use Case |
|-------|---------------|-------|-----|-----------|----------------|----------|
| **test-queue** | t3.medium | 2 | 4GB | 5 | ~$0.012 | Testing small chunks |
| **cpu-queue** | c6i.8xlarge, c7i.8xlarge, c5a.8xlarge, m6i.8xlarge | 32 | 64-128GB | 20 | ~$0.26 | Production processing |
| **gpu-queue** | g6.4xlarge, g4dn.4xlarge | 16 | 64GB | 10 | ~$0.43 | GPU models |

> **cpu-queue uses multiple instance types** with `capacity-optimized` allocation strategy. AWS automatically picks whichever has available Spot capacity, avoiding `InsufficientInstanceCapacity` errors.

---

## 🛠️ Helper Scripts

All scripts located in ` /shared/scripts/`

### **Model Management**
- `sync-sif-from-s3.sh` - Download ALL SIF files from S3
- `download-ersilia-model.sh` - Download one model from S3
- `upload-sif-to-s3.sh` - Upload SIF file(s) to S3

### **Job Processing**
- `submit-ersilia-batch.sh` - Submit parallel Slurm array job for a library ⭐
- `run-ersilia-job.sh` - Process one chunk (called automatically by array job)
- `check-results.sh` - Compare input vs output row counts per chunk ⭐
- `merge-results.sh` - Merge chunked results into single file
- `test-run-ersilia-job.sh` - Uses the test queue to run a test job

### **Cluster Management**
- `test-cluster.sh` - Validate cluster setup

---

## ⚙️ Important Technical Notes

### **Software Installed**
- **Python 3.9.18** (in  /shared/python39/)
- **Apptainer 1.2.5** (in  /shared/apptainer/)
- **ersilia-apptainer** (in /shared/python39/package)
- **AWS CLI v2**

#### Software installation guide:
##### 1. Shared Python Setup
To ensure all compute nodes have access to the same software, we used a standalone Python installation located on the shared EFS drive.

``` bash
# Install build dependencies
sudo yum install -y gcc openssl-devel bzip2-devel libffi-devel zlib-devel

# Download Python 3.9.18
cd /tmp
wget https://www.python.org/ftp/python/3.9.18/Python-3.9.18.tgz
tar xzf Python-3.9.18.tgz
cd Python-3.9.18

# Configure to install to shared (accessible by all nodes)
./configure --prefix=/shared/python39 --enable-optimizations

# Build with all cores (faster)
make -j$(nproc)

# Install to shared directory
sudo make install

# Verify
/shared/python39/bin/python3.9 --version

```

Fix permissions to allow ec2-user to install packages

```bash
sudo chown -R ec2-user:ec2-user /shared/python39
```
##### 2. Apptainer installation
Use the installation script provided in `/shared/scripts/install-apptaier.sh`

```bash
# Create installation script
/tmp/install-apptainer.sh
```
##### 3. Set Up PATH for All Users

```bash
# Add to system-wide profile
echo 'export PATH=/shared/python39/bin:/shared/apptainer/bin:$PATH' | sudo tee /etc/profile.d/cluster-env.sh

# Apply to current session
source /etc/profile.d/cluster-env.sh

# Verify
which python3.9
which apptainer
```

**Note:** Compute nodes automatically get this PATH via the bootstrap script!


##### 4. Ersilia-apptainer installation

Install to Shared Path:
``` bash
# Install from GitHub
cd /tmp
git clone https://github.com/ersilia-os/ersilia-apptainer.git
cd ersilia-apptainer

cd /tmp/ersilia-apptainer
/shared/python39/bin/python3.9 -m pip install .
```

##### 5. Troubleshooting
Permission Denied on Logs: Ensure the log directory is writable: chmod 777 /shared/logs.

ModuleNotFoundError: Ensure the script uses /shared/python39/bin/python3.9.

FileNotFound inside Container: The modified runner.py handles this by 1:1 binding. Ensure all paths provided are absolute paths.

### **Networking**
- Head node: Public subnet (has internet)
- Compute nodes: Private subnet (NO internet)
- VPC Endpoints: S3, DynamoDB (required for compute nodes)

### **Required VPC Endpoints** ⚠️
The cluster REQUIRES these VPC endpoints for compute nodes to work:
1. **S3 Gateway Endpoint** (pl-c3aa4faa) ✅
2. **DynamoDB Gateway Endpoint** (pl-adae4bc4) ✅

Both must be in the compute security group egress rules!

---

## 📞 Quick Reference

### **Useful Aliases** (pre-configured)
```bash
list-models           # ls -lh  /shared/sif-files/
download-model        #  /shared/scripts/download-ersilia-model.sh
sync-models           #  /shared/scripts/sync-sif-from-s3.sh
test-cluster          #  /shared/scripts/test-cluster.sh
```

### **Common Commands**
```bash
# Queue status
squeue -u $USER
sinfo

# Job history
sacct -u $USER --format=JobID,JobName,State,Elapsed

# Cancel job
scancel <JOBID>

# Cancel all your jobs
scancel -u $USER

# View log
cat  /shared/logs/ersilia-<JOBID>.out
```

---

## 🎓 Best Practices

1. **Upload SIF files to S3 before starting work** - much faster than building
2. **Test with small chunks first** - use test-queue with 1-2 chunks
3. **Monitor costs** - check Budget Alerts in AWS console
4. **Merge results regularly** - don't let thousands of chunk files accumulate
5. **Use descriptive library names** - easier to track multiple projects
6. **Back up results to S3** - FSx Lustre is temporary scratch space
7. **Clean up old jobs** - review  /shared/logs/ periodically

---

## 🆘 Support

- **Cluster Issues:** Check CloudWatch logs or SSH to nodes
- **Script Issues:** All scripts have `--help` or show usage when run without args
- **AWS Issues:** Check AWS console → CloudFormation for cluster stack

---

**Last Updated:** March 5, 2026
**Cluster Version:** aws-parallelcluster-3.14.1
**Python:** 3.9.18
**Apptainer:** 1.2.5