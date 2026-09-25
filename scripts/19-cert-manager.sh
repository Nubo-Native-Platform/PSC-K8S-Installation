#!/usr/bin/env bash
# 19 — cert-manager + Let's Encrypt ClusterIssuers (HTTP-01 via nginx). Run on a master.
#
# Installs cert-manager and, when ACME_EMAIL is set, creates letsencrypt-staging
# and letsencrypt-prod ClusterIssuers that solve the ACME HTTP-01 challenge through
# the nginx ingress. Issue a cert by adding to an Ingress:
#   annotations: { cert-manager.io/cluster-issuer: letsencrypt-prod }
#   spec.tls: [{ hosts: [app.example.com], secretName: app-tls }]
#
#   sudo ACME_EMAIL=you@example.com ./scripts/19-cert-manager.sh
#
# Config (env):
#   ACME_EMAIL            contact for Let's Encrypt (required to create issuers)
#   CERT_MANAGER_VERSION  chart version (default: latest)
#   INGRESS_CLASS         ingress class for HTTP-01 (default nginx)
#
# NOTE: real certificate issuance requires a PUBLIC DNS name resolving to the LB
# and the LB reachable from the internet on :80 (ACME HTTP-01). On a private lab it
# won't validate; the plumbing (cert-manager + issuers) still installs.
set -euo pipefail
ACME_EMAIL="${ACME_EMAIL:-}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
CM_NS="${CM_NS:-cert-manager}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"
command -v helm >/dev/null || die "helm not found"

log "installing cert-manager"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null 2>&1 || true
VER=(); [[ -n "$CERT_MANAGER_VERSION" ]] && VER=(--version "$CERT_MANAGER_VERSION")
ok=false
for i in 1 2 3; do
  if helm upgrade --install cert-manager jetstack/cert-manager \
      -n "$CM_NS" --create-namespace --set crds.enabled=true \
      "${VER[@]}" --wait --timeout 6m; then ok=true; break; fi
  warn "helm attempt $i failed — retrying"; sleep 5
done
[[ "$ok" == true ]] || die "cert-manager install failed"

if [[ -z "$ACME_EMAIL" ]]; then
  warn "ACME_EMAIL not set — skipping ClusterIssuers. Create them later with:"
  warn "  sudo ACME_EMAIL=you@example.com ./scripts/19-cert-manager.sh"
  exit 0
fi

log "creating Let's Encrypt ClusterIssuers (staging + prod, HTTP-01 via ${INGRESS_CLASS})"
for pair in "letsencrypt-staging|https://acme-staging-v02.api.letsencrypt.org/directory" \
            "letsencrypt-prod|https://acme-v02.api.letsencrypt.org/directory"; do
  name="${pair%%|*}"; server="${pair##*|}"
  kubectl apply -f - <<EOF >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: ${name} }
spec:
  acme:
    email: ${ACME_EMAIL}
    server: ${server}
    privateKeySecretRef: { name: ${name}-account-key }
    solvers:
      - http01:
          ingress: { ingressClassName: ${INGRESS_CLASS} }
EOF
done
sleep 5
kubectl get clusterissuer -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].status --no-headers 2>&1 | sed 's/^/    /'
echo
log "Use it on an Ingress:  annotation cert-manager.io/cluster-issuer: letsencrypt-prod + spec.tls"
