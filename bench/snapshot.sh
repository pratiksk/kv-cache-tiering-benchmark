#!/usr/bin/env bash
# Preserve what only lives in the cluster: Prometheus keeps its data in an emptyDir,
# so it is lost with the pod. Run before `make stop` / `make down`.
#   1. load dashboards/*.json into Grafana
#   2. mark each benchmark Job's time window as a Grafana annotation
#   3. export the key Prometheus series to results/metrics/*.csv (and S3)
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
log() { echo "[snapshot] $*"; }

prom=http://$(kubectl -n monitoring get svc monitoring-kube-prometheus-prometheus -o jsonpath={.spec.clusterIP}):9090
graf=http://$(kubectl -n monitoring get svc monitoring-grafana -o jsonpath={.spec.clusterIP})
pw=$(kubectl -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d)

kubectl -n monitoring create configmap kv-dashboards --from-file=dashboards/ --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f - >/dev/null
log "dashboards loaded: $(ls dashboards)"

kubectl -n kvdemo get jobs -o json > /tmp/kv-jobs.json
PROM=$prom GRAF=$graf PW=$pw python3 - <<'PY'
import base64, csv, datetime, json, os, sys, urllib.parse, urllib.request

def ms(t):
    return int(datetime.datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp() * 1000)

auth = "Basic " + base64.b64encode(f"admin:{os.environ['PW']}".encode()).decode()
def grafana(method, path, body=None):
    req = urllib.request.Request(os.environ["GRAF"] + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": auth, "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req))

# Replace earlier run annotations so reruns don't duplicate them.
for a in grafana("GET", "/api/annotations?tags=kvdemo-run&limit=1000"):
    grafana("DELETE", f"/api/annotations/{a['id']}")

windows = []
for job in json.load(open("/tmp/kv-jobs.json"))["items"]:
    s = job["status"]
    if "startTime" in s and "completionTime" in s:
        name = job["metadata"]["name"].replace("bench-", "", 1)
        windows.append((name, ms(s["startTime"]), ms(s["completionTime"])))
        grafana("POST", "/api/annotations", {"time": windows[-1][1], "timeEnd": windows[-1][2],
                                             "tags": ["kvdemo-run"], "text": name})
windows.sort(key=lambda w: w[1])
print(f"[snapshot] {len(windows)} run windows annotated")

os.makedirs("results/metrics", exist_ok=True)
with open("results/metrics/run_windows.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["run", "start_utc", "end_utc"])
    for name, a, b in windows:
        w.writerow([name] + [datetime.datetime.fromtimestamp(t / 1000, datetime.timezone.utc).isoformat() for t in (a, b)])

queries = {
    "prompt_tokens_by_source_rate": 'sum by (source) (rate(vllm:prompt_tokens_by_source_total{namespace="kvdemo"}[1m]))',
    "ttft_mean_seconds": 'sum by (service) (rate(vllm:time_to_first_token_seconds_sum{namespace="kvdemo"}[1m])) / sum by (service) (rate(vllm:time_to_first_token_seconds_count{namespace="kvdemo"}[1m]))',
    "gpu_kv_cache_usage": 'max by (service) (vllm:kv_cache_usage_perc{namespace="kvdemo"})',
    "lmcache_cpu_tier_bytes": 'max by (service) (lmcache:local_cache_usage{namespace="kvdemo"})',
    "host_memory_available_bytes": "min(node_memory_MemAvailable_bytes)",
}
start, end = windows[0][1] / 1000 - 600, windows[-1][2] / 1000 + 600
for name, q in queries.items():
    url = os.environ["PROM"] + "/api/v1/query_range?" + urllib.parse.urlencode(
        {"query": q, "start": start, "end": end, "step": "10"})
    result = json.load(urllib.request.urlopen(url))["data"]["result"]
    with open(f"results/metrics/{name}.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["timestamp_utc", "series", "value"])
        for series in result:
            label = ",".join(f"{k}={v}" for k, v in series["metric"].items()) or "value"
            for t, v in series["values"]:
                w.writerow([datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat(), label, v])
    print(f"[snapshot] {name}: {len(result)} series")
PY

if [[ -n "${RESULTS_URI:-}" ]]; then
  aws s3 sync results/metrics "${RESULTS_URI}metrics/" --only-show-errors
  log "uploaded to ${RESULTS_URI}metrics/"
fi
