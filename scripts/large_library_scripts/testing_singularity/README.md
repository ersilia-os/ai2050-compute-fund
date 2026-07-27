# testing_singularity

Bench scripts for sizing the singularity wave pipeline **before** launching a
billion-scale run. Nothing here touches the real S3 output or the pipeline — all
work lands in a throwaway `WORKDIR` (default `/fsx/output/_packing_test/...`).

## run-singularity-packing-test.sh

Answers: **how many singularity jobs of a given model fit on one EC2 instance?**

It runs `<num_jobs>` model jobs concurrently on the machine that executes it,
samples RAM + CPU load every couple of seconds, then verifies each output
(exists + row count matches its input). The number of jobs is the argument, so
you sweep it upward until RAM runs out or outputs start failing.

```bash
# grab a whole node of the target instance type first:
srun --partition=cpu-queue --exclusive --pty bash

# then sweep concurrency:
bash run-singularity-packing-test.sh <model_id> 4
bash run-singularity-packing-test.sh <model_id> 8
bash run-singularity-packing-test.sh <model_id> 16
```

Args: `<model_id> <num_jobs> [library=Enamine_Real_Sample_1.4B] [source_dir=/fsx/input/<library>]`.
Inputs are taken from `source_dir` if it holds enough chunks, otherwise pulled
from `s3://$S3_BUCKET/input/<library>/`.

### Reading the result

The summary prints measured **MB/job** and **cores/job**, then a rough capacity
estimate (RAM-bound vs CPU-bound — the real limit is the smaller). Feed that into
the worker:

- Set `--cpus-per-task = nproc / max_jobs` in `../run-singularity-wave-job.sh`.
- If `max_jobs ≈ 1`, keep the default `--exclusive`.

A non-zero exit means at least one job failed at that concurrency (likely OOM /
contention) — back off `num_jobs`.
