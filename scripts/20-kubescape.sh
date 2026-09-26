#!/usr/bin/env bash
# 20 — Kubescape operator (in-cluster security & compliance scanning). Run on a master.
#
# Installs the Kubescape operator, which continuously scans workloads and the
# cluster config for misconfigurations (NSA, MITRE, CIS frameworks) and images for
# vulnerabilities. Results are Kubernetes CRDs you can query with kubectl.
#
#   sudo KUBESCAPE_CLUSTER_NAME=prod1-k8s ./scripts/20-kubescape.sh
#
# Config (env):
#   KUBESCAPE_NS             default kubescape
#   KUBESCAPE_CLUSTER_NAME   label for this cluster (default: kubernetes)
#   KUBESCAPE_VERSION        chart version (default: latest)
#
# Query results:
#   kubectl get configurationscansummaries -A          # cluster compliance summary
#   kubectl get workloadconfigurationscansummaries -A  # per-workload findings
#   kubectl get vulnerabilitymanifestsummaries -A       # image vulnerabilities
set -euo pipefail
KUBESCAPE_NS="${KUBESCAPE_NS:-kubescape}"
KUBESCAPE_CLUSTER_NAME="${KUBESCAPE_CLUSTER_NAME:-kubernetes}"
KUBESCAPE_VERSION="${KUBESCAPE_VERSION:-}"
# Posture frameworks to scan. Default to the well-established nsa+mitre, which are
# in the scanner's bundled control library. The newer "security" framework
# references controls (e.g. C-0214) that only load if the full library can be
# downloaded (download.armosec.io); when it can't, the scan aborts with
# "framework 'C-0214' not found" and NO summaries are produced. So we pin known
# frameworks and disable the security framework by default.
KUBESCAPE_FRAMEWORKS="${KUBESCAPE_FRAMEWORKS:-nsa,mitre}"
KUBESCAPE_SECURITY_FRAMEWORK="${KUBESCAPE_SECURITY_FRAMEWORK:-false}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"
command -v helm >/dev/null || die "helm not found"

log "installing Kubescape operator (cluster '${KUBESCAPE_CLUSTER_NAME}', continuous scan)"
helm repo add kubescape https://kubescape.github.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update kubescape >/dev/null 2>&1 || true
VER=(); [[ -n "$KUBESCAPE_VERSION" ]] && VER=(--version "$KUBESCAPE_VERSION")
ok=false
for i in 1 2 3; do
  if helm upgrade --install kubescape kubescape/kubescape-operator \
      -n "$KUBESCAPE_NS" --create-namespace \
      --set clusterName="$KUBESCAPE_CLUSTER_NAME" \
      --set capabilities.continuousScan=enable \
      --set operator.triggerSecurityFramework="$KUBESCAPE_SECURITY_FRAMEWORK" \
      --set "defaultFrameworks={${KUBESCAPE_FRAMEWORKS}}" \
      "${VER[@]}" --wait --timeout 6m; then ok=true; break; fi
  warn "helm attempt $i failed — retrying"; sleep 5
done
[[ "$ok" == true ]] || die "kubescape install failed"

log "kubescape pods:"
kubectl -n "$KUBESCAPE_NS" get pods --no-headers 2>/dev/null | awk '{print "    "$1,$3}'
echo
log "Scans run on a schedule. Trigger one now:"
echo "    kubectl -n ${KUBESCAPE_NS} create job scan-now --from=cronjob/kubescape-scheduler"
log "Read results:"
echo "    kubectl get configurationscansummaries -A"
echo "    kubectl get workloadconfigurationscansummaries -A"
echo "    kubectl get vulnerabilitymanifestsummaries -A"
