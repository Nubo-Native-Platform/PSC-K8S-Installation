#!/usr/bin/env bash
# 04 — Install Longhorn distributed storage + set it as default StorageClass.
# Run once from any master (uses kubectl). Workers must have open-iscsi (01 did that).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

command -v kubectl >/dev/null || die "kubectl not found — run this on a master"

log "checking Longhorn prerequisites on nodes"
if kubectl get nodes >/dev/null 2>&1; then
  curl -fsSL "https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_VERSION}/scripts/environment_check.sh" \
    -o /tmp/lh-check.sh 2>/dev/null && bash /tmp/lh-check.sh || warn "env check reported issues (review above)"
fi

log "installing Longhorn ${LONGHORN_VERSION}"
kubectl apply -f "https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_VERSION}/deploy/longhorn.yaml"

log "waiting for Longhorn manager to roll out (this takes a few minutes)"
kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=600s || \
  warn "longhorn-manager not fully ready yet — check: kubectl -n longhorn-system get pods"

if [[ "${LONGHORN_SET_DEFAULT_SC:-true}" == "true" ]]; then
  log "setting 'longhorn' as the default StorageClass"
  # unset any existing default, then mark longhorn default
  for sc in $(kubectl get sc -o name); do
    kubectl annotate "$sc" storageclass.kubernetes.io/is-default-class- >/dev/null 2>&1 || true
  done
  kubectl annotate sc longhorn storageclass.kubernetes.io/is-default-class=true --overwrite
fi

log "done. StorageClasses:"; kubectl get sc
echo
log "Longhorn UI: kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80  ->  http://localhost:8080"
