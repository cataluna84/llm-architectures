# llm-architectures

A personal research base for building scalable LLM architectures from scratch in **pure JAX** — starting from nanoGPT and expanding toward MoE and RL post-training, with a Cloud TPU (v6e) launch/ops toolchain.

> **Credits & attribution.** The nanoGPT implementation in this repository is **seeded from
> [AakashKumarNain/nanoGPTJAX](https://github.com/AakashKumarNain/nanoGPTJAX)**. This is *not* a GitHub
> fork — the code was copied and is being extended under a different scope. Full credit for the original
> pure-JAX nanoGPT design and implementation goes to that project and its author; the original `LICENSE`
> and `NOTICE` are preserved. See also the upstream links in [References](#references).

> **📦 Trained weights:** [`cataluna84/nanogpt-jax-181m`](https://huggingface.co/cataluna84/nanogpt-jax-181m)
> — 181M params, both the pretrained base (val **3.1271**) and the instruction-tuned
> SFT checkpoint (val **1.4365**). Sampling runs on **CPU**; no accelerator required.

---

## nanoGPTJAX

This project is inspired by Karpathy's [nanoGPT](https://github.com/karpathy/nanoGPT) and [nanochat](https://github.com/karpathy/nanochat), with one major difference: here we build everything from scratch in **pure JAX (on both GPUs and TPUs)**, avoiding higher-level third-party model/training libraries. This is not meant to start another PyTorch vs. JAX debate—I use both on a daily basis, and both are good in their own right. There are a few reasons I keep using JAX:

1. I am not a fan of the OOP paradigm for deep learning. It is often nice to have, but not required.
2. Nothing comes close to distributed training in JAX. The mental model is simple and fits well with the philosophy of having control over every design aspect of a training run.
3. Reproducibility is a first-class citizen in JAX.
4. I like having fine-grained control over implementation and performance details without fighting framework abstractions.

It is recommended to read the [design philosophy](docs/design.md) to better understand how this works under the hood. <br>

## Architecture

We follow the standard Transformer architecture, with the following choices:

- Grouped Query Attention (GQA)
- No weight tying
- RoPE
- QK-Norm
- Logits soft-capping
- ReLU-squared activations in the MLP/SwiGLU
- RMSNorm without learnable parameters
- Muon/AdamW

The models here can be trained with both `AdamW` and `Muon` optimizers (via Optax). You can use any sharding strategy depending on the size of the model. We use the cached, tokenized **FineWeb10B** dataset as in [modded-nanogpt](https://github.com/KellerJordan/modded-nanogpt).


## Tasks

- [x] Minimal abstraction for defining layers and models
- [x] Pretrain a GPT-2-like model on FineWeb 10B tokens
- [x] Inference and KVCache
- [x] Cautious Weight Decay
- [x] Chunked Cross Entropy
- [x] Mid-training
- [x] Supervised fine-tuning on a dataset
- [x] RoPE-NoPE (local-global attention) pattern
- [x] Post Training Quantization (Weights only int8 quantization for now)
- [ ] Reinforcement learning on a dataset
- [ ] Speculative Decoding
- [ ] MoE example

<br>

## Getting Started

1. Install uv
```
curl -LsSf https://astral.sh/uv/install.sh | sh
uv --version
```

2. Create a `venv`
```
uv venv --python 3.12
source .venv/bin/activate
```

3. Install dependencies
```
uv sync

# If you are running the code on GPUs, run this instead:
uv sync --all-extras
```

4. Prepare the dataset for pretraining
```
# Download the dataset
python nanogpt/download_fineweb_tokens.py
```

5. (Optional) Experiment tracking with Weights & Biases

Training (`train.py`) and SFT (`train_sft.py`) log to [wandb.ai](https://wandb.ai)
out of the box. Put your credentials in a `.env` at the repo root (gitignored):
```
WANDB_API_KEY=...          # from https://wandb.ai/authorize
WANDB_PROJECT=llm-architectures
WANDB_ENTITY=<your-username-or-team>
```
Logged per step: `train/loss`, `train/lr`, `perf/tokens_per_sec`,
`perf/step_time_s`; per validation: `val/loss`, `val/best_loss`; and a
leaderboard-shaped run summary (`total_training_time`, `total_training_flops`,
`best_val_loss`). To turn it off or run locally, set one of:
```
WANDB_ENABLED=0            # fully off (no-op)
WANDB_MODE=offline         # local-only, no network (view via `wandb sync` later)
WANDB_MODE=disabled        # off, same as WANDB_ENABLED=0
```
Other knobs: `WANDB_RUN_NAME`, `WANDB_RUN_ID` (resume a run), `WANDB_LOG_INTERVAL`.

6. Train the model
```
# Pass the data dir path in the config file located at `nanogpt/config.py`
# Change the hparams in the file if you want.
python nanogpt/train.py
```

7. (Optional) Fine-tune model on conversational dataset
```
# Prepare the SFT dataset. Change args if you want to
python nanogpt/sft_dataloader.py

# Fine-tune the model using the above data
python nanogpt/train_sft.py
```

8. Run inference by providing the checkpoint path
```
# Change this in the config file. Load the checkpoint 
# that is appropriate for the task (pretrain results/SFT results)
load_ckpt_path = /home/.../params  # absolute path only

# Run the inference code
python nanogpt/inference.py
```
<br>

## Results

#### Pretraining

After pretraining the model on first 30 shards of Fineweb10B tokens, here are some sample outputs from the mode:

```
temperature = 0.8
top_k = 100
max_new_tokens = 50
prompts = [
        "<|endoftext|>Did you notice that this world",
        "<|endoftext|>Hello World! My dear",
        "<|endoftext|>Some say we are tired far",
        "<|endoftext|>The capital of France",
    ]


Completions:

<|endoftext|>Did you notice that this world is filled with so many people and so many ideas?
Well, I’m going to tell you about a few of them that I personally love.
One is an article written for a few local blogs, one is for a national magazine

<|endoftext|>Hello World! My dear friend,
This is my first post in a while. I’m glad that I have found such amazing blog because this is really a place I would visit.
If you haven’t read my past post, you’ll

<|endoftext|>Some say we are tired far too easily. It’s true that we often feel tired and defeated when we’re not getting the right treatment.
But the good news is that you can get the right treatment and get the right life.
You don’

<|endoftext|>The capital of France, Paris, is the birthplace of many art treasures. The city has a rich history of art and architecture, and a beautiful
city park is a place to relax and enjoy the peace. The city also features a number of historical buildings and museums, which
```
<br>

#### Midtrain/SFT

Warm-started from the 10k pretraining checkpoint and fine-tuned for **one epoch**
(844 steps, 442M tokens) on packed smoltalk + MMLU + GSM8K with completion-only
loss. Best val **1.4365** at step 800, down from 1.596.

```
prompt:

<|endoftext|><|user_start|>What are the benefits of regular exercise? Your response should contain at least 3 sentences. Include keywords such as "health", "reduce", and "improve".
<|user_end|>
<|assistant_start|>


completion:

Regular exercise offers numerous health benefits, particularly improved cardiovascular health and a longer lifespan. Research has shown that regular physical activity can improve cognitive function, enhance mood, and contribute to overall well-being. This could be particularly beneficial for individuals with chronic diseases or conditions that affect daily activities. Additionally, regular exercise can have a positive impact on mental health, reducing symptoms of depression and anxiety.<|assistant_end|>
```

The model follows the instruction: three-plus sentences as asked, all three
requested keywords present, and it emits `<|assistant_end|>` to stop rather than
running on. Reproduce with:

```bash
NANOGPT_MODEL_TYPE=SFT NANOGPT_LOAD_PARAMS_CKPT_PATH=<ckpt>/params python nanogpt/inference.py
```

**Note:**

1. For the base version (12 layers), we fine-tuned it on a small dataset (smoltalk, MMLU, GSM8K) with *completion-only* training.
2. For SFT, we use Adam with no weight decay instead of Muon. 
<br>

## Benchmarking 

As of now without using any tricks, the training loss converges in around ~16 minutes on `4 X H100` machine. The dataloader is not optimal,
we have not included gradient accumulation, we have not used any tricks to improve the convergence. Still, 16 minutes is neither bad nor great.
I am sure we can do it in under 5-8 minutes soon without using many tricks. 🤞

### TPU baseline — 10k steps (2026-07-25)

181M parameters (GQA, 16 layers, d=768, 8 Q heads / 4 KV heads), trained on
FineWeb10B at **524,288 tokens/step** for 10,000 steps on a **v5e-32**
(8 hosts x 4 chips, `grad_accum_steps=2`), bfloat16, Muon + AdamW.

| Metric | Value |
| --- | --- |
| Best val loss | **3.1271** @ step 9919 |
| MFU | 25.06% |
| Throughput | 1,137,868 tok/s |
| Step time (p50) | 0.4605 s |
| Wall clock | 97.5 min |
| Total tokens | 5.24B |
| Total FLOPs | 5.696e18 |
| HBM peak | 2.17 / 15.75 GiB |

Recipe: peak LR 0.02, Muon momentum warmup 0.85→0.95 over 300 steps, embedding
LR 0.3, unembedding LR 0.002, cautious weight decay 0.2, grad clip 0.5, WSD
schedule with 0.65 warmdown fraction. Selected by a 43-run sweep — see
[`docs/sweeps/v5e64-2026-07/report.md`](docs/sweeps/v5e64-2026-07/report.md).

Base-model evals (200 examples/task, pre-SFT) are **at chance**: MMLU 0.230,
ARC-easy 0.245, ARC-challenge 0.285, GSM8K 0.000 (chance 0.25, SE ±0.031). This
is expected at 181M parameters and 5.2B tokens — the numbers are a pre-SFT floor
to measure SFT against, not a capability claim.

[W&B run](https://wandb.ai/cataluna84/llm-architectures/runs/v5e32-baseline-10k-clean) ·
[eval run](https://wandb.ai/cataluna84/llm-architectures/runs/eval-base-v5e32-10k-clean)

### SFT (one epoch, v5e-64)

| Metric | Value |
| --- | --- |
| Best val loss | **1.4365** @ step 800 |
| Steps / tokens | 844 (one epoch) / 442M |
| MFU / throughput | 26.5% / 2,405,515 tok/s |
| Wall clock | 6.3 min |

Post-SFT evals are unchanged within noise (MMLU 0.210, ARC-e 0.200, ARC-c 0.260,
GSM8K 0.000; SE ±0.031 at n=200) — expected at this scale, since SFT teaches
format rather than knowledge. The measurable change is the loss and the
generation behaviour shown above.

Sweep methodology and the per-knob effect sizes behind this recipe:
[`docs/training.md`](docs/training.md) and
[`docs/sweeps/v5e64-2026-07/report.md`](docs/sweeps/v5e64-2026-07/report.md).

## Project status

The full pipeline has been run end to end on Google TRC TPU and is **complete**:
sweep → pretraining → base evals → SFT → post-SFT evals. The TPU grant ended
2026-07-26, and **all TPU and GCS resources for this project have been released**.

| Stage | Result |
| --- | --- |
| Sweep v2 (43 runs, v5e-64) | composed recipe, −18σ vs baseline |
| Pretraining 10k, v5e-32 | val **3.1271** · 25.1% MFU · 1.14M tok/s · 5.24B tokens |
| Base evals (200 ex/task) | MMLU .230 · ARC-e .245 · ARC-c .285 · GSM8K .000 |
| SFT 1 epoch, v5e-64 | val **1.4365** · 26.5% MFU · 2.41M tok/s · 442M tokens |
| Post-SFT evals | MMLU .210 · ARC-e .200 · ARC-c .260 · GSM8K .000 |

Both models sit **at chance** on the multiple-choice benchmarks and every
post-SFT delta is inside noise (SE ±0.031 at n=200). That is the expected
outcome at 181M params on 5.24B tokens — SFT teaches format and turn-taking,
which accuracy benchmarks do not measure. What did move is the loss
(val 1.596 → 1.4365) and the generation behaviour shown in
[Midtrain/SFT](#midtrainsft) above.

### What is preserved

| Artifact | Where |
| --- | --- |
| Base + SFT weights | [HF `cataluna84/nanogpt-jax-181m`](https://huggingface.co/cataluna84/nanogpt-jax-181m) |
| All metrics and curves | [W&B `cataluna84/llm-architectures`](https://wandb.ai/cataluna84/llm-architectures) |
| Methodology and effect sizes | [`docs/training.md`](docs/training.md), [`docs/sweeps/v5e64-2026-07/report.md`](docs/sweeps/v5e64-2026-07/report.md) |

Optimizer and dataloader state were **not** published, so training can be
restarted from the released params but not resumed mid-run. The SFT parquet is
regenerable in a few minutes via `nanogpt/sft_dataloader.py`.

### Sampling the released model (no TPU needed)

```bash
uv sync
huggingface-cli download cataluna84/nanogpt-jax-181m --local-dir ./ckpts

# instruction-tuned: chat-formatted, stops on <|assistant_end|>
NANOGPT_MODEL_TYPE=SFT \
NANOGPT_LOAD_PARAMS_CKPT_PATH=./ckpts/sft/params \
python nanogpt/inference.py

# base: raw continuation
NANOGPT_MODEL_TYPE=pretrained \
NANOGPT_LOAD_PARAMS_CKPT_PATH=./ckpts/base/params \
python nanogpt/inference.py
```

Checkpoints are **Orbax** directories, not `transformers` weights — load them
with this repo's code, not `AutoModel`. Reproducing the training runs requires
your own accelerator and a FineWeb10B download; the TPU launch scripts under
`scripts/tpu/` are preserved and documented but are no longer pointed at a live
grant.

## Contributing

Contributions are welcome. Apart from bug fixes, the task list above is a good start for contributions.

- **Before you start:** Please open an issue to discuss significant changes (new features, refactors, training pipeline changes).
- **Branching:** Create a feature branch from `main` (e.g., `feat/<name>` or `fix/<name>`).
- **Testing:** If you add or change functionality, include minimal tests or a small reproducible script to validate the change.
- **Pull requests:** In your PR description, include (1) what changed, (2) why it changed, and (3) how to reproduce/verify. <br>

We use `ruff` for linting and formatting. You can either manually run `ruff check nanogpt/*.py` and `ruff format nanogpt/*.py` before sending a PR or you can
install `pe-commit` and will do the job for you. To install pre-commit, use the following command:

```
uv tool install pre-commit --with pre-commit-uv
```

## References

This work would not have been possible without these existing resources:

- [modded-nanogpt](https://github.com/KellerJordan/modded-nanogpt)
- [nanoGPT](https://github.com/karpathy/nanoGPT)
- [nanochat](https://github.com/karpathy/nanochat)
- [JAX LLM Examples](https://github.com/jax-ml/jax-llm-examples/tree/main)
- [JAX Scaling Book](https://jax-ml.github.io/scaling-book/)
- [JAX Tutorials](https://www.kaggle.com/code/aakashnain/tf-jax-tutorials-part-4-jax-and-devicearray)