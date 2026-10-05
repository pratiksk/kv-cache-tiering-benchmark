#!/usr/bin/env bash
# Deploy monitoring and the vLLM production stack on the k3s node.
#   deploy.sh                      base config, both engines
#   deploy.sh scenarios/x.yaml     base + scenario overlay (see merge_values.py)
# pod-b replicas come from the overlay's podB (default 1); PODB=n overrides.
set -euo pipefail
cd "$(dirname "$0")"
source versions.env

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS=kvdemo
RELEASE=kv
OVERLAY=${1:-}
overlay_podb=$( [[ -n "$OVERLAY" ]] && python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1])).get("podB", 1))' "$OVERLAY" || echo 1)
PODB=${PODB:-$overlay_podb}
log() { echo "[deploy] $*"; }

# --- Monitoring --------------------------------------------------------------
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo add vllm https://vllm-project.github.io/production-stack --force-update >/dev/null
log "kube-prometheus-stack $KPS_CHART_VERSION"
helm upgrade -i monitoring prometheus-community/kube-prometheus-stack \
  --version "$KPS_CHART_VERSION" --namespace monitoring --create-namespace \
  -f monitoring.yaml --wait --timeout 10m >/dev/null
# Our own dashboards; Grafana's sidecar loads any ConfigMap labelled grafana_dashboard=1.
kubectl -n monitoring create configmap kv-dashboards --from-file=../dashboards/ --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f - >/dev/null

# --- Stack -------------------------------------------------------------------
pins=(
  --set-string "servingEngineSpec.modelSpec[0].tag=${ENGINE_IMAGE##*:}"
  --set-string "servingEngineSpec.modelSpec[1].tag=${ENGINE_IMAGE##*:}"
  --set-string "servingEngineSpec.modelSpec[0].modelURL=$MODEL"
  --set-string "servingEngineSpec.modelSpec[1].modelURL=$MODEL"
  --set-string "servingEngineSpec.modelSpec[0].modelRevision=$MODEL_REVISION"
  --set-string "servingEngineSpec.modelSpec[1].modelRevision=$MODEL_REVISION"
  --set-string "cacheserverSpec.image.tag=${ENGINE_IMAGE##*:}"
  --set-string "routerSpec.tag=${ROUTER_IMAGE##*:}"
)
python3 merge_values.py base.yaml $OVERLAY > /tmp/kv-values.yaml
values=(-f /tmp/kv-values.yaml)

stack() {  # $1 = pod-b replicas
  helm upgrade -i "$RELEASE" vllm/vllm-stack --version "$STACK_CHART_VERSION" \
    --namespace "$NS" --create-namespace "${values[@]}" "${pins[@]}" \
    --set "servingEngineSpec.modelSpec[1].replicaCount=$1" >/dev/null
}

wait_ready() {  # $1 = engine name (pod-a, pod-b)
  # rollout status follows the new revision; a plain pod wait can match the old pod
  # that Recreate is about to remove.
  log "waiting for $1 (first start pulls ~9 GB image and ~6 GB weights)"
  kubectl -n "$NS" rollout status deploy/"$RELEASE-$1-deployment-vllm" --timeout=40m
}

# vLLM sizes its KV cache from GPU memory free at startup, so engines start one at a time.
log "stack $STACK_CHART_VERSION, overlay: ${OVERLAY:-none}, pod-b replicas: $PODB"
stack 0
wait_ready pod-a
if [[ "$PODB" -gt 0 ]]; then
  stack "$PODB"
  wait_ready pod-b
fi
kubectl -n "$NS" rollout status deploy/"$RELEASE-deployment-router" --timeout=10m >/dev/null
kubectl -n "$NS" get pods -o wide

# --- Smoke test --------------------------------------------------------------
complete() {  # $1 = service name
  kubectl -n "$NS" exec deploy/"$RELEASE"-deployment-router -- python3 -c "
import json, time, urllib.request
body = json.dumps({'model': '$MODEL', 'prompt': 'The capital of France is', 'max_tokens': 8, 'temperature': 0}).encode()
t = time.time()
r = json.load(urllib.request.urlopen(urllib.request.Request('http://$1/v1/completions', body, {'Content-Type': 'application/json'}), timeout=120))
print(f\"{'$1':40} {time.time() - t:6.2f}s  {r['choices'][0]['text']!r}\")"
}
log "smoke test"
complete "$RELEASE-pod-a-engine-service"
[[ "$PODB" -gt 0 ]] && complete "$RELEASE-pod-b-engine-service"
for _ in 1 2; do complete "$RELEASE-router-service"; done

pod_a=$(kubectl -n "$NS" get pod -l model=pod-a -o name | head -1)
log "image versions: $(kubectl -n "$NS" exec "$pod_a" -- /opt/venv/bin/python -c \
  'from importlib.metadata import version as v; print("vllm", v("vllm"), "lmcache", v("lmcache"), "torch", v("torch"))')"
log "nvidia-smi:"; nvidia-smi --query-gpu=memory.used,memory.total --format=csv
log "host memory:"; free -g | head -2
log "done"
