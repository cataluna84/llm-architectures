"""Generate the hardware-specific hyperparameter report from W&B.

Pulls every run of the sweep2-v5e64 program (group `sweep2-v5e64`, plus the
named stage-0/1 runs that predate grouping) and emits
docs/sweeps/v5e64-2026-07/report.md — the "described in literature vs
practically best on this hardware" record. Reruns are idempotent: output is
ordered deterministically so the file is byte-stable for identical inputs.

Usage:  uv run python scripts/sweep_report.py
"""

from __future__ import annotations

import os
import statistics
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "docs" / "sweeps" / "v5e64-2026-07" / "report.md"
ENTITY_PROJECT = "cataluna84/llm-architectures"
GROUP = "sweep2-v5e64"

# Stage-0/1 runs created before WANDB_RUN_GROUP existed, adopted by name.
LEGACY_NAMES = {
    "v5e64-lrsweep-020": ("lr", 0.020),
    "v5e64-lrsweep-020-s1": ("lr", 0.020),
    "v5e64-lrsweep-020-s2": ("lr", 0.020),
    "v5e64-lrsweep-028": ("lr", 0.028),
    "v5e64-lrsweep-028-s1": ("lr", 0.028),
    "v5e64-lrsweep-028-s2": ("lr", 0.028),
    "v5e64-lrsweep-014": ("lr", 0.014),
    "v5e64-lrsweep-020-nomom": ("momwu", 0),
}

# The literature column: axis -> (claimed value, source). The report's whole
# point is comparing this column against what this hardware measured.
PROVENANCE = {
    "lr": ("0.02", "nanochat matrix_lr; Muon README (muP-scaled)"),
    "momwu": ("300 steps, 0.85->0.95", "nanochat momentum warmup"),
    "mommax": ("0.95", "Muon README: 'defaults work well'"),
    "emblr": ("0.2", "nanochat embedding_lr (Adam, width-scaled)"),
    "unemb": ("0.004", "nanochat unembedding_lr; most LR-sensitive group per Scion norm-transfer"),
    "warmup": ("min(300, 1% of steps)", "repo default (nanochat-ish)"),
    "cwd": ("0.01", "modded-nanogpt cautious weight decay"),
    "adamb": ("b1=0.8, b2=0.95", "nanochat adam_betas (sharp optima in their probes)"),
    "clip": ("1.0", "GPT-3 lineage global-norm clip"),
    "accum": ("accum=1 (bsz 4x64)", "B_ref-derived; numerics control vs accum=2"),
    "mudtype": ("float32", "repo default Muon momentum buffer"),
    "ns": ("5", "Muon README / Newton-Schulz writeup"),
    "schedule": ("cosine (repo) vs WSD 0.65-0.85", "nanochat Run 7 trapezoid"),
    "lr-horizon": ("LR* ~ D^-0.32", "Scaling Optimal LR Across Token Horizons (ICLR'25)"),
    "failenv": ("n/a — deliberate breakage", "failure-envelope mapping"),
    "seeds": ("n/a — noise floor", "Time-Transfer 2024: LR optimum moves ~2x on seed"),
}

BASELINE_ARM = ["v5e64-lrsweep-020", "v5e64-lrsweep-020-s1", "v5e64-lrsweep-020-s2"]


def fetch_runs():
    import wandb

    api = wandb.Api()
    out = {}
    for r in api.runs(ENTITY_PROJECT, order="+created_at"):
        if r.group == GROUP or r.name in LEGACY_NAMES:
            s, c = r.summary, r.config
            job = r.job_type or (LEGACY_NAMES.get(r.name) or ("?", None))[0]
            out[r.name] = {
                "name": r.name,
                "job": job,
                "state": r.state,
                "url": r.url,
                "seed": c.get("init_seed", 0),
                "best": s.get("best_val_loss"),
                "best_step": s.get("best_step"),
                "diverged": bool(s.get("diverged")),
                "diverged_at": s.get("diverged_at_step"),
                "spikes": s.get("loss_spikes"),
                "p50": s.get("p50_step_time"),
                "p99": s.get("p99_step_time"),
                "hbm_pct": s.get("hbm_util_pct"),
                "config": {
                    k: c.get(k)
                    for k in (
                        "other_peak_lr", "embedding_lr", "unembedding_lr",
                        "cautious_weight_decay", "adam_b1", "adam_b2",
                        "grad_clip_norm", "warmup_steps", "ns_steps",
                        "mu_dtype", "lr_schedule", "wsd_warmdown_frac",
                        "muon_momentum_max", "muon_momentum_warmup_steps",
                        "grad_accum_steps",
                    )
                },
            }
    return out


