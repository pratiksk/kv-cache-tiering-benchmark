"""Summarise results/<scenario>/run*.csv into results/summary.md.

For each scenario and request type: the p50 and p90 TTFT of each run, then the median
of those across runs (the scope's "three measured runs, report medians"). Also the
share of prompt tokens served from a cache instead of prefilled.
"""
import csv
import glob
import json
import os
import statistics
import sys

ORDER = ["first", "resident", "evicted", "cross"]


def pct(values, q):
    """Nearest-rank percentile (used for p90; p50 uses a true median)."""
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * q))]


def scenario_summary(path):
    runs = sorted(glob.glob(f"{path}/run*.csv"))
    per_type = {}
    prompt, reused = 0, 0
    for run in runs:
        rows = list(csv.DictReader(open(run)))
        for t in ORDER:
            v = [float(r["ttft_ms"]) for r in rows if r["expected"] == t]
            if v:
                per_type.setdefault(t, []).append((statistics.median(v), pct(v, 0.9), len(v)))
        prompt += sum(int(r["prompt_tokens"]) for r in rows)
        delta = json.load(open(run.replace(".csv", ".json")))["counter_delta"]
        # Older runs stored one endpoint's counters flat; newer ones key them by endpoint.
        for delta in [delta] if "vllm:prompt_tokens_total" in delta else delta.values():
            reused += delta.get("vllm:prefix_cache_hits_total", 0) + delta.get("vllm:external_prefix_cache_hits_total", 0)
    out = {t: (statistics.median(p50 for p50, _, _ in v), statistics.median(p90 for _, p90, _ in v), v[0][2])
           for t, v in per_type.items()}
    return out, len(runs), reused / prompt if prompt else 0


def main(root="results"):
    lines = ["# Results", "", "Median across runs of each run's TTFT percentiles, by request type.", "",
             "| Scenario | Runs | Type | n per run | TTFT p50 (ms) | TTFT p90 (ms) |",
             "| --- | --- | --- | --- | --- | --- |"]
    reuse = []
    for path in sorted(p for p in glob.glob(f"{root}/s[0-9]*") if os.path.isdir(p)):
        name = os.path.basename(path)
        summary, n_runs, reused = scenario_summary(path)
        for t in ORDER:
            if t in summary:
                p50, p90, n = summary[t]
                lines.append(f"| {name} | {n_runs} | {t} | {n} | {p50:,.1f} | {p90:,.1f} |")
        reuse.append(f"| {name} | {reused:.1%} |")
    lines += ["", "Share of prompt tokens served from a cache (GPU prefix cache + LMCache) instead of prefilled:", "",
              "| Scenario | Prompt tokens reused |", "| --- | --- |"] + reuse

    bug = f"{root}/bug-s5-lmserver"
    if os.path.isdir(bug):
        summary, n_runs, _ = scenario_summary(bug)
        lines += ["", "## Known issue: the chart's built-in cache server (LMCache 0.5.5)", "",
                  "Scenario 5 was first run with the production-stack chart's own shared server "
                  "(`lmcache_server`, `lm://` URL). It never served a hit and added ~3 s to every "
                  "request on both engines, including GPU cache hits; engine logs show LMCache's "
                  "internal lookup RPC timing out. Root cause not established; scenario 5 above "
                  "uses Redis instead. Details: docs/REPORT.md Appendix F.", "",
                  "| Config | Runs | Type | TTFT p50 (ms) |", "| --- | --- | --- | --- |"]
        lines += [f"| bug-s5-lmserver | {n_runs} | {t} | {summary[t][0]:,.1f} |" for t in ORDER if t in summary]
    text = "\n".join(lines) + "\n"
    open(f"{root}/summary.md", "w").write(text)
    print(text)


if __name__ == "__main__":
    main(*sys.argv[1:])
