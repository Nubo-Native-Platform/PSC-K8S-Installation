#!/usr/bin/env bash
# 07 — Install Argo CD (GitOps continuous delivery). Run once from a master.
#
#   sudo ./scripts/07-argocd.sh
#   sudo ARGOCD_VERSION=v3.5.3 ARGOCD_INGRESS_TYPE=NodePort ./scripts/07-argocd.sh
#
# Installs Argo CD into the 'argocd' namespace, waits for it to be ready,
# optionally exposes the API/UI server via NodePort, and prints the initial
# admin password. Idempotent (safe to re-run).
#
# Config via env vars (all optional):
#   ARGOCD_VERSION       default v3.5.3   (pinned release tag)
#   ARGOCD_NAMESPACE     default argocd
#   ARGOCD_INGRESS_TYPE  NodePort | LoadBalancer | ClusterIP   default NodePort
set -euo pipefail

ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.3}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_INGRESS_TYPE="${ARGOCD_INGRESS_TYPE:-NodePort}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }
warn(){ echo -e "${y}[!]${n} $*"; }
die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"

log "installing Argo CD ${ARGOCD_VERSION} into namespace ${ARGOCD_NAMESPACE}"
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
# Server-side apply: Argo CD's CRDs are larger than the 256KB client-side
# last-applied annotation limit, so plain "kubectl apply" fails on them.
kubectl apply --server-side --force-conflicts -n "$ARGOCD_NAMESPACE" \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

log "waiting for Argo CD to be ready (this pulls several images)"
kubectl -n "$ARGOCD_NAMESPACE" rollout status deploy/argocd-server --timeout=420s || \
  warn "argocd-server not ready yet — check: kubectl -n ${ARGOCD_NAMESPACE} get pods"
# The application-controller can briefly CreateContainerConfigError until the
# argocd-redis secret is created; rollout status waits that out.
kubectl -n "$ARGOCD_NAMESPACE" rollout status statefulset/argocd-application-controller --timeout=420s || \
  warn "application-controller not ready yet — check: kubectl -n ${ARGOCD_NAMESPACE} get pods"

if [[ "$ARGOCD_INGRESS_TYPE" != ClusterIP ]]; then
  log "exposing argocd-server as ${ARGOCD_INGRESS_TYPE}"
  kubectl -n "$ARGOCD_NAMESPACE" patch svc argocd-server -p "{\"spec\":{\"type\":\"${ARGOCD_INGRESS_TYPE}\"}}"
fi

NP="$(kubectl -n "$ARGOCD_NAMESPACE" get svc argocd-server -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || true)"
PW="$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"

echo
log "================= ARGO CD READY ================="
log "namespace : ${ARGOCD_NAMESPACE}"
log "login     : user 'admin', password: ${PW:-<already rotated; reset via docs>}"
if [[ "$ARGOCD_INGRESS_TYPE" == NodePort && -n "$NP" ]]; then
  log "UI/API    : https://<any-node-ip>:${NP}   (self-signed TLS)"
fi
cat <<EOF

CLI login (from your machine, with kubectl access):
  kubectl -n ${ARGOCD_NAMESPACE} port-forward svc/argocd-server 8080:443 &
  argocd login localhost:8080 --username admin --password '${PW:-<password>}' --insecure

Change the admin password after first login, and delete the bootstrap secret:
  argocd account update-password
  kubectl -n ${ARGOCD_NAMESPACE} delete secret argocd-initial-admin-secret
EOF
