"""Supporting figures for docs/REPORT.md, written to docs/img/report/.

    uv run --with 'matplotlib==3.10.*' python bench/figures.py
"""
import csv
import glob
import json
import os
import statistics
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter, PercentFormatter

sys.path.insert(0, os.path.dirname(__file__))
from chart import GRID, INK, INK_2, SURFACE  # noqa: E402

BLUE, ORANGE, AQUA, YELLOW = "#2a78d6", "#eb6834", "#1baf7a", "#eda100"  # validated slots 1-4
OUT = "docs/img/report"
ms_fmt = FuncFormatter(lambda v, _: f"{v:,.0f}")


def style():
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 9, "text.color": INK,
                         "axes.labelcolor": INK_2, "xtick.color": INK_2, "ytick.color": INK_2})


def frame(ax, grid_axis="y"):
    ax.set_facecolor(SURFACE)
    ax.grid(axis=grid_axis, color=GRID, linewidth=0.6, zorder=0)
    ax.tick_params(length=0)
    for side in ("top", "right", "left", "bottom"):
        ax.spines[side].set_visible(False)


def titled(fig, title, subtitle, top):
    fig.patch.set_facecolor(SURFACE)
    fig.suptitle(title, x=0.06, ha="left", fontsize=12, fontweight="bold", y=0.985)
    fig.text(0.06, top, subtitle, fontsize=8, color=INK_2)


def rows(scenario, run):
    return list(csv.DictReader(open(f"results/{scenario}/run{run}.csv")))


def counter_totals(scenario):
    """Sum vLLM counters over every run (and endpoint) of a scenario."""
    tot = {}
    for f in glob.glob(f"results/{scenario}/run*.json"):
        d = json.load(open(f))["counter_delta"]
        for part in [d] if "vllm:prompt_tokens_total" in d else d.values():
            for k, v in part.items():
                tot[k] = tot.get(k, 0) + v
    return tot


def per_request(run=2):
    """Every request of one run, scenario 3 vs 4, in send order."""
    fig, axes = plt.subplots(1, 2, figsize=(8, 3.6), dpi=200, sharey=True)
    colours = {"first": BLUE, "resident": ORANGE, "evicted": AQUA}
    names = {"first": "First question", "resident": "Repeat, asked right after", "evicted": "Revisit after 19 other documents"}
    for ax, (scenario, title) in zip(axes, [("s3-gpu-pressure", "3. GPU prefix cache only"),
                                            ("s4-cpu-tier", "4. + LMCache CPU tier")]):
        frame(ax)
        data = rows(scenario, run)
        for kind in ("first", "resident", "evicted"):
            pts = [(int(r["seq"]), float(r["ttft_ms"])) for r in data if r["expected"] == kind]
            ax.scatter(*zip(*pts), s=16, color=colours[kind], edgecolors=SURFACE, linewidths=0.8,
                       zorder=3, label=names[kind])
        ax.axvline(39.5, color=GRID, linewidth=1, zorder=1)
        ax.text(19.5, 1640, "Pass 1: Q0, Q1", ha="center", fontsize=7.5, color=INK_2)
        ax.text(59.5, 1640, "Pass 2: Q2, Q3", ha="center", fontsize=7.5, color=INK_2)
        ax.set_title(title, loc="left", fontsize=9, fontweight="bold", pad=14)
        ax.set_xlabel("Request number (sent one at a time)")
        ax.set_ylim(0, 1700)
        ax.yaxis.set_major_formatter(ms_fmt)
    axes[0].set_ylabel("Time to first token, ms")
    axes[1].annotate("Revisits: 68 ms", (60, 68), xytext=(64, 520), fontsize=8, color=INK,
                     arrowprops={"arrowstyle": "-", "color": INK_2, "linewidth": 0.8})
    axes[0].annotate("Revisits: 1,449 ms", (60, 1449), xytext=(46, 1100), fontsize=8, color=INK,
                     arrowprops={"arrowstyle": "-", "color": INK_2, "linewidth": 0.8})
    axes[0].legend(loc="lower left", bbox_to_anchor=(0, 1.13), ncol=3, frameon=False, fontsize=8,
                   handletextpad=0.2, columnspacing=1.2, markerscale=1.4)
    titled(fig, "Every request, scenario 3 vs 4", f"Run {run} of 3, 80 requests each. "
           "Each document: Q0 then Q1 in pass 1; Q2 then Q3 in pass 2, after all 19 other documents.", 0.905)
    fig.subplots_adjust(left=0.1, right=0.98, top=0.7, bottom=0.14, wspace=0.08)
    fig.savefig(f"{OUT}/per-request-s3-s4.png", facecolor=SURFACE)


