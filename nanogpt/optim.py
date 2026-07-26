import jax
import optax
import jax.numpy as jnp
from jax.tree_util import GetAttrKey, SequenceKey, DictKey


def build_optimizer(
    params,
    *,
    d_model: int,
    other_peak_lr: float,
    other_min_lr: float,
    total_train_steps: int,
    warmup_steps: int = 30,
    b1: float = 0.9,
    b2: float = 0.95,
    embedding_lr: float = 0.2,
    unembedding_lr: float = 0.004,
    weight_decay: float = 0.0,
    cautious_weight_decay: float = 0.01,
    use_muon=True,
    muon_momentum_min: float = 0.85,
    muon_momentum_max: float = 0.95,
    muon_momentum_warmup_steps: int = 300,
    ns_steps: int = 5,
    mu_dtype: str = "",
    lr_schedule: str = "cosine",
    wsd_warmdown_frac: float = 0.65,
):
    # nanochat's width scaling for AdamW groups: (d_model / 768) ** -0.5
    dmodel_lr_scale = (d_model / 768.0) ** -0.5

    # use width scaling for embed/lm_head; do not tie to other_peak_lr
    emb_lr = embedding_lr * dmodel_lr_scale
    unemb_lr = unembedding_lr * dmodel_lr_scale

    if use_muon:
        print("Using Muon Optimizer!")

    if lr_schedule == "wsd":
        # Warmup -> constant -> linear warmdown over the final
        # wsd_warmdown_frac of training (nanochat's trapezoid). Their Run 7
        # evidence: warmdown shape matters at longer horizons.
        wu = max(1, warmup_steps)
        warmdown_steps = max(1, int(total_train_steps * wsd_warmdown_frac))
        stable_steps = max(0, total_train_steps - wu - warmdown_steps)
        other_schedule = optax.join_schedules(
            [
                optax.linear_schedule(other_min_lr, other_peak_lr, wu),
                optax.constant_schedule(other_peak_lr),
                optax.linear_schedule(other_peak_lr, other_min_lr, warmdown_steps),
            ],
            boundaries=[wu, wu + stable_steps],
        )
    else:
        other_schedule = optax.warmup_cosine_decay_schedule(
            init_value=other_min_lr,
            peak_value=other_peak_lr,
            warmup_steps=warmup_steps,
            decay_steps=max(1, total_train_steps - warmup_steps),
            end_value=other_min_lr,
        )

    schedules = {
        "embed": optax.constant_schedule(emb_lr),
        "lm_head": optax.constant_schedule(unemb_lr),
        "other": other_schedule,
    }

    def _path_names(path):
        out = []
        for k in path:
            if isinstance(k, GetAttrKey):
                out.append(k.name)
            elif isinstance(k, SequenceKey):
                out.append(str(k.idx))
            elif isinstance(k, DictKey):
                out.append(str(k.key))
            else:
                out.append(str(k))
        return out

    def label_fn(path, leaf):
        # Top-level fields in GPT pytree: embed, blocks, lm_head
        names = _path_names(path)
        top = names[0] if names else ""
        if top == "embed":
            return "embed"
        if top == "lm_head":
            return "lm_head"
        return "other"

    def make_weight_dim_nums(p):
        def choose(x):
            s = getattr(x, "shape", None)
            if s is None:
                return None
            if len(s) == 2:
                return optax.contrib.MuonDimensionNumbers((0,), (1,))
            if len(s) == 3:
                # wo: (heads, head_dim, d_model)
                if s[-1] == d_model:
                    return optax.contrib.MuonDimensionNumbers((1,), (2,))
                # wq/wk/wv: batch=heads
                return optax.contrib.MuonDimensionNumbers((0,), (2,))
            return None

        return jax.tree_util.tree_map(choose, p)

    def weight_decay_mask_fn(p):
        def keep(x):
            s = getattr(x, "shape", None)
            return s is not None and len(s) >= 2

        return jax.tree_util.tree_map(keep, p)

    def cautious_decay(schedule, wd):
        def init_fn(params):
            return {"count": jnp.array(0, dtype=jnp.int32)}

        def update_fn(updates, state, params=None):
            step = state["count"]
            scale = schedule(step)
            if params is None:
                return updates, {"count": step + 1}

            def apply_updates(update, param):
                if param is None:
                    return update
                s = getattr(param, "shape", None)
                eligible_for_update = (s is not None) and (len(s) >= 2)
                if not eligible_for_update:
                    return update
                # Cautious: only decay when update and param are aligned (same sign)
                decay = jnp.where(
                    (update * param) >= 0,
                    param.astype(update.dtype),
                    jnp.zeros_like(update),
                )
                # Subtract to apply weight decay (moves parameters toward zero)
                return update - (scale * wd) * decay

            new_updates = jax.tree_util.tree_map(apply_updates, updates, params)
            return new_updates, {"count": step + 1}

        return optax.GradientTransformation(init_fn, update_fn)

    param_labels = jax.tree_util.tree_map_with_path(label_fn, params)
    muon_weight_dim_nums = make_weight_dim_nums(params)
    muon_wd_mask = weight_decay_mask_fn(params)

    def make_adamw(schedule_fn, weight_decay=0.0):
        return optax.adamw(
            learning_rate=schedule_fn,
            b1=b1,
            b2=b2,
            eps=1e-10,  # for better stability like nanochat/modded-nanogpt
            weight_decay=weight_decay,
            mu_dtype=jnp.float32,
        )

    def make_muon(schedule_fn, weight_decay=0.0):
        # nanochat-style momentum warmup: beta ramps muon_momentum_min ->
        # muon_momentum_max over the first muon_momentum_warmup_steps optimizer
        # steps. optax's muon only takes beta as a plain float, so the schedule
        # goes through inject_hyperparams; warmup_steps=0 keeps the plain path
        # (and the optim-state structure of checkpoints saved before this).
        if muon_momentum_warmup_steps > 0:
            factory = optax.inject_hyperparams(
                optax.contrib.muon,
                # ns_steps slices ns_coeffs at init time and must stay
                # concrete; mu_dtype is a callable class that inject would
                # otherwise wrap as a schedule; float32 because the
                # injected-hyperparam dtype otherwise follows the bf16 params
                # and would quantize the lr/beta schedules.
                static_args=("ns_steps", "mu_dtype"),
                hyperparam_dtype=jnp.float32,
            )
            beta = optax.linear_schedule(
                init_value=muon_momentum_min,
                end_value=muon_momentum_max,
                transition_steps=muon_momentum_warmup_steps,
            )
        else:
            factory = optax.contrib.muon
            beta = muon_momentum_max
        return factory(
            learning_rate=schedule_fn,
            ns_coeffs=(3.4445, -4.775, 2.0315),
            ns_steps=ns_steps,
            beta=beta,
            eps=1e-8,
            weight_decay=0.0,
            weight_decay_mask=muon_wd_mask,
            mu_dtype=jnp.dtype(mu_dtype) if mu_dtype else jnp.float32,
            nesterov=True,
            adaptive=False,
            adam_b1=b1,
            adam_b2=b2,
            adam_eps_root=0.0,
            adam_weight_decay=weight_decay,
            muon_weight_dimension_numbers=muon_weight_dim_nums,
            consistent_rms=None,
        )

    tx = optax.multi_transform(
        {
            "embed": make_adamw(schedules["embed"]),
            "lm_head": make_adamw(schedules["lm_head"]),
            "other": (
                optax.chain(
                    make_muon(schedules["other"], weight_decay=weight_decay),
                    cautious_decay(schedules["other"], cautious_weight_decay),
                )
                if use_muon
                else optax.chain(
                    make_adamw(schedules["other"], weight_decay=weight_decay),
                    cautious_decay(schedules["other"], cautious_weight_decay),
                )
            ),
        },
        param_labels,
    )

    # Also return the per-group LR schedules so callers can log the current LR
    # (e.g. wandb `train/lr`). `schedules["other"]` is the warmup-cosine schedule
    # driving the main Muon group.
    return tx, schedules
