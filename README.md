# Running Ersilia models and DrugCLIP screening over billion-scale chemical libraries

![Status](https://img.shields.io/badge/status-in%20progress-orange)

This repository holds the compute work for Ersilia's AI2050 project: running Ersilia Model Hub
models, and DrugCLIP virtual screening, over commercial and natural-product libraries from
hundreds of thousands to 1.4 billion molecules, on an AWS ParallelCluster (Slurm) cluster.

## What is here

- **Library processing:** vendor files to model-ready SMILES chunks, re-chunking after
  standardization, and debugging failing chunks.
  [`scripts/library_processing/`](scripts/library_processing/README.md)
- **Billion-scale pipeline:** Enamine REAL 1.4B in FSx-bounded waves, with ID tagging and
  deduplication. [`scripts/large_library_scripts/`](scripts/large_library_scripts/README.md)
- **Cluster infrastructure and job toolkits:** VPC template, cluster configs, bootstrap
  scripts, and the submit/check/resubmit/bisect/merge scripts for Ersilia and Singularity
  models. [`scripts/AWS_templates/`](scripts/AWS_templates/),
  [`scripts/singularity_job_scripts/`](scripts/singularity_job_scripts/)
- **DrugCLIP screening:** molecule and pocket encoding for 66 human targets, and the
  enrichment validation against the paper's leaderboards.
  [`scripts/drugclip_scripts/`](scripts/drugclip_scripts/)

Queueing many model runs on the cluster is handled by the separate
[model-launcher](https://github.com/ersilia-os/model-launcher) repository.

## Getting started

Set up or reach the cluster with the guides in [`docs/`](docs/): the
[deployment checklist](docs/01_cluster_deployment_checklist.md),
[cluster details](docs/02_cluster_details.md) and [usage guide](docs/03_cluster_usage.md).
Scripts are deployed to `/shared/scripts/` on the head node and run there.

```bash
# locally: build chunks, then upload them to s3://ai2050-ersilia-cluster/input/<library>/
python scripts/library_processing/01_chemical_libraries_processing.py --input-dir ./raw --output-dir ./output

# head node: run an Ersilia model over a library, or DrugCLIP on the GPU queue
/shared/scripts/submit-ersilia-batch.sh <model_id> <library_name> cpu-queue
bash /shared/scripts/drugclip_scripts/submit-drugclip.sh <library_name> gpu-queue
```

## Outputs

Model results land in `/fsx/output/<library>/<model_id>/` and are synced to
`s3://ai2050-ersilia-cluster/output/`. Results pulled locally go in `output/`, which is tracked
by eosvc, not git. Findings and decision logs are in [`docs/`](docs/); the DrugCLIP validation
result is in [`docs/05_drugclip_validation.md`](docs/05_drugclip_validation.md).

The repository layout and conventions are described in [`CLAUDE.md`](CLAUDE.md).

## About the Ersilia Open Source Initiative

The [Ersilia Open Source Initiative](https://ersilia.io) is a tech-nonprofit organization fueling sustainable research in the Global South. Ersilia's main asset is the [Ersilia Model Hub](https://github.com/ersilia-os/ersilia), an open-source repository of AI/ML models for antimicrobial drug discovery.

![Ersilia Logo](assets/Ersilia_Brand.png)
