#!/usr/bin/env bash
# Turn an Ubuntu GPU host into a single-node k3s cluster that advertises the GPU as
# TIME_SLICES schedulable slots. Needs the NVIDIA driver and container toolkit already
# installed (the AWS Deep Learning Base AMI ships both). Safe to rerun.
set -euo pipefail

K3S_VERSION=v1.36.5+k3s1
HELM_VERSION=v3.22.0
DEVICE_PLUGIN_VERSION=0.20.1
TIME_SLICES=2
# Not the k3s default (10.42.0.0/16): that collides with common VPC ranges, including ours,
# and pods then cannot reach the VPC DNS resolver. Can only be set at install time.
CLUSTER_CIDR=10.244.0.0/16

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
log() { echo "[bootstrap] $*"; }

command -v nvidia-container-runtime >/dev/null || { echo "nvidia-container-runtime not found" >&2; exit 1; }

# --- k3s ---------------------------------------------------------------------
# An existing install with another pod range must be reinstalled; this wipes the cluster.
# Runs before the config is written, because the uninstaller deletes /etc/rancher/k3s.
if command -v k3s >/dev/null && kubectl get nodes >/dev/null 2>&1; then
  pod_cidr=$(kubectl get nodes -o jsonpath='{.items[0].spec.podCIDR}')
  if [[ "${pod_cidr%.*.*}" != "${CLUSTER_CIDR%.*.*}" ]]; then
    log "pod CIDR is $pod_cidr, want $CLUSTER_CIDR: reinstalling k3s"
    /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1
  fi
fi

# nvidia as the default runtime so chart-generated pods need no runtimeClassName.
# Traefik and ServiceLB are unused: everything is reached by port-forward.
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<EOF
default-runtime: nvidia
write-kubeconfig-mode: "0644"
cluster-cidr: $CLUSTER_CIDR
disable:
  - traefik
  - servicelb
EOF

if [[ "$(k3s --version 2>/dev/null | head -1 | awk '{print $3}')" != "$K3S_VERSION" ]]; then
  log "installing k3s $K3S_VERSION"
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -
fi

log "waiting for node Ready"
until kubectl get nodes 2>/dev/null | grep -q ' Ready'; do sleep 3; done
grep -q nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml \
  || { echo "k3s did not register the nvidia runtime" >&2; exit 1; }

log "checking DNS from a pod"
until kubectl -n kube-system get pod -l k8s-app=kube-dns -o name 2>/dev/null | grep -q pod; do sleep 3; done
kubectl wait -n kube-system pod -l k8s-app=kube-dns --for=condition=Ready --timeout=120s >/dev/null
kubectl run dns-check --rm -i --restart=Never --image=busybox:1.36 --command -- nslookup huggingface.co >/dev/null \
  || { echo "pods cannot resolve external names" >&2; exit 1; }

# --- Helm --------------------------------------------------------------------
if [[ "$(helm version --template '{{.Version}}' 2>/dev/null)" != "$HELM_VERSION" ]]; then
  log "installing helm $HELM_VERSION"
  curl -sfL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp linux-amd64/helm
  install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
fi

# --- NVIDIA device plugin with time-slicing ----------------------------------
log "installing nvidia-device-plugin $DEVICE_PLUGIN_VERSION ($TIME_SLICES slices)"
cat > /tmp/time-slicing.yaml <<EOF
version: v1
sharing:
  timeSlicing:
    resources:
      - name: nvidia.com/gpu
        replicas: $TIME_SLICES
EOF

# The chart only schedules on nodes labelled by Node Feature Discovery or carrying
# this override label. We know the node has a GPU, so label it rather than run NFD.
kubectl label nodes --all nvidia.com/gpu.present=true --overwrite >/dev/null

helm repo add nvdp https://nvidia.github.io/k8s-device-plugin --force-update >/dev/null
helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  --version "$DEVICE_PLUGIN_VERSION" \
  --namespace nvidia-device-plugin --create-namespace \
  --set-file config.map.config=/tmp/time-slicing.yaml \
  --wait --timeout 5m

log "waiting for the node to advertise nvidia.com/gpu=$TIME_SLICES"
for _ in $(seq 60); do
  gpus=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}')
  [[ "$gpus" == "$TIME_SLICES" ]] && break
  sleep 5
done
[[ "$gpus" == "$TIME_SLICES" ]] || { echo "node advertises nvidia.com/gpu=${gpus:-0}" >&2; exit 1; }

# --- Check: one pod per slice, all at once, each runs nvidia-smi --------------
log "running $TIME_SLICES GPU test pods"
kubectl delete pod -l app=gpu-test --ignore-not-found --wait >/dev/null
for i in $(seq "$TIME_SLICES"); do
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test-$i
  labels: { app: gpu-test }
spec:
  restartPolicy: Never
  containers:
    - name: smi
      image: ubuntu:22.04
      command: ["nvidia-smi", "-L"]
      env:
        - { name: NVIDIA_DRIVER_CAPABILITIES, value: "utility,compute" }
      resources:
        limits: { nvidia.com/gpu: 1 }
EOF
done
kubectl wait pod -l app=gpu-test --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
for i in $(seq "$TIME_SLICES"); do echo "gpu-test-$i: $(kubectl logs "gpu-test-$i")"; done
kubectl delete pod -l app=gpu-test >/dev/null

log "versions: k3s $K3S_VERSION, helm $HELM_VERSION, nvidia-device-plugin $DEVICE_PLUGIN_VERSION"
kubectl get nodes -o custom-columns='NODE:.metadata.name,STATUS:.status.conditions[-1].type,GPU:.status.allocatable.nvidia\.com/gpu,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory'
log "done"
