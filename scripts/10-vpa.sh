#!/usr/bin/env bash
# 10 — Install the Vertical Pod Autoscaler (VPA). Run once from a master.
# Requires metrics-server (see 09-metrics-server.sh). Idempotent-ish.
#
#   sudo ./scripts/10-vpa.sh
#   sudo VPA_VERSION=1.8.0 ./scripts/10-vpa.sh
#
# Installs the VPA recommender, updater, and admission-controller (the latter
# needs openssl to generate its webhook cert; vpa-up.sh handles that).
set -euo pipefail
VPA_VERSION="${VPA_VERSION:-1.8.0}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"

# tools
command -v git >/dev/null || { command -v apt-get >/dev/null && apt-get install -y -qq git >/dev/null || dnf install -y -q git; }
command -v openssl >/dev/null || { command -v apt-get >/dev/null && apt-get install -y -qq openssl >/dev/null || dnf install -y -q openssl; }

TAG="vertical-pod-autoscaler-${VPA_VERSION}"
DIR="$(mktemp -d)"
log "fetching VPA ${VPA_VERSION}"
git clone --depth 1 --branch "$TAG" https://github.com/kubernetes/autoscaler.git "$DIR/autoscaler" >/dev/null 2>&1 \
  || die "could not clone VPA at tag ${TAG}"

log "installing VPA components (recommender, updater, admission-controller)"
cd "$DIR/autoscaler/vertical-pod-autoscaler"
yes | ./hack/vpa-up.sh >/dev/null 2>&1 || warn "vpa-up.sh reported issues (review with: kubectl -n kube-system get pods | grep vpa)"

log "waiting for VPA components"
for d in vpa-recommender vpa-updater vpa-admission-controller; do
  kubectl -n kube-system rollout status deploy/"$d" --timeout=180s || warn "$d not ready yet"
done
rm -rf "$DIR"
log "done. Create a VerticalPodAutoscaler targeting a workload (updateMode: Off for"
log "recommendations only, or Auto to let VPA resize pods via recreation)."
