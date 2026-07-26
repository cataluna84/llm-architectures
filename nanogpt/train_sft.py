import os

# GPU-specific NCCL/XLA flags. Skipped on TPU (startup_script.sh sets
# NANOGPT_TPU=1) since these --xla_gpu_* / NCCL knobs don't apply there.
# This guard mirrors train.py and is load-bearing: exporting GPU XLA_FLAGS on a
# TPU host made JAX bring up a CPU backend alongside the TPU one, and with
# jax.distributed initialized that CPU backend does a cross-process topology
# exchange which nothing else joins — every host then died with
#   INTERNAL: Getting local topologies failed:
#   GetKeyValue() timed out with key: cpu:local_topology/cpu/N ... duration: 2m
# followed by a Shutdown barrier timeout and exit 134 (2026-07-26).
if os.environ.get("NANOGPT_TPU") != "1":
    os.environ["CUDA_DEVICE_MAX_CONNECTIONS"] = "1"
    os.environ["NCCL_NVLS_ENABLE"] = "1"
    os.environ.update(
        {
            "NCCL_LL128_BUFFSIZE": "-2",
            "NCCL_LL_BUFFSIZE": "-2",
            "NCCL_PROTO": "SIMPLE,LL,LL128",
        }
    )
    os.environ["XLA_FLAGS"] = (
        "--xla_gpu_triton_gemm_any=True "
        "--xla_gpu_enable_latency_hiding_scheduler=true "
        "--xla_gpu_enable_pipelined_all_reduce=true "
        "--xla_gpu_enable_pipelined_all_gather=true "
        "--xla_gpu_enable_pipelined_reduce_scatter=true "
        "--xla_gpu_enable_while_loop_double_buffering=true "
        "--xla_gpu_enable_pipelined_p2p=true "
        "--xla_gpu_collective_permute_decomposer_threshold=1024 "
    )
import warnings
import logging
import time
from functools import partial

import jax

# Multi-host TPU slices (v5e-32 = 8 hosts x 4 chips, v5e-64 = 16 x 4) need the
# distributed runtime up BEFORE anything touches the backend — model.py queries
# jax.default_backend() at import time below. Harmless on single host
# (initializes a 1-process cluster). Mirrors train.py.
if os.environ.get("NANOGPT_TPU") == "1":
    try:
        jax.distributed.initialize()
    except Exception as _exc:
        print(f"[dist] jax.distributed.initialize() skipped: {_exc}")

jax.config.update("jax_optimization_level", "O1")

import optax
import numpy as np
import jax.numpy as jnp
import orbax.checkpoint as ocp
from jax.sharding import Mesh

from model import count_params
from model import precompute_frequencies
from model import GPT, forward
from utils import logical_to_sharding
from checkpoint_utils import load_weights_from_checkpoint_with_validation
from config import ShardingRules, Config, BATCH_AXIS_NAME
from sft_dataloader import make_grain_shard_loader, build_tokenizer
from wandb_logger import (
    load_dotenv,
    init_wandb,
    device_peak_flops,
    transformer_flops_per_token,
)


logging.getLogger("absl").setLevel(logging.ERROR)
warnings.filterwarnings("ignore", category=UserWarning, message=".*CheckpointManager.*")


jitted_precompute_frequencies = jax.jit(
    precompute_frequencies, static_argnames=("features", "theta", "dtype")
)


def host_local_to_global(sharding, buf, local_rows, batch_dim=0):
    """Ship this host's row-slice of the global batch to its local devices.

    Every process runs the identical data pipeline over the same shard list in
    the same order, so `buf` holds the full global batch on every host; each
    host transfers only its own block of `local_rows` along `batch_dim`.

    Without this, a host-local array gets device_put against a sharding that
    spans devices the process does not own. The collectives then never match,
    every core parks in Vwait on a sync flag that never arrives, and libtpu
    eventually kills the slice with SLICE_FAILURE_SW_INJECT_ERROR (signal 6,
    exit 134). That killed a v5e-32 and reproduced identically on a fresh
    v5e-64 on 2026-07-26 — it is a missing multi-host port, not bad hardware.

    Unlike train.py's copy this does NOT force int32: completion_mask is bool
    and optax's `where=` needs it to stay that way.
    """
    buf = np.asarray(buf)
    idx = (slice(None),) * batch_dim + (local_rows,)
    local = np.ascontiguousarray(buf[idx])
    return jax.make_array_from_process_local_data(sharding, local, buf.shape)


