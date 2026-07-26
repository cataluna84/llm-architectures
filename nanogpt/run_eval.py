"""
Base / SFT model evaluation over the tasks/ definitions. MULTI-HOST: the v5e/v6e
pods are one slice spanning N hosts, so this must run on ALL hosts (jax.distributed
rendezvous). Every host runs the identical data pipeline (deterministic HF shuffle
seed=42), feeds its local_rows slice of each global batch, and results are gathered
to host 0 (reshard batch-sharded -> replicated). Only host 0 logs to W&B.

Scoring:
  - categorical (MMLU, ARC): argmax of the next-token logit over the candidate
    letter tokens after assistant_start (render_mc uses no leading space -> 1 token).
  - generative (GSM8K): greedy KV-cache generation to <|assistant_end|>, then
    task.evaluate() (regex-extracts "#### N").

Launch on all workers with NANOGPT_TPU=1. Config via config.py env vars plus:
  NANOGPT_LOAD_PARAMS_CKPT_PATH  checkpoint params/ dir                (required)
  NANOGPT_EVAL_MAX_EXAMPLES      cap per task                          (default 200)
  NANOGPT_EVAL_MAX_NEW_TOKENS    generative budget                     (default 256)
  NANOGPT_EVAL_PER_DEVICE        per-device batch (x total devices)    (default 1)
  NANOGPT_EVAL_LABEL             tag for W&B keys, base|sft            (default base)
"""

import os

import jax
import numpy as np
import jax.numpy as jnp
from jax.sharding import Mesh, NamedSharding, PartitionSpec

# Distributed rendezvous BEFORE importing model (model.py queries the backend at
# import). Gated on NANOGPT_TPU so a laptop import doesn't try to form a cluster.
if os.environ.get("NANOGPT_TPU") == "1":
    try:
        jax.distributed.initialize()
    except Exception as _exc:  # noqa: BLE001
        print(f"[dist] jax.distributed.initialize() skipped: {_exc}", flush=True)

from model import GPT
from kvcache import KVCache
from utils import logical_to_sharding
from checkpoint_utils import load_weights_from_checkpoint_with_validation
from config import ShardingRules, Config, BATCH_AXIS_NAME
from sft_dataloader import build_tokenizer, format_conversation
from inference import pad_tokens, prefill, generate_with_stop_condition
from wandb_logger import init_wandb


def _env(k, d):
    return os.environ.get(k, d)


def _prompt_text(conv, tok_info):
    # User turn only + assistant_start; check_assistant_role=False so the
    # (deliberately assistant-less) prompt isn't dropped to None.
    user_ex = {"messages": [conv["messages"][0]]}
    text = format_conversation(user_ex, tok_info, check_assistant_role=False)["text"]
    return text + tok_info["assistant_start"]


def host_local_to_global(sharding, buf, local_rows):
    """Each host holds the full `buf`; ship only its own row block to the mesh."""
    local = np.ascontiguousarray(buf[local_rows], dtype=np.int32)
    return jax.make_array_from_process_local_data(sharding, local, buf.shape)


def _feed(prompts, batch_size, tok_info, cfg, data_sharding, local_rows):
    if len(prompts) < batch_size:
        prompts = prompts + [prompts[-1]] * (batch_size - len(prompts))
    encoded = tok_info["tokenizer"].encode_batch(prompts, allowed_special="all")
    padded, seg = pad_tokens(encoded, tok_info["pad_id"], pad_to_power_of_two=True)
    padded, seg = np.asarray(padded), np.asarray(seg)
    return (
        host_local_to_global(data_sharding, padded, local_rows),
        host_local_to_global(data_sharding, seg, local_rows),
    )


def _gather(arr, cfg):
    """Reshard a batch-sharded global array to replicated -> full numpy on host."""
    rep = jax.device_put(arr, NamedSharding(cfg.mesh, PartitionSpec()))
    return np.asarray(rep)


def eval_categorical(model, task, tok_info, cfg, head_dim, n, bs, data_sharding, local_rows):  # fmt: off
    PAD_ID = tok_info["pad_id"]
    tokenizer = tok_info["tokenizer"]
    letter_id = {}
    correct = total = 0
    for start in range(0, n, bs):
        convs = [task[i] for i in range(start, min(start + bs, n))]
        real = len(convs)
        g_ids, g_seg = _feed(
            [_prompt_text(c, tok_info) for c in convs],
            bs,
            tok_info,
            cfg,
            data_sharding,
            local_rows,  # fmt: off
        )
        cache = KVCache.init(jax.random.PRNGKey(1), cfg.mesh, cfg.rules, bs, cfg)
        with jax.set_mesh(cfg.mesh):
            logits, _, _ = prefill(model, g_ids, g_seg, cache, head_dim, pad_id=PAD_ID)
            last = logits[:, -1, :]
        full_last = _gather(last, cfg)
        for j in range(real):
            conv = convs[j]
            letters = conv.get("letters") or getattr(task, "letters", ("A", "B", "C", "D"))  # fmt: off
            lids = []
            for lt in letters:
                if lt not in letter_id:
                    letter_id[lt] = tokenizer.encode_batch([lt], allowed_special="all")[0][0]  # fmt: off
                lids.append(letter_id[lt])
            pred = letters[int(np.argmax([full_last[j, lid] for lid in lids]))]
            correct += int(bool(task.evaluate(conv, pred)))
            total += 1
    return correct / max(total, 1), total


