#!/usr/bin/env bash
# 18 — NGINX Ingress Controller as a NodePort service. Run once on a master.
#
# The controller listens on fixed NodePorts on every node; the external HAProxy LB
# forwards :80/:443 to those NodePorts (see scripts/lb-haproxy-setup.sh with
# INGRESS_LB=true), so it acts as the L4 load balancer in front of Ingresses.
#
#   sudo INGRESS_HTTP_NODEPORT=30080 INGRESS_HTTPS_NODEPORT=30443 ./scripts/18-ingress-nginx.sh
#
# Config (env):
#   INGRESS_NGINX_NS         default ingress-nginx
#   INGRESS_HTTP_NODEPORT    default 30080
#   INGRESS_HTTPS_NODEPORT   default 30443
#   INGRESS_NGINX_VERSION    chart version (default: latest)
#   INGRESS_DEFAULT_CLASS    make 'nginx' the default IngressClass (default true)
set -euo pipefail
INGRESS_NGINX_NS="${INGRESS_NGINX_NS:-ingress-nginx}"
INGRESS_HTTP_NODEPORT="${INGRESS_HTTP_NODEPORT:-30080}"
INGRESS_HTTPS_NODEPORT="${INGRESS_HTTPS_NODEPORT:-30443}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-}"
INGRESS_DEFAULT_CLASS="${INGRESS_DEFAULT_CLASS:-true}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"
command -v helm >/dev/null || die "helm not found"

log "installing ingress-nginx (NodePort http=${INGRESS_HTTP_NODEPORT} https=${INGRESS_HTTPS_NODEPORT})"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null 2>&1 || true
VER=(); [[ -n "$INGRESS_NGINX_VERSION" ]] && VER=(--version "$INGRESS_NGINX_VERSION")
ok=false
for i in 1 2 3; do
  if helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
      -n "$INGRESS_NGINX_NS" --create-namespace \
      --set controller.service.type=NodePort \
      --set controller.service.nodePorts.http="$INGRESS_HTTP_NODEPORT" \
      --set controller.service.nodePorts.https="$INGRESS_HTTPS_NODEPORT" \
      --set controller.watchIngressWithoutClass=true \
      --set controller.ingressClassResource.default="$INGRESS_DEFAULT_CLASS" \
      "${VER[@]}" --wait --timeout 6m; then ok=true; break; fi
  warn "helm attempt $i failed — retrying"; sleep 5
done
[[ "$ok" == true ]] || die "ingress-nginx install failed"

kubectl -n "$INGRESS_NGINX_NS" rollout status deploy/ingress-nginx-controller --timeout=180s >/dev/null 2>&1 || true
log "ingress-nginx ready:"
kubectl -n "$INGRESS_NGINX_NS" get svc ingress-nginx-controller -o wide 2>/dev/null | sed 's/^/    /'
echo
log "Point the HAProxy LB at the NodePorts (on the proxy host):"
echo "    INGRESS_LB=true INGRESS_NODES='<worker IPs>' INGRESS_HTTP_NODEPORT=${INGRESS_HTTP_NODEPORT} \\"
echo "    INGRESS_HTTPS_NODEPORT=${INGRESS_HTTPS_NODEPORT} ./lb-haproxy-setup.sh <master IPs>"
