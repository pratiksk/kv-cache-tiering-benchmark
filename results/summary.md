# Results

Median across runs of each run's TTFT percentiles, by request type.

| Scenario | Runs | Type | n per run | TTFT p50 (ms) | TTFT p90 (ms) |
| --- | --- | --- | --- | --- | --- |
| s1-no-cache | 3 | first | 20 | 1,451.8 | 1,470.9 |
| s1-no-cache | 3 | resident | 40 | 1,468.4 | 1,484.7 |
| s1-no-cache | 3 | evicted | 20 | 1,481.4 | 1,486.5 |
| s2-gpu-cache | 3 | first | 4 | 1,407.3 | 1,409.6 |
| s2-gpu-cache | 3 | resident | 12 | 51.1 | 51.9 |
| s3-gpu-pressure | 3 | first | 20 | 1,424.7 | 1,434.1 |
| s3-gpu-pressure | 3 | resident | 40 | 51.8 | 53.0 |
| s3-gpu-pressure | 3 | evicted | 20 | 1,449.2 | 1,454.9 |
| s4-cpu-tier | 3 | first | 20 | 1,451.1 | 1,468.5 |
| s4-cpu-tier | 3 | resident | 40 | 52.3 | 53.2 |
| s4-cpu-tier | 3 | evicted | 20 | 67.7 | 69.6 |
| s5-shared | 3 | first | 4 | 1,436.2 | 1,439.8 |
| s5-shared | 3 | resident | 8 | 52.8 | 54.2 |
| s5-shared | 3 | cross | 4 | 490.1 | 555.4 |

Share of prompt tokens served from a cache (GPU prefix cache + LMCache) instead of prefilled:

| Scenario | Prompt tokens reused |
| --- | --- |
| s1-no-cache | 0.0% |
| s2-gpu-cache | 74.8% |
| s3-gpu-pressure | 49.9% |
| s4-cpu-tier | 74.8% |
| s5-shared | 74.8% |

## Known issue: the chart's built-in cache server (LMCache 0.5.5)

Scenario 5 was first run with the production-stack chart's own shared server (`lmcache_server`, `lm://` URL). It never served a hit and added ~3 s to every request on both engines, including GPU cache hits; engine logs show LMCache's internal lookup RPC timing out. Root cause not established; scenario 5 above uses Redis instead. Details: docs/REPORT.md Appendix F.

| Config | Runs | Type | TTFT p50 (ms) |
| --- | --- | --- | --- |
| bug-s5-lmserver | 3 | first | 4,428.6 |
| bug-s5-lmserver | 3 | resident | 3,099.5 |
| bug-s5-lmserver | 3 | cross | 4,424.7 |