def compute_loss(params, x_batch, y_batch, segment_ids, freqs, loss_mask):
    logits = forward(params, x_batch, segment_ids, freqs)
    if loss_mask is not None:
        per_token_loss = optax.losses.softmax_cross_entropy_with_integer_labels(
            logits=logits,
            labels=y_batch,
            where=loss_mask,
        )
        return jnp.sum(per_token_loss) / jnp.maximum(jnp.sum(loss_mask), 1.0)
    else:
        return jnp.mean(
            optax.losses.softmax_cross_entropy_with_integer_labels(
                logits=logits, labels=y_batch
            )
        )


@partial(
    jax.jit,
    static_argnames=("optim", "grad_accum_steps"),
    donate_argnames=("params", "x_batch", "y_batch", "optim_state"),
)
def train_step_accum(
    params,
    x_batch,
    y_batch,
    segment_ids,
    freqs,
    loss_mask,
    optim_state,
    optim,
    grad_accum_steps,
):
    def body(carry, xy):
        param, opt_state, lsum = carry
        xb, yb = xy
        loss, grad = jax.value_and_grad(compute_loss)(
            param, xb, yb, segment_ids, freqs, loss_mask
        )

        # MultiSteps accumulates grad internally and returns a zero-tree update on
        # every micro-step except the last, where it emits the real update.
        updates, new_opt_state = optim.update(grad, opt_state, param)
        new_param = optax.apply_updates(param, updates)
        return (new_param, new_opt_state, lsum + loss), None

    carry0 = (params, optim_state, jnp.array(0.0, dtype=jnp.result_type(0.0)))
    (params, optim_state, lsum), _ = jax.lax.scan(
        body, carry0, (x_batch, y_batch), length=grad_accum_steps
    )
    loss = lsum / grad_accum_steps
    return params, loss, optim_state


@partial(
    jax.jit,
    static_argnames=("optim",),
    donate_argnames=("params", "x_batch", "y_batch", "optim_state"),
)
def train_step(
    params, x_batch, y_batch, segment_ids, freqs, loss_mask, optim_state, optim
):
    loss, grads = jax.value_and_grad(compute_loss)(
        params, x_batch, y_batch, segment_ids, freqs, loss_mask
    )
    updates, optim_state = optim.update(grads, optim_state, params)
    updated_params = optax.apply_updates(params, updates)
    return updated_params, loss, optim_state


@jax.jit
def val_step(params, x_batch, y_batch, segment_ids, freqs, loss_mask):
    loss = compute_loss(params, x_batch, y_batch, segment_ids, freqs, loss_mask)
    return loss


def line(label, value, comma=False, label_w=30, colon_w=2, value_w=20):
    fmt = f">{value_w}," if comma else f">{value_w}"
    return f"{label:<{label_w}}{':':<{colon_w}}{value:{fmt}}"


def model_run_name(cfg):
    return (
        f"{cfg.model.attn_type}"
        f"_L{cfg.model.num_layers}"
        f"_D{cfg.model.d_emb}"
        f"_Q{cfg.model.q_heads}"
        f"_KV{cfg.model.kv_heads}"
        f"_H{cfg.model.attn.head_dim}"
        f"_T{cfg.model.seqlen}"
        f"_V{cfg.model.vocab_size}"
        f"_{cfg.model.window_pattern}"
    )


def main():
    # Seed os.environ from .env (WANDB_*, etc.) before building the config,
    # which reads those values at construction time.
    load_dotenv()

    # Get the mesh, sharding rules, amd the config
    devices = np.array(jax.devices())
    print("Number of devices found:", len(devices))
    mesh = Mesh(devices, axis_names=BATCH_AXIS_NAME)
    sharding_rules = ShardingRules(batch=BATCH_AXIS_NAME)
    cfg = Config(mesh=mesh, rules=sharding_rules)

    per_device_bsz = cfg.hparams.per_device_batch_size
    bsz = per_device_bsz * len(devices)
    seqlen = cfg.model.seqlen
    head_dim = cfg.model.attn.head_dim
    data_sharding = logical_to_sharding(("batch",), cfg.mesh, cfg.rules)
    # Multi-host: jax.devices() orders devices by process, so this host owns the
    # contiguous row block [process_index*local_bsz, ...) of every global batch.
    local_bsz = per_device_bsz * jax.local_device_count()
    local_rows = slice(
        jax.process_index() * local_bsz, (jax.process_index() + 1) * local_bsz
    )
    max_lr = cfg.hparams.max_lr
    min_lr = 0.01 * max_lr
    grad_accum_steps = 1
    total_train_steps = cfg.hparams.total_train_steps
    max_checkpoints_to_keep = cfg.ckpt_cfg.max_checkpoints_to_keep
    checkpoint_save_steps = cfg.ckpt_cfg.checkpoint_save_steps

    tok_info = build_tokenizer()
    # data_sharding=None below: the loader must yield HOST numpy batches. Letting
    # grain device_put them against the global sharding is precisely what
    # deadlocked the slice; host_local_to_global does the placement instead.
    train_dl = make_grain_shard_loader(
        data_dir=cfg.data_dir,
        split="train",
        pad_id=tok_info["pad_id"],
        batch_size=bsz,
        sequence_length=seqlen,
        grad_accum_steps=1,
        data_sharding=None,
        multi_threading=True,
    )
    train_iter = iter(train_dl)

    # During testing, we had only one shard of validation data.
    # Hence multi-threading was turned off for it.
    # TODO: Enable multi-threading once we have enough val shards
    val_dl = make_grain_shard_loader(
        data_dir=cfg.data_dir,
        split="test",
        pad_id=tok_info["pad_id"],
        batch_size=bsz,
        sequence_length=seqlen,
        grad_accum_steps=1,
        data_sharding=None,
        cycle_length=1,
        multi_threading=False,
    )

    # Load the model
    print("Building GPT model based on the config...")
    model = GPT.init(jax.random.PRNGKey(0), cfg)
    print("Model built successfully!")
    model_sharding = GPT.shardings(cfg.mesh, cfg.rules, cfg.model)
    model = load_weights_from_checkpoint_with_validation(
        cfg.ckpt_cfg.load_params_ckpt_path, model, model_sharding
    )
    print("Weights loaded from the checkpoint successfully!")

    # Optimizer (constant LR for SFT)
    sft_lr = 1e-4
    optim = optax.chain(
        optax.clip_by_global_norm(cfg.hparams.grad_clip_norm),
        optax.adamw(learning_rate=sft_lr),
    )
    optim_state = optim.init(model)

    # Constant schedule mirror so wandb `train/lr` matches the pretrain interface.
    def lr_fn(_step):
        return sft_lr

    #  Checkpointing
    options = ocp.CheckpointManagerOptions(
        max_to_keep=max_checkpoints_to_keep,
        save_interval_steps=checkpoint_save_steps,
        enable_async_checkpointing=True,
        enable_background_delete=True,
    )
    handlers = {
        "params": ocp.Checkpointer(ocp.PyTreeCheckpointHandler()),
        "optim_state": ocp.Checkpointer(ocp.PyTreeCheckpointHandler()),
        # "ds": ocp.Checkpointer(grain.checkpoint.CheckpointHandler()),
    }
    mngr = ocp.CheckpointManager(cfg.ckpt_cfg.save_ckpt_dir, handlers, options=options)

    print("")
    print("-" * 75)
    print("")
    print(line("Run name", model_run_name(cfg), value_w=30))
    print(line("Attention type", cfg.model.attn_type))
    print(line("Attention Pattern", cfg.model.window_pattern))
    print(line("Model dtype", str(cfg.model.dtype)))
    print(line("Num layers", cfg.model.num_layers))
    print(line("Embedding dim", cfg.model.d_emb))
    print(line("Query heads", cfg.model.q_heads))
    print(line("KV heads", cfg.model.kv_heads))
    print(line("Head dim", cfg.model.attn.head_dim))
    print(line("MLP hidden dim", cfg.model.mlp.fc1.out_features))
    print(line("Vocab size", cfg.model.vocab_size))
    print(line("Number of trainable params: ", count_params(model), comma=True))
    print(line("Sequence length per sample", seqlen))
    print(line("Per device batch size", per_device_bsz))
    print(line("Total batch size", bsz))
    print(line("Grad accumulation steps", grad_accum_steps))
    print()
    print(line("LR (min, max)", str((f"{min_lr:.6f}", f"{max_lr:.6f}"))))
    print(line("Warmup steps", cfg.hparams.warmup_steps))
    print(line("Weight decay", cfg.hparams.weight_decay), "\n")
    print("-" * 75)

    num_params = count_params(model)
    run = init_wandb(
        cfg,
        model_run_name(cfg),
        {
            "attn_type": cfg.model.attn_type,
            "window_pattern": cfg.model.window_pattern,
            "num_layers": cfg.model.num_layers,
            "d_emb": cfg.model.d_emb,
            "q_heads": cfg.model.q_heads,
            "kv_heads": cfg.model.kv_heads,
            "head_dim": head_dim,
            "seqlen": seqlen,
            "vocab_size": cfg.model.vocab_size,
            "num_params": num_params,
            "per_device_batch_size": per_device_bsz,
            "total_batch_size": bsz,
            "grad_accum_steps": grad_accum_steps,
            "lr": sft_lr,
            "total_train_steps": total_train_steps,
            "num_devices": len(devices),
            "stage": "sft",
        },
    )

    # Constants for MFU: FLOPs/token (dense + attention) and total device peak.
    flops_per_token = transformer_flops_per_token(
        num_params, cfg.model.num_layers, cfg.model.d_emb, seqlen
    )
    peak_flops_total = device_peak_flops() * len(devices)

    best_loss = float("inf")
    last_val_loss = float("inf")
    es_patience = cfg.hparams.es_patience
    es_patience_counter = 0
    best_step = 0
    num_shards_used = 0
    total_tokens_consumed = 0
    # Train-only wall clock (excludes eval/logging) for the leaderboard summary.
    total_train_step_time = 0.0
    steps_this_run = 0  # completed optimizer steps this process (for avg/ETA)

    # SFT always starts at step 0. It warm-starts from load_params_ckpt_path
    # (params only, above) and never restores optimizer state — there is no
    # mngr.restore on this path — so a mid-run resume would silently continue
    # with a fresh optimizer, which is worse than redoing the work. A preempted
    # SFT run simply reruns from the pretrained params.
    # (`cfg.ckpt_cfg.last_checkpoint_step` / NANOGPT_RESUME_FROM_STEP drives
    # pretraining resume only, and may be the string "auto", not a step index.)
    step = 0
    print("Starting training (the first step will take some time for compilation...)\n")

    training_complete = False
    train_start_time = time.time()

    for train_batch in train_iter:
        if training_complete:
            break
        start = time.time()

        # Every host holds the full global batch; ship only our own rows.
        def _g(key, _b=train_batch):
            return host_local_to_global(data_sharding, _b[key], local_rows)

        x, y = _g("x"), _g("y")
        segment_ids = _g("segment_ids")
        completion_mask = _g("completion_mask")
        positions = _g("positions")

        with jax.set_mesh(cfg.mesh):
            freqs = jitted_precompute_frequencies(positions, head_dim)

        model, loss, optim_state = train_step(
            model, x, y, segment_ids, freqs, completion_mask, optim_state, optim
        )
        loss = jax.block_until_ready(loss).item()
        end = time.time()
        dt = end - start
        train_time_elapsed = (end - train_start_time) / 60  # in minutes

        step += 1
        tokens_processed = bsz * seqlen * grad_accum_steps
        total_tokens_consumed += tokens_processed
        total_train_step_time += dt
        steps_this_run += 1
        tokens_per_sec = int(tokens_processed / dt)
        # MFU = achieved FLOPs/s over device peak. ETA uses the average step time
        # so far (the compile-heavy first step washes out within a few steps).
        mfu = flops_per_token * tokens_per_sec / peak_flops_total
        avg_step_time = total_train_step_time / steps_this_run
        eta_minutes = max(total_train_steps - step, 0) * avg_step_time / 60.0

        print(f"Step: [{str(step).zfill(len(str(total_train_steps)))}/{total_train_steps}] | loss: {loss:8.4f} | Step time: {dt:5.2f} s | Train time: {train_time_elapsed:6.2f} min | Tokens/s: {tokens_per_sec:>9,} | MFU: {mfu * 100:4.1f}% | ETA: {eta_minutes:6.1f} min")  # fmt: off

        if (step % cfg.wandb.log_interval) == 0:
            run.log(
                {
                    "train/loss": float(loss),
                    "train/lr": float(lr_fn(step)),
                    "perf/tokens_per_sec": tokens_per_sec,
                    "perf/step_time_s": dt,
                    "perf/mfu": mfu,
                    "perf/total_tokens": total_tokens_consumed,
                    "time/train_minutes": train_time_elapsed,
                    "time/eta_minutes": eta_minutes,
                },
                step=step,
            )

        if (step % options.save_interval_steps) == 0:
            mngr.save(
                step,
                args=ocp.args.Composite(
                    params=ocp.args.PyTreeSave(model),
                    optim_state=ocp.args.PyTreeSave(optim_state),
                    # ds=grain.checkpoint.CheckpointSave(train_iter),
                ),
            )
            print("\nScoring model performance on validation data...\n")
            val_loss = 0.0
            val_steps_count = 0
            val_iter = iter(val_dl)
            for val_batch in val_iter:

                def _v(key, _b=val_batch):
                    return host_local_to_global(data_sharding, _b[key], local_rows)

                val_x, val_y = _v("x"), _v("y")
                val_segment_ids = _v("segment_ids")
                val_completion_mask = _v("completion_mask")
                val_positions = _v("positions")
                with jax.set_mesh(cfg.mesh):
                    val_freqs = jitted_precompute_frequencies(val_positions, head_dim)
                loss = val_step(
                    model, val_x, val_y, val_segment_ids, val_freqs, val_completion_mask
                )

                val_loss += loss
                val_steps_count += 1
            avg_val_loss = val_loss / val_steps_count
            avg_val_loss = jax.block_until_ready(avg_val_loss).item()

            improved = avg_val_loss < best_loss
            if improved:
                best_loss = avg_val_loss
                best_step = step
                es_patience_counter = 0
            else:
                es_patience_counter += 1

            run.log(
                {
                    "val/loss": avg_val_loss,
                    "val/best_loss": best_loss,
                    "val/best_step": best_step,
                },
                step=step,
            )

            if es_patience_counter > es_patience:
                # fmt: off
                print(f"\nEarly stopping triggered! No improvement for {es_patience_counter} steps.")
                print(f"Total number of shards consumed : {num_shards_used}")
                print(f"Best loss                       : {best_loss:.4f} at step {best_step}")
                mngr.wait_until_finished()
                training_complete = True
                break
                # fmt: on

            print(f"last_val_loss : {last_val_loss:.4f}")
            print(f"curr_val_loss : {avg_val_loss:.4f}")
            print(f"Best loss     : {best_loss:.4f} at step {best_step}\n")
            last_val_loss = avg_val_loss

        if step >= total_train_steps:
            print(f"\nReached maximum training steps  : {total_train_steps}")
            print(f"Total number of shards consumed : {num_shards_used}")
            print(f"Best loss : {best_loss:.4f} at step {best_step}")
            mngr.wait_until_finished()
            print("Finished checkpointing! Cleaned.")
            # training_complete = True
            break

    train_end_time = time.time()
    print(
        f"\nTotal time taken to train the model: {(train_end_time - train_start_time) / 60:.2f} minutes"
    )

    # Leaderboard-shaped run summary (see train.py for the convention).
    run.summary(
        total_training_time=total_train_step_time,
        total_training_flops=6 * num_params * total_tokens_consumed,
        step=step,
        best_val_loss=best_loss,
        best_step=best_step,
        total_tokens=total_tokens_consumed,
        num_shards=num_shards_used,
    )
    run.finish()


if __name__ == "__main__":
    main()
