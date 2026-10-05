#!/usr/bin/env bash
# Run one scenario RUNS times on the node, resetting every KV cache before each run.
#   bench/bench.sh <scenario> [extra run.py args...]
# Env: TARGET (default pod-a), RUNS (default 3), RESULTS_URI (s3://... to upload; optional)
set -euo pipefail
cd "$(dirname "$0")/.."
source deploy/versions.env

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS=kvdemo
SCENARIO=$1; shift
TARGET=${TARGET:-pod-a}
RUNS=${RUNS:-3}
ROOT=/opt/kvdemo
log() { echo "[bench] $*"; }

# Delete pods one at a time and wait for replacements: engines must start one after
# another (vLLM sizes its KV cache from free GPU memory), and a restart is the only
# way to empty the GPU, CPU-tier and shared-server caches.
reset_caches() {
  # Shared stores first: engines connect to them at startup.
  for sel in app.kubernetes.io/component=cache-server app=kv-redis model=pod-a model=pod-b; do
    pods=$(kubectl -n "$NS" get pod -l "$sel" -o name)
    [[ -z "$pods" ]] && continue
    kubectl -n "$NS" delete $pods --wait >/dev/null
    until kubectl -n "$NS" get pod -l "$sel" -o name 2>/dev/null | grep -q pod; do sleep 2; done
    kubectl -n "$NS" wait pod -l "$sel" --for=condition=Ready --timeout=15m >/dev/null
  done
}

run_job() {  # $1 = run number, rest = extra run.py args
  local run=$1; shift
  local name="bench-$(echo "$SCENARIO" | tr '_.' '--')-$run"
  kubectl -n "$NS" delete job "$name" --ignore-not-found --wait >/dev/null
  # Extra run.py args are passed as a JSON list so quoting survives.
  local args
  args=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' \
    --target "http://kv-$TARGET-engine-service" --scenario "$SCENARIO" --run "$run" "$@")
  kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: { name: $name }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: bench
          image: $ENGINE_IMAGE
          imagePullPolicy: IfNotPresent
          workingDir: /bench
          command: ["/opt/venv/bin/python", "-u", "run.py"]
          args: $args
          env:
            - { name: MODEL, value: "$MODEL" }
            - { name: HF_HOME, value: /hf }
            - { name: NVIDIA_VISIBLE_DEVICES, value: void }   # client only; no GPU
            - { name: PIN_ENGINE_IMAGE, value: "$ENGINE_IMAGE" }
            - { name: PIN_ROUTER_IMAGE, value: "$ROUTER_IMAGE" }
            - { name: PIN_STACK_CHART, value: "$STACK_CHART_VERSION" }
            - { name: PIN_MODEL_REVISION, value: "$MODEL_REVISION" }
          resources:
            requests: { cpu: "1", memory: 1Gi }
          volumeMounts:
            - { name: code, mountPath: /bench, readOnly: true }
            - { name: results, mountPath: /results }
            - { name: hf, mountPath: /hf }
      volumes:
        - { name: code, hostPath: { path: $ROOT/bench } }
        - { name: results, hostPath: { path: $ROOT/results, type: DirectoryOrCreate } }
        - { name: hf, hostPath: { path: $ROOT/hf, type: DirectoryOrCreate } }
YAML
  until kubectl -n "$NS" get pod -l job-name="$name" -o name 2>/dev/null | grep -q pod; do sleep 2; done
  kubectl -n "$NS" wait pod -l job-name="$name" --for=condition=Ready --timeout=5m >/dev/null 2>&1 || true
  kubectl -n "$NS" logs -f job/"$name"
  kubectl -n "$NS" wait job/"$name" --for=condition=Complete --timeout=10s >/dev/null \
    || { echo "job $name failed" >&2; return 1; }
}

log "scenario $SCENARIO: $RUNS runs against $TARGET"
for run in $(seq "$RUNS"); do
  log "run $run: resetting caches"
  reset_caches
  run_job "$run" "$@"
done

if [[ -n "${RESULTS_URI:-}" ]]; then
  aws s3 sync "$ROOT/results/$SCENARIO" "$RESULTS_URI$SCENARIO/" --only-show-errors
  log "uploaded to $RESULTS_URI$SCENARIO/"
fi
