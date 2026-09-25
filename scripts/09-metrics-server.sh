#!/usr/bin/env bash
# 09 — Install metrics-server (required for HPA autoscaling and `kubectl top`).
# Run once from a master. Idempotent.
#
#   sudo ./scripts/09-metrics-server.sh
#   sudo METRICS_SERVER_VERSION=v0.7.2 ./scripts/09-metrics-server.sh
#
# On kubeadm bare-metal the kubelet serving certs are self-signed, so the
# deployment is patched with --kubelet-insecure-tls.
set -euo pipefail
MSV="${METRICS_SERVER_VERSION:-latest}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"

if [[ "$MSV" == latest ]]; then
  URL="https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
else
  URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/${MSV}/components.yaml"
fi
log "installing metrics-server (${MSV})"
kubectl apply -f "$URL"

# Ensure --kubelet-insecure-tls is present (kubeadm self-signed kubelet certs).
if ! kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q 'kubelet-insecure-tls'; then
  log "patching --kubelet-insecure-tls"
  kubectl -n kube-system patch deploy metrics-server --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
log "waiting for metrics-server rollout"
kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s || warn "metrics-server not ready yet"
log "done — try:  kubectl top nodes"
