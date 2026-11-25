#!/bin/bash
# Sync the NON-model SIFs (drugclip, drugclip_pocket, unidock, ...) from the AI2050 bucket.
#
# Model SIFs (eos*.sif) come only from s3://models-sif and are fetched per model by
# download-ersilia-model.sh (every submit script calls it), so they are excluded here.
# models-sif cannot be listed from this account, so it cannot be synced anyway.
S3_BUCKET="${S3_BUCKET:-ai2050-ersilia-cluster}"

echo "Syncing non-model SIF files from s3://$S3_BUCKET/sif-files/ ..."
aws s3 sync s3://$S3_BUCKET/sif-files/ /shared/sif-files/ \
    --exclude "*" --include "*.sif" --exclude "eos*"
echo "✓ Sync complete!"
ls -lh /shared/sif-files/*.sif 2>/dev/null || echo "No SIF files found"
