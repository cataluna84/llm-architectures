"""Thin, from-scratch Weights & Biases wrapper.

The *only* module in the project that imports `wandb`. Training scripts talk to
W&B exclusively through `init_wandb(...)`, which returns an object exposing
`.log()`, `.summary()`, and `.finish()`. When logging is disabled, unauthenticated,
or running on a non-primary host, a no-op object with the same interface is
returned so call sites stay unconditional.

Credentials/config come from the environment (`WANDB_API_KEY`, `WANDB_PROJECT`,
`WANDB_ENTITY`, ...). `load_dotenv()` seeds those from the repo `.env` without a
`python-dotenv` dependency, keeping the "from scratch" ethos.
"""

import os
from pathlib import Path


def load_dotenv(path: str = ".env") -> None:
    """Populate `os.environ` from a `.env` file (dependency-free).

    Parses simple `KEY=VALUE` lines, skipping blanks and `#` comments and
    stripping surrounding single/double quotes. Uses `setdefault`, so a value
    already present in the real environment always wins over the file. Searches
    the given path, then the repo root relative to this file, so it works
    regardless of the current working directory.
    """
    candidates = [Path(path)]
    # Fall back to the repo root (parent of nanogpt/) so `python nanogpt/train.py`
    # from any cwd still finds the project `.env`.
    repo_root_env = Path(__file__).resolve().parent.parent / ".env"
    if repo_root_env not in candidates:
        candidates.append(repo_root_env)

    for candidate in candidates:
        if not candidate.exists():
            continue
        for raw in candidate.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key:
                os.environ.setdefault(key, val)
        # First existing file wins; don't let a later file override it.
        return


def device_peak_flops(default: float = 918e12) -> float:
    """Per-device bf16 peak FLOP/s used to normalize MFU.

    Defaults to ~918 TFLOP/s, the Cloud TPU v6e (Trillium) bf16 peak. Override
    with `NANOGPT_DEVICE_PEAK_FLOPS` for other hardware (e.g. an H100 SXM is
    ~989e12 bf16 without sparsity).
    """
    val = os.environ.get("NANOGPT_DEVICE_PEAK_FLOPS")
    if not val:
        return default
    try:
        return float(val)
    except ValueError:
        return default


def transformer_flops_per_token(
    num_params: int, num_layers: int, d_model: int, seqlen: int
) -> float:
    """Approx train (fwd+bwd) FLOPs per token, Karpathy `estimate_mfu` style.

    `6 * N` is the dense matmul term; `12 * L * d_model * seqlen` adds the
    attention score/value matmuls (which scale with context length). `N` is the
    total parameter count, matching the `total_training_flops` run-summary
    convention so MFU and that summary stay consistent.
    """
    return 6 * num_params + 12 * num_layers * d_model * seqlen


class _NoOpRun:
    """Null-object run: same interface as `WandbRun`, does nothing."""

    def log(self, metrics, step=None):
        pass

    def summary(self, **kv):
        pass

    def finish(self):
        pass


class WandbRun:
    """Wraps a live `wandb` run; every call swallows exceptions.

    A transient network/wandb error must never take down a multi-hour training
    run, so failures are logged once to stdout and otherwise ignored.
    """

    def __init__(self, run):
        self._run = run

    def log(self, metrics, step=None):
        try:
            import wandb

            wandb.log(metrics, step=step)
        except Exception as e:  # pragma: no cover - defensive
            print(f"[wandb] log failed (step={step}): {e}")

    def summary(self, **kv):
        try:
            import wandb

            wandb.run.summary.update(kv)
        except Exception as e:  # pragma: no cover - defensive
            print(f"[wandb] summary update failed: {e}")

    def finish(self):
        try:
            import wandb

            wandb.finish()
        except Exception as e:  # pragma: no cover - defensive
            print(f"[wandb] finish failed: {e}")


def init_wandb(cfg, run_name, config):
    """Initialize a W&B run from `cfg.wandb`, returning a run object.

    Returns a `_NoOpRun` (rather than `None`) when logging should be skipped:
    W&B disabled in config, running on a non-primary host (multi-host TPU), or
    online mode with no `WANDB_API_KEY`. This keeps every call site free of
    `if run is not None` guards.

    Args:
        cfg: the project `Config` (reads `cfg.wandb`).
        run_name: default run name (used unless `WANDB_RUN_NAME` overrides).
        config: dict of hyperparameters recorded as the run's config.
    """
    import jax

    load_dotenv()
    # Deploy scripts export WANDB_* unconditionally, so unset knobs arrive as
    # empty strings. Our config treats empty as unset, but the wandb library
    # reads these raw and chokes (e.g. WANDB_RUN_ID="" -> "Run ID cannot be
    # empty"). Scrub empties so both layers agree.
    for key in (
        "WANDB_RUN_ID",
        "WANDB_RUN_NAME",
        "WANDB_NAME",
        "WANDB_MODE",
        "WANDB_RUN_GROUP",
        "WANDB_JOB_TYPE",
    ):
        if key in os.environ and not os.environ[key]:
            del os.environ[key]
    wcfg = cfg.wandb

    if not wcfg.enabled:
        print("[wandb] disabled via config — logging is a no-op")
        return _NoOpRun()

    if jax.process_index() != 0:
        # Only the primary host logs on multi-host setups.
        return _NoOpRun()

    online = wcfg.mode not in ("offline", "disabled")
    if online and not os.environ.get("WANDB_API_KEY"):
        print(
            "[wandb] no WANDB_API_KEY found (set it in .env or the environment) — "
            "logging is a no-op. Use WANDB_MODE=offline for local-only runs."
        )
        return _NoOpRun()

    try:
        import wandb

        run = wandb.init(
            project=wcfg.project or None,
            entity=wcfg.entity or None,
            name=wcfg.run_name or run_name,
            id=wcfg.run_id or None,
            resume=("allow" if wcfg.run_id else None),
            mode=wcfg.mode,
            config=config,
            dir=wcfg.dir or None,
            settings=wandb.Settings(console="off"),
        )
        print(f"[wandb] run initialized: {getattr(run, 'url', None) or '(offline)'}")
        return WandbRun(run)
    except Exception as e:
        print(f"[wandb] init failed ({e}) — continuing without logging")
        return _NoOpRun()