def eval_generative(model, task, tok_info, cfg, head_dim, n, bs, max_new, data_sharding, local_rows):  # fmt: off
    PAD_ID = tok_info["pad_id"]
    stop_id = tok_info["assistant_end_id"]
    end_str = tok_info["assistant_end"]
    correct = total = 0
    for start in range(0, n, bs):
        convs = [task[i] for i in range(start, min(start + bs, n))]
        real = len(convs)
        g_ids, g_seg = _feed(
            [_prompt_text(c, tok_info) for c in convs],
            bs,
            tok_info,
            cfg,
            data_sharding,
            local_rows,  # fmt: off
        )
        cache = KVCache.init(jax.random.PRNGKey(1), cfg.mesh, cfg.rules, bs, cfg)
        with jax.set_mesh(cfg.mesh):
            _, next_tokens, cache = prefill(model, g_ids, g_seg, cache, head_dim, pad_id=PAD_ID)  # fmt: off
            gen = jnp.zeros((bs, max_new), dtype=jnp.int32).at[:, 0].set(next_tokens)
            generated = generate_with_stop_condition(
                model,
                cache,
                next_tokens[:, None],
                gen,
                head_dim,
                jax.random.PRNGKey(7),
                temperature=0.0,
                top_k=0,
                max_new_tokens=max_new,
                stop_token_id=stop_id,
            )
        full_gen = _gather(generated, cfg)
        decoded = tok_info["tokenizer"].decode_batch(full_gen.tolist())
        for j in range(real):
            completion = decoded[j].split(end_str)[0]
            correct += int(bool(task.evaluate(convs[j], completion)))
            total += 1
    return correct / max(total, 1), total


def build_tasks(max_examples):
    from tasks.mmlu import MMLU
    from tasks.arc import ARC
    from tasks.gsm8k import GSM8K

    return [
        ("mmlu", MMLU(subset="all", split="test", stop=max_examples), "categorical"),
        (
            "arc_easy",
            ARC(subset="ARC-Easy", split="test", stop=max_examples),
            "categorical",
        ),  # fmt: off
        (
            "arc_challenge",
            ARC(subset="ARC-Challenge", split="test", stop=max_examples),
            "categorical",
        ),  # fmt: off
        ("gsm8k", GSM8K(subset="main", split="test", stop=max_examples), "generative"),
    ]


if __name__ == "__main__":
    devices = np.array(jax.devices())
    h0 = jax.process_index() == 0
    if h0:
        print(f"[eval] processes={jax.process_count()} devices={len(devices)} platform={devices[0].platform}", flush=True)  # fmt: off
    mesh = Mesh(devices, axis_names=BATCH_AXIS_NAME)
    cfg = Config(mesh=mesh, rules=ShardingRules(batch=BATCH_AXIS_NAME))

    per_device = int(_env("NANOGPT_EVAL_PER_DEVICE", "1"))
    bs = per_device * len(devices)
    local_bsz = per_device * jax.local_device_count()
    local_rows = slice(jax.process_index() * local_bsz, (jax.process_index() + 1) * local_bsz)  # fmt: off
    data_sharding = logical_to_sharding(("batch",), cfg.mesh, cfg.rules)

    max_examples = int(_env("NANOGPT_EVAL_MAX_EXAMPLES", "200"))
    max_new = int(_env("NANOGPT_EVAL_MAX_NEW_TOKENS", "256"))
    label = _env("NANOGPT_EVAL_LABEL", "base")

    ckpt = cfg.ckpt_cfg.load_params_ckpt_path
    assert ckpt, "set NANOGPT_LOAD_PARAMS_CKPT_PATH to the checkpoint params/ dir"
    if h0:
        print(f"[eval] label={label} batch={bs} max_examples={max_examples}\n[eval] ckpt={ckpt}", flush=True)  # fmt: off
    model = GPT.init(jax.random.PRNGKey(0), cfg)
    model_sharding = GPT.shardings(cfg.mesh, cfg.rules, cfg.model)
    model = load_weights_from_checkpoint_with_validation(ckpt, model, model_sharding)
    if h0:
        print("[eval] checkpoint loaded.", flush=True)

    tok_info = build_tokenizer()
    head_dim = cfg.model.attn.head_dim
    run = init_wandb(cfg, f"eval-{label}", {"eval_label": label, "max_examples": max_examples})  # fmt: off

    results = {}
    for name, task, kind in build_tasks(max_examples):
        n = min(len(task), max_examples)
        if h0:
            print(f"\n[eval] === {name} ({kind}, n={n}) ===", flush=True)
        if kind == "categorical":
            acc, tot = eval_categorical(model, task, tok_info, cfg, head_dim, n, bs, data_sharding, local_rows)  # fmt: off
        else:
            acc, tot = eval_generative(model, task, tok_info, cfg, head_dim, n, bs, max_new, data_sharding, local_rows)  # fmt: off
        results[name] = (acc, tot)
        if h0:
            print(f"[eval] {name}: acc={acc:.4f} (n={tot})", flush=True)
            run.log({f"eval/{label}/{name}_acc": acc, f"eval/{label}/{name}_n": tot})

    if h0:
        print(f"\n===== EVAL SUMMARY [{label}] =====", flush=True)
        for name, (acc, tot) in results.items():
            print(f"  {name:16s} {acc:.4f}  (n={tot})", flush=True)
            run.summary[f"eval_{label}_{name}_acc"] = acc
        if results:
            macro = sum(a for a, _ in results.values()) / len(results)
            print(f"  {'MACRO_AVG':16s} {macro:.4f}", flush=True)
            run.summary[f"eval_{label}_macro_avg"] = macro
        run.finish()
    print("[eval] done. Reached maximum training steps", flush=True)
