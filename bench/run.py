"""Send the workload to one endpoint, one request at a time, and record TTFT per request.

Writes <out>/<scenario>/run<N>.csv (one row per request) and run<N>.json (run metadata
and the change in vLLM / LMCache counters over the measured requests).

Each request is tagged with what the GPU prefix cache *should* do, from a simulation
of an LRU cache sized from vLLM's own cache_config_info metric:
  first     the document has not been seen in this run
  resident  the document's KV should still be in GPU memory
  evicted   enough other tokens passed through since its last use to push it out

With --peer (scenario 5), each document goes target -> peer -> peer -> target:
  first     Q0 to the target (pod A) computes the document
  cross     Q1 to the peer (pod B), which has never seen it: fast only if the KV
            comes from the shared cache server
  resident  Q2 on the peer, Q3 back on the target
"""
import argparse
import csv
import http.client
import json
import os
import re
import time
from collections import OrderedDict
from urllib.parse import urlparse

from transformers import AutoTokenizer

from workload import build


def http_get(url):
    u = urlparse(url)
    c = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=30)
    c.request("GET", u.path)
    return c.getresponse().read().decode()


def counters(base_url):
    """Sum every vllm:/lmcache: sample by metric name (labels dropped)."""
    totals = {}
    for line in http_get(base_url + "/metrics").splitlines():
        m = re.match(r"^((?:vllm|lmcache):[a-zA-Z0-9_:]+)(?:\{[^}]*\})? ([0-9.eE+-]+)$", line)
        if m:
            totals[m[1]] = totals.get(m[1], 0.0) + float(m[2])
    return totals


def gpu_cache_tokens(base_url):
    text = http_get(base_url + "/metrics")
    m = re.search(r'vllm:cache_config_info\{[^}]*\}', text)
    labels = dict(re.findall(r'(\w+)="([^"]*)"', m[0]))
    return int(labels["num_gpu_blocks"]) * int(labels["block_size"])


def complete(base_url, model, prompt_ids, max_tokens):
    """Stream one completion. Returns (ttft_s, total_s, cached_tokens)."""
    u = urlparse(base_url)
    body = json.dumps({
        "model": model,
        "prompt": prompt_ids,
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": True,
        "stream_options": {"include_usage": True},
    })
    c = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=300)
    start = time.perf_counter()
    c.request("POST", "/v1/completions", body, {"Content-Type": "application/json"})
    resp = c.getresponse()
    if resp.status != 200:
        raise RuntimeError(f"HTTP {resp.status}: {resp.read()[:300]!r}")
    ttft, cached = None, None
    for raw in resp:
        line = raw.decode().strip()
        if not line.startswith("data: ") or line == "data: [DONE]":
            continue
        chunk = json.loads(line[6:])
        if ttft is None and chunk.get("choices"):
            ttft = time.perf_counter() - start
        usage = chunk.get("usage")
        if usage:
            cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens")
    return ttft, time.perf_counter() - start, cached


class LruSim:
    """Which documents should still be in an LRU cache of `capacity` tokens."""

    def __init__(self, capacity):
        self.capacity, self.docs, self.seen = capacity, OrderedDict(), set()

    def access(self, doc, tokens):
        if doc in self.docs:
            state = "resident"
        else:
            state = "evicted" if doc in self.seen else "first"
        self.seen.add(doc)
        self.docs.pop(doc, None)
        self.docs[doc] = tokens
        while sum(self.docs.values()) > self.capacity:
            self.docs.popitem(last=False)
        return state


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True, help="engine base URL, e.g. http://kv-pod-a-engine-service")
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--run", type=int, required=True)
    ap.add_argument("--model", default=os.environ.get("MODEL", "Qwen/Qwen2.5-3B-Instruct"))
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--docs", type=int, default=20)
    ap.add_argument("--doc-tokens", type=int, default=10_000)
    ap.add_argument("--warmup-seed", type=int, default=1042, help="separate documents, so warm-up fills no measured cache")
    ap.add_argument("--warmup-docs", type=int, default=2)
    ap.add_argument("--max-tokens", type=int, default=4)
    ap.add_argument("--peer", help="second engine URL; switches to the cross-pod order (scenario 5)")
    ap.add_argument("--out", default="/results")
    a = ap.parse_args()

    tok = AutoTokenizer.from_pretrained(a.model)
    capacity = gpu_cache_tokens(a.target)
    workload = build(tok, a.seed, a.docs, a.doc_tokens)
    print(f"[run] {a.scenario} run {a.run}: {len(workload)} requests to {a.target}, GPU cache {capacity:,} tokens")

    endpoints = [a.target] + ([a.peer] if a.peer else [])
    for r in build(tok, a.warmup_seed, a.warmup_docs, a.doc_tokens):
        for url in endpoints:
            complete(url, a.model, r.prompt_ids, a.max_tokens)
    print(f"[run] warm-up done ({a.warmup_docs} documents, seed {a.warmup_seed}, {len(endpoints)} endpoint(s))")

    if a.peer:
        by_key = {(r.doc, r.question): r for r in workload}
        plan = [(by_key[d, q], url, state) for d in range(a.docs) for q, url, state in
                ((0, a.target, "first"), (1, a.peer, "cross"), (2, a.peer, "resident"), (3, a.target, "resident"))]
    else:
        sim = LruSim(capacity)
        plan = [(r, a.target, sim.access(r.doc, len(r.prompt_ids))) for r in workload]

    before = {url: counters(url) for url in endpoints}
    rows = []
    for seq, (r, url, state) in enumerate(plan):
        ttft, total, cached = complete(url, a.model, r.prompt_ids, a.max_tokens)
        rows.append({
            "scenario": a.scenario, "run": a.run, "seq": seq, "doc": r.doc, "question": r.question,
            "expected": state, "prompt_tokens": len(r.prompt_ids), "cached_tokens": cached,
            "ttft_ms": round(ttft * 1000, 1), "total_ms": round(total * 1000, 1), "target": url,
        })
        print(f"  {seq:3d} doc {r.doc:2d} q{r.question} {state:8s} ttft {ttft * 1000:7.1f} ms  cached {cached}  {url}")
    after = {url: counters(url) for url in endpoints}

    os.makedirs(f"{a.out}/{a.scenario}", exist_ok=True)
    path = f"{a.out}/{a.scenario}/run{a.run}"
    with open(path + ".csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=rows[0].keys())
        w.writeheader()
        w.writerows(rows)
    delta = {url: {k: after[url][k] - before[url].get(k, 0.0) for k in sorted(after[url])
                   if k.endswith("_total") and after[url][k] != before[url].get(k, 0.0)}
             for url in endpoints}
    with open(path + ".json", "w") as f:
        json.dump({"args": vars(a), "gpu_cache_tokens": capacity, "counter_delta": delta,
                   "versions": {k: v for k, v in os.environ.items() if k.startswith("PIN_")}}, f, indent=2)

    by_state = {}
    for row in rows:
        by_state.setdefault(row["expected"], []).append(row["ttft_ms"])
    for state, v in by_state.items():
        v.sort()
        print(f"[run] {state:8s} n={len(v):3d}  p50 {v[len(v) // 2]:7.1f} ms  p90 {v[int(len(v) * 0.9)]:7.1f} ms")
    print(f"[run] wrote {path}.csv")


if __name__ == "__main__":
    main()
