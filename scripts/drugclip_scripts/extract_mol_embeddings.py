#!/usr/bin/env python3
"""
Extract 128-dim L2-normalized molecular embeddings using DrugCLIP.

Loads a molecule LMDB (produced by smiles_to_lmdb.py), runs the DrugCLIP
mol encoder, and saves the embeddings to an HDF5 file.

Usage (inside SIF):
    python /drugclip/extract_mol_embeddings.py \
        --lmdb      /fsx/tmp/mols.lmdb \
        --checkpoint /shared/drugclip-weights/checkpoint_best.pt \
        --output     /fsx/output/Molport.../drugclip/chunk_NNN.h5 \
        [--dict-dir  /drugclip/data] \
        [--batch-size 256] \
        [--cpu]

HDF5 output layout:
    embeddings  : float32 (N, 128)  — L2-normalized embedding vectors
    smiles      : variable-length str (N,) — SMILES from the LMDB
    attrs:
        n_molecules    : int
        embedding_dim  : int (128)
"""

import argparse
import logging
import sys
from pathlib import Path

import numpy as np
import torch
import h5py

# DrugCLIP repo is at /drugclip inside the SIF
sys.path.insert(0, "/drugclip")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)


def build_task_args(dict_dir: str, batch_size: int, cpu: bool):
    """
    Build a minimal Namespace with the arguments DrugCLIP's task and model
    require.  Architecture values are the defaults from drugclip_architecture()
    in unimol/models/drugclip.py — they will be overridden by the checkpoint
    weights anyway, but Unicore needs them to construct the model object.
    """
    import argparse

    a = argparse.Namespace(
        # ── Task ──────────────────────────────────────────────────────────
        task="drugclip",
        data=dict_dir,          # directory with dict_mol.txt / dict_pkt.txt
        arch="drugclip",

        # ── Mol encoder defaults (drugclip_architecture) ──────────────────
        mol_encoder_layers=15,
        mol_encoder_embed_dim=512,
        mol_encoder_ffn_embed_dim=2048,
        mol_encoder_attention_heads=64,
        mol_dropout=0.1,
        mol_emb_dropout=0.1,
        mol_attention_dropout=0.1,
        mol_activation_dropout=0.0,
        mol_max_seq_len=512,
        mol_activation_fn="gelu",
        mol_pooler_activation_fn="tanh",
        mol_pooler_dropout=0.0,
        mol_post_ln=False,
        mol_masked_token_loss=-1.0,
        mol_masked_coord_loss=-1.0,
        mol_masked_dist_loss=-1.0,
        mol_x_norm_loss=-1.0,
        mol_delta_pair_repr_norm_loss=-1.0,

        # ── Pocket encoder defaults (same; needed for model init) ─────────
        pocket_encoder_layers=15,
        pocket_encoder_embed_dim=512,
        pocket_encoder_ffn_embed_dim=2048,
        pocket_encoder_attention_heads=64,
        pocket_dropout=0.1,
        pocket_emb_dropout=0.1,
        pocket_attention_dropout=0.1,
        pocket_activation_dropout=0.0,
        pocket_max_seq_len=512,
        pocket_activation_fn="gelu",
        pocket_pooler_activation_fn="tanh",
        pocket_pooler_dropout=0.0,
        pocket_post_ln=False,
        pocket_masked_token_loss=-1.0,
        pocket_masked_coord_loss=-1.0,
        pocket_masked_dist_loss=-1.0,
        pocket_x_norm_loss=-1.0,
        pocket_delta_pair_repr_norm_loss=-1.0,

        # ── Inference ─────────────────────────────────────────────────────
        seed=1,
        batch_size=batch_size,
        num_workers=0,
        max_pocket_atoms=256,
        finetune_mol_model=None,
        finetune_pocket_model=None,

        # ── Device / precision ────────────────────────────────────────────
        cpu=cpu,
        fp16=not cpu,
        fp16_init_scale=4,
        fp16_scale_window=256,
    )
    return a


def main():
    parser = argparse.ArgumentParser(
        description="DrugCLIP: extract 128-dim mol embeddings from LMDB → HDF5"
    )
    parser.add_argument("--lmdb",        required=True,
                        help="Molecule LMDB produced by smiles_to_lmdb.py")
    parser.add_argument("--checkpoint",  required=True,
                        help="DrugCLIP checkpoint_best.pt")
    parser.add_argument("--output",      required=True,
                        help="Output HDF5 file")
    parser.add_argument("--dict-dir",    default="/drugclip/data",
                        help="Directory with dict_mol.txt / dict_pkt.txt "
                             "(default: /drugclip/data)")
    parser.add_argument("--batch-size",  type=int, default=256)
    parser.add_argument("--emb-cache",   default="/tmp/drugclip_emb_cache",
                        help="Temp dir for encode_mols_once cache (default: /tmp/...)")
    parser.add_argument("--cpu",         action="store_true",
                        help="Force CPU (no GPU)")
    args = parser.parse_args()

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    Path(args.emb_cache).mkdir(parents=True, exist_ok=True)

    log.info("=" * 65)
    log.info("DrugCLIP — Molecular Embedding Extraction")
    log.info(f"  LMDB       : {args.lmdb}")
    log.info(f"  Checkpoint : {args.checkpoint}")
    log.info(f"  Output     : {args.output}")
    log.info(f"  Device     : {'CPU' if args.cpu else 'GPU'}")
    log.info(f"  Batch size : {args.batch_size}")
    log.info("=" * 65)

    # ── Import Unicore and register DrugCLIP models/tasks ────────────────────
    from unicore import tasks, checkpoint_utils
    import unimol  # noqa: F401  — registers drugclip task + model with Unicore

    # ── Set up task and model ─────────────────────────────────────────────────
    model_args = build_task_args(
        dict_dir=args.dict_dir,
        batch_size=args.batch_size,
        cpu=args.cpu,
    )

    log.info("Setting up DrugCLIP task ...")
    task = tasks.setup_task(model_args)

    log.info("Building model ...")
    model = task.build_model(model_args)

    log.info(f"Loading checkpoint ...")
    state = checkpoint_utils.load_checkpoint_to_cpu(args.checkpoint)
    model.load_state_dict(state["model"], strict=False)

    device = torch.device("cpu" if args.cpu else "cuda")
    model  = model.to(device)
    if not args.cpu:
        model = model.half()  # FP16 on GPU — matches training setup
    model.eval()
    log.info("Model ready")

    # ── Extract embeddings ────────────────────────────────────────────────────
    log.info("Running encode_mols_once ...")
    with torch.no_grad():
        mol_reps, mol_names = task.encode_mols_once(
            model,
            data_path=args.lmdb,
            emb_dir=args.emb_cache,
            atoms="atoms",
            coords="coordinates",
        )

    mol_reps = np.array(mol_reps, dtype=np.float32)
    log.info(f"Embeddings : {mol_reps.shape}  (N × 128, L2-normalized)")

    # ── Save to HDF5 ──────────────────────────────────────────────────────────
    log.info(f"Saving to {output_path} ...")
    with h5py.File(output_path, "w") as f:
        f.create_dataset("embeddings", data=mol_reps, compression="gzip")
        dt = h5py.special_dtype(vlen=str)
        f.create_dataset(
            "smiles",
            data=np.array([s.encode("utf-8") for s in mol_names], dtype=object),
            dtype=dt,
        )
        f.attrs["n_molecules"]   = len(mol_names)
        f.attrs["embedding_dim"] = mol_reps.shape[1]

    log.info(f"Done — {len(mol_names):,} embeddings → {output_path}")
    log.info("=" * 65)


if __name__ == "__main__":
    main()