def token_sources():
    """Share of prompt tokens computed vs served from each cache, per scenario."""
    scenarios = [("s1-no-cache", "1. No cache"), ("s2-gpu-cache", "2. GPU prefix cache"),
                 ("s3-gpu-pressure", "3. GPU cache, overflowed"), ("s4-cpu-tier", "4. + CPU tier"),
                 ("s5-shared", "5. Shared store (Redis)")]
    fig, ax = plt.subplots(figsize=(8, 3.3), dpi=200)
    frame(ax, grid_axis="x")
    for i, (scenario, _) in enumerate(scenarios):
        t = counter_totals(scenario)
        total = t["vllm:prompt_tokens_total"]
        gpu = t.get("vllm:prefix_cache_hits_total", 0) / total
        ext = t.get("vllm:external_prefix_cache_hits_total", 0) / total
        parts = [(1 - gpu - ext, BLUE), (gpu, ORANGE), (ext, AQUA)]
        left = 0
        for share, colour in parts:
            if share > 0:
                ax.barh(i, share - 0.004, left=left + 0.002, height=0.55, color=colour, zorder=3)
                if share >= 0.08:
                    ax.text(left + share / 2, i, f"{share:.0%}", ha="center", va="center", fontsize=8,
                            color="#ffffff" if colour == BLUE else INK, fontweight="bold", zorder=4)
            left += share
    ax.set_yticks(range(len(scenarios)), [n for _, n in scenarios])
    ax.invert_yaxis()
    ax.set_xlim(0, 1)
    ax.xaxis.set_major_formatter(PercentFormatter(1.0, decimals=0))
    handles = [plt.Rectangle((0, 0), 1, 1, color=c) for c in (BLUE, ORANGE, AQUA)]
    ax.legend(handles, ["Computed (prefill)", "GPU prefix cache hit", "Loaded by LMCache (RAM or shared store)"],
              loc="lower left", bbox_to_anchor=(-0.27, 1.02), ncol=3, frameon=False, fontsize=8,
              handlelength=1, handleheight=1)
    titled(fig, "Where prompt tokens came from", "vLLM counters summed over 3 runs per scenario. "
           "75% is the ceiling here: each document's first read must be computed.", 0.9)
    fig.subplots_adjust(left=0.25, right=0.97, top=0.72, bottom=0.1)
    fig.savefig(f"{OUT}/token-sources.png", facecolor=SURFACE)


def shared_store_bug():
    """Scenario 5 with the chart's lmcache_server (broken) vs Redis."""
    def medians(scenario):  # median of the three runs' medians, as in results/summary.md
        per_run = {}
        for run in (1, 2, 3):
            by_kind = {}
            for r in rows(scenario, run):
                by_kind.setdefault(r["expected"], []).append(float(r["ttft_ms"]))
            for k, v in by_kind.items():
                per_run.setdefault(k, []).append(statistics.median(v))
        return {k: statistics.median(v) for k, v in per_run.items()}
    broken, redis = medians("bug-s5-lmserver"), medians("s5-shared")
    kinds = [("first", "Pod A: first question"), ("cross", "Pod B: same document"), ("resident", "Repeat on either pod")]
    fig, ax = plt.subplots(figsize=(8, 3.4), dpi=200)
    frame(ax)
    w = 0.3
    for i, (kind, _) in enumerate(kinds):
        for j, (vals, colour) in enumerate([(broken, ORANGE), (redis, BLUE)]):
            x = i + (j - 0.5) * w
            ax.bar(x, vals[kind], width=w - 0.02, color=colour, zorder=3)
            ax.annotate(f"{vals[kind]:,.0f} ms", (x, vals[kind]), xytext=(0, 3), textcoords="offset points",
                        ha="center", fontsize=8, color=INK, fontweight="bold")
    ax.set_xticks(range(len(kinds)), [n for _, n in kinds])
    ax.set_ylabel("Time to first token, ms (median)")
    ax.yaxis.set_major_formatter(ms_fmt)
    ax.set_ylim(0, 5000)
    handles = [plt.Rectangle((0, 0), 1, 1, color=c) for c in (ORANGE, BLUE)]
    ax.legend(handles, ["Chart's built-in lmcache_server (lm://)", "Redis"], loc="lower left",
              bbox_to_anchor=(-0.01, 1.01), ncol=2, frameon=False, fontsize=8, handlelength=1, handleheight=1)
    titled(fig, "Scenario 5: built-in cache server vs Redis", "Same workload, 3 runs each. The built-in server "
           "adds ~3 s to every request, even GPU cache hits, and never serves pod B.", 0.905)
    fig.subplots_adjust(left=0.1, right=0.98, top=0.74, bottom=0.12)
    fig.savefig(f"{OUT}/shared-store-bug.png", facecolor=SURFACE)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    style()
    per_request()
    token_sources()
    shared_store_bug()
    print(f"wrote {sorted(os.listdir(OUT))}")
