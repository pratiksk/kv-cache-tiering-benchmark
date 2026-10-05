"""Draw docs/img/ttft-by-scenario.png from results/<scenario>/run*.csv.

Grouped bars: one group per scenario, one bar per request type, median TTFT (p50)
across runs. Only the bars the story turns on carry a value label; the axis and
results/summary.md (the table view) carry the rest.

    uv run --with 'matplotlib==3.10.*' python bench/chart.py
"""
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

sys.path.insert(0, os.path.dirname(__file__))
from report import scenario_summary  # noqa: E402

# Validated categorical slots 1-4 (dataviz reference palette, light mode).
SURFACE, INK, INK_2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e1"
# Labels describe where a question falls in the workload, not what the cache did:
# in scenario 1 nothing is cached, yet the same three positions exist.
TYPES = [  # (request type, legend label, colour)
    ("first", "First question on a document", "#2a78d6"),
    ("resident", "Repeat, asked right after", "#eb6834"),
    ("evicted", "Revisit after 19 other documents", "#1baf7a"),
    ("cross", "First question on the other pod", "#eda100"),
]
SCENARIOS = [
    ("s1-no-cache", "1. No cache"),
    ("s2-gpu-cache", "2. GPU prefix\ncache"),
    ("s3-gpu-pressure", "3. GPU cache,\noverflowed"),
    ("s4-cpu-tier", "4. + CPU tier\n(LMCache)"),
    ("s5-shared", "5. Shared store\n(Redis, 2 pods)"),
]
LABELLED = {("s2-gpu-cache", "resident"), ("s3-gpu-pressure", "evicted"),
            ("s4-cpu-tier", "evicted"), ("s5-shared", "cross")}


def main(root="results", out="docs/img/ttft-by-scenario.png"):
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 9, "text.color": INK,
                         "axes.labelcolor": INK_2, "xtick.color": INK_2, "ytick.color": INK_2})
    fig, ax = plt.subplots(figsize=(8, 4.4), dpi=200)
    fig.patch.set_facecolor(SURFACE)
    ax.set_facecolor(SURFACE)

    bar_w, gap = 0.18, 0.02  # data units; gap shows the surface between touching bars
    for gi, (scenario, _) in enumerate(SCENARIOS):
        summary, _, _ = scenario_summary(f"{root}/{scenario}")
        present = [t for t in TYPES if t[0] in summary]
        span = len(present) * bar_w
        for bi, (key, _, colour) in enumerate(present):
            x = gi - span / 2 + bi * bar_w + bar_w / 2
            p50 = summary[key][0]
            ax.bar(x, p50, width=bar_w - gap, color=colour, zorder=3)
            if (scenario, key) in LABELLED:
                ax.annotate(f"{p50:,.0f} ms", (x, p50), xytext=(0, 3), textcoords="offset points",
                            ha="center", va="bottom", fontsize=8.5, color=INK, fontweight="bold")

    ax.set_xticks(range(len(SCENARIOS)), [label for _, label in SCENARIOS])
    ax.tick_params(axis="x", length=0, pad=6)
    ax.tick_params(axis="y", length=0)
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:,.0f}"))
    ax.set_ylabel("Time to first token, ms (median)")
    ax.set_ylim(0, 1700)
    ax.grid(axis="y", color=GRID, linewidth=0.6, zorder=0)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color(GRID)

    handles = [plt.Rectangle((0, 0), 1, 1, color=c) for _, _, c in TYPES]
    ax.legend(handles, [label for _, label, _ in TYPES], loc="lower left", bbox_to_anchor=(-0.01, 1.01),
              ncol=2, frameon=False, fontsize=8, handlelength=1, handleheight=1, columnspacing=2.5)
    fig.suptitle("KV cache tiering: time to first token by scenario", x=0.06, ha="left",
                 fontsize=12, fontweight="bold", y=0.99)
    fig.text(0.06, 0.915, "Qwen2.5-3B on one NVIDIA L4, 10,000-token documents, one request at a time. "
             "Median of 3 runs; lower is better.", fontsize=8, color=INK_2)
    fig.subplots_adjust(left=0.1, right=0.98, top=0.75, bottom=0.17)
    fig.savefig(out, facecolor=SURFACE)
    print(f"wrote {out}")


if __name__ == "__main__":
    main(*sys.argv[1:])
