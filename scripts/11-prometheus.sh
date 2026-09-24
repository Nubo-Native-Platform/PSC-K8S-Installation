#!/usr/bin/env bash
# 11 — Install Prometheus (kube-prometheus-stack) WITHOUT Grafana. Run from a
# master. Gives Prometheus + Alertmanager + node-exporter + kube-state-metrics,
# suitable for scraping/federation into an external tool (e.g. Sysdig).
#
#   sudo ./scripts/11-prometheus.sh
#   sudo PROMETHEUS_STORAGE_CLASS=local-path PROMETHEUS_RETENTION=15d ./scripts/11-prometheus.sh
#
# Config via env vars:
#   PROMETHEUS_NAMESPACE       default monitoring
#   PROMETHEUS_RETENTION       default 7d
#   PROMETHEUS_STORAGE_CLASS   default "" (emptyDir; NOT persistent). Set to a
#                              local/block SC for persistence — avoid NFS for the
#                              Prometheus TSDB (mmap/locking).
#   PROMETHEUS_STORAGE_SIZE    default 20Gi (only when a storage class is set)
#   PROMETHEUS_ALERTMANAGER    default true
set -euo pipefail
NS="${PROMETHEUS_NAMESPACE:-monitoring}"
RETENTION="${PROMETHEUS_RETENTION:-7d}"
SC="${PROMETHEUS_STORAGE_CLASS:-}"
SIZE="${PROMETHEUS_STORAGE_SIZE:-20Gi}"
ALERTMANAGER="${PROMETHEUS_ALERTMANAGER:-true}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"
if ! command -v helm >/dev/null 2>&1; then
  log "installing helm"; curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
fi

log "adding prometheus-community helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

ARGS=(
  --set grafana.enabled=false
  --set prometheus.prometheusSpec.retention="${RETENTION}"
  --set alertmanager.enabled="${ALERTMANAGER}"
)
if [[ -n "$SC" ]]; then
  log "Prometheus TSDB persisted on StorageClass ${SC} (${SIZE})"
  ARGS+=(
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName="${SC}"
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]=ReadWriteOnce
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage="${SIZE}"
  )
else
  warn "no PROMETHEUS_STORAGE_CLASS set — Prometheus data is emptyDir (ephemeral). Fine when shipping to an external store; set a local/block SC for local persistence."
fi

log "installing kube-prometheus-stack (Grafana disabled) in namespace ${NS}"
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack -n "$NS" --create-namespace "${ARGS[@]}"

log "waiting for Prometheus to be ready"
kubectl -n "$NS" rollout status statefulset/prometheus-prometheus-kube-prometheus-prometheus --timeout=300s 2>/dev/null \
  || kubectl -n "$NS" get pods
echo
log "================= PROMETHEUS READY (no Grafana) ================="
log "Prometheus service: svc/prometheus-kube-prometheus-prometheus.${NS}:9090"
cat <<EOF

Query it / point Sysdig or a federation scrape at it:
  kubectl -n ${NS} port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 &
  # http://127.0.0.1:9090

Components: Prometheus, Alertmanager, node-exporter (per node), kube-state-metrics.
EOF