def main() -> None:
    # .env for WANDB_API_KEY (same dependency-free loader as the trainer).
    env = REPO / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

    runs = fetch_runs()
    baseline = [runs[n]["best"] for n in BASELINE_ARM if n in runs and runs[n]["best"]]
    base_mean = statistics.mean(baseline) if baseline else float("nan")
    sigma = statistics.stdev(baseline) if len(baseline) > 2 else 0.0016
    bar = 2 * sigma

    by_job = defaultdict(list)
    for r in sorted(runs.values(), key=lambda x: x["name"]):
        by_job[r["job"]].append(r)

    L = []
    L.append("# v5e-64 hyperparameter report — described vs measured")
    L.append("")
    L.append("Auto-generated by `scripts/sweep_report.py` from W&B group "
             f"`{GROUP}` (+ pre-group stage-1 runs). Do not hand-edit.")
    L.append("")
    L.append("## Method")
    L.append("")
    L.append("- Slice: v5litepod-64, 16 hosts x 4 chips, DDP, accum=1, bf16.")
    L.append("- Invariants: 524,288 tokens/step; 6,400-row val subset; fixed "
             "data order (seed varies init only).")
    L.append(f"- Noise floor from the seed arm: sigma = {sigma:.4f} -> "
             f"adoption bar 2*sigma = {bar:.4f}.")
    L.append(f"- Baseline arm (LR 0.02, momentum warmup on): mean best-val "
             f"{base_mean:.4f} over n={len(baseline)} seeds.")
    L.append("- Verdicts: MOVED = beats baseline by >2sigma; NOISE-KEPT = "
             "within the bar, literature default stands; CONFIRMED = default "
             "was tested and not beaten; DIVERGED = config left the stable "
             "envelope.")
    L.append("")
    L.append("## Per-axis results")
    L.append("")
    for job in sorted(by_job):
        prov = PROVENANCE.get(job, ("?", "?"))
        L.append(f"### {job}")
        L.append("")
        L.append(f"Literature value: **{prov[0]}** — {prov[1]}")
        L.append("")
        L.append("| run | best val | Δ vs baseline | Δ/σ | spikes | p50/p99 s | verdict |")
        L.append("|---|---|---|---|---|---|---|")
        for r in by_job[job]:
            if r["diverged"]:
                verdict = f"DIVERGED @ step {r['diverged_at']}"
                delta = ds = "—"
                best = f"{r['best']:.4f}" if r["best"] and r["best"] != float("inf") else "inf"
            elif r["best"] is None:
                verdict, delta, ds, best = r["state"], "—", "—", "—"
            else:
                d = r["best"] - base_mean
                delta, ds = f"{d:+.4f}", f"{d / sigma:+.1f}σ" if sigma else "—"
                verdict = "MOVED" if d < -bar else ("WORSE" if d > bar else "noise")
                best = f"{r['best']:.4f}"
            p = (f"{r['p50']:.2f}/{r['p99']:.2f}"
                 if r["p50"] and r["p99"] else "—")
            L.append(
                f"| [{r['name']}]({r['url']}) | {best} | {delta} | {ds} | "
                f"{r['spikes'] if r['spikes'] is not None else '—'} | {p} | {verdict} |"
            )
        L.append("")

    L.append("## Run inventory")
    L.append("")
    L.append("| run | axis | state | seed | best val | url |")
    L.append("|---|---|---|---|---|---|")
    for r in sorted(runs.values(), key=lambda x: (x["job"], x["name"])):
        best = f"{r['best']:.4f}" if isinstance(r["best"], float) and r["best"] != float("inf") else "—"
        L.append(f"| {r['name']} | {r['job']} | {r['state']} | {r['seed']} | {best} | {r['url']} |")
    L.append("")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(L))
    print(f"wrote {OUT} ({len(runs)} runs, sigma={sigma:.4f})")


if __name__ == "__main__":
    main()
