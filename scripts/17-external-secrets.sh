#!/usr/bin/env bash
# 17 — External Secrets Operator (ESO) wired to OpenBao. Run once on a master.
#
# Lets you keep secrets in OpenBao and have them appear as normal Kubernetes
# Secrets automatically: you write an ExternalSecret, ESO reads OpenBao (via the
# Kubernetes auth method) and creates/refreshes the k8s Secret for your apps.
#
#   sudo AWS_...=... BAO_TOKEN=<root> ./scripts/17-external-secrets.sh
#
# Config (env):
#   ESO_VERSION        chart version (default: latest)
#   ESO_NAMESPACE      default external-secrets
#   OPENBAO_NS         default openbao
#   BAO_KV_PATH        KV v2 mount to expose to ESO (default: secret)
#   BAO_ROLE           OpenBao k8s-auth role name (default: eso)
#   STORE_NAME         ClusterSecretStore name (default: openbao)
#   BAO_TOKEN          OpenBao root/admin token; falls back to /root/openbao-init.json
set -euo pipefail
ESO_VERSION="${ESO_VERSION:-}"
ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"
OPENBAO_NS="${OPENBAO_NS:-openbao}"
BAO_KV_PATH="${BAO_KV_PATH:-secret}"
BAO_ROLE="${BAO_ROLE:-eso}"
STORE_NAME="${STORE_NAME:-openbao}"
BAO_ADDR_INT="http://127.0.0.1:8200"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"
command -v helm >/dev/null || die "helm not found"

BAO_TOKEN="${BAO_TOKEN:-}"
if [[ -z "$BAO_TOKEN" && -f /root/openbao-init.json ]]; then
  BAO_TOKEN="$(sed -n 's/.*"root_token"[: ]*"\([^"]*\)".*/\1/p;s/.*"initial_root_token"[: ]*"\([^"]*\)".*/\1/p' /root/openbao-init.json | head -1)"
fi
[[ -n "$BAO_TOKEN" ]] || die "no BAO_TOKEN and none in /root/openbao-init.json"
bao(){ kubectl -n "$OPENBAO_NS" exec -i openbao-0 -- sh -c "BAO_ADDR=$BAO_ADDR_INT BAO_TOKEN=$BAO_TOKEN $*"; }

# --- 1. install ESO (retry: chart asset download can be flaky) ---------------
log "installing External Secrets Operator (namespace ${ESO_NAMESPACE})"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null 2>&1 || true
VER_ARG=(); [[ -n "$ESO_VERSION" ]] && VER_ARG=(--version "$ESO_VERSION")
ok=false
for i in 1 2 3; do
  if helm upgrade --install external-secrets external-secrets/external-secrets \
      -n "$ESO_NAMESPACE" --create-namespace --set installCRDs=true \
      "${VER_ARG[@]}" --wait --timeout 6m; then ok=true; break; fi
  warn "helm install attempt $i failed — retrying"; sleep 5
done
[[ "$ok" == true ]] || die "ESO helm install failed"
kubectl -n "$ESO_NAMESPACE" rollout status deploy/external-secrets --timeout=180s >/dev/null 2>&1 || true
ESO_SA="$(kubectl -n "$ESO_NAMESPACE" get deploy external-secrets -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)"
ESO_SA="${ESO_SA:-external-secrets}"

# --- 2. configure OpenBao: kubernetes auth + read policy + role -------------
log "configuring OpenBao kubernetes auth + policy/role for ESO (SA ${ESO_SA})"
bao "bao auth enable kubernetes" >/dev/null 2>&1 || true   # ok if already enabled
bao "bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc" >/dev/null \
  || die "failed to configure kubernetes auth"
kubectl -n "$OPENBAO_NS" exec -i openbao-0 -- sh -c "BAO_ADDR=$BAO_ADDR_INT BAO_TOKEN=$BAO_TOKEN bao policy write eso-read -" <<POL >/dev/null || die "policy write failed"
path "${BAO_KV_PATH}/data/*"     { capabilities = ["read"] }
path "${BAO_KV_PATH}/metadata/*" { capabilities = ["read","list"] }
POL
bao "bao write auth/kubernetes/role/${BAO_ROLE} bound_service_account_names=${ESO_SA} bound_service_account_namespaces=${ESO_NAMESPACE} policies=eso-read ttl=1h" >/dev/null \
  || die "role write failed"

# --- 3. ClusterSecretStore pointing at OpenBao ------------------------------
log "creating ClusterSecretStore '${STORE_NAME}' -> OpenBao (${BAO_KV_PATH}/, kv v2)"
kubectl apply -f - <<EOF >/dev/null
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata: { name: ${STORE_NAME} }
spec:
  provider:
    vault:
      server: "http://openbao.${OPENBAO_NS}.svc:8200"
      path: "${BAO_KV_PATH}"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "${BAO_ROLE}"
          serviceAccountRef: { name: ${ESO_SA}, namespace: ${ESO_NAMESPACE} }
EOF

echo
log "================= EXTERNAL SECRETS READY ================="
cat <<EOF
Store a secret in OpenBao, then reference it from any namespace:

  # 1) put a secret in OpenBao (KV v2 at ${BAO_KV_PATH}/)
  kubectl -n ${OPENBAO_NS} exec openbao-0 -- sh -c \\
    'BAO_TOKEN=<root> bao kv put ${BAO_KV_PATH}/myapp/db password=s3cr3t'

  # 2) declare an ExternalSecret; ESO creates a normal k8s Secret 'db-creds'
  kubectl apply -f - <<'YAML'
  apiVersion: external-secrets.io/v1
  kind: ExternalSecret
  metadata: { name: db, namespace: default }
  spec:
    refreshInterval: 1h
    secretStoreRef: { name: ${STORE_NAME}, kind: ClusterSecretStore }
    target: { name: db-creds, creationPolicy: Owner }
    data:
      - secretKey: password
        remoteRef: { key: myapp/db, property: password }
  YAML

  # 3) your pods use 'db-creds' like any Secret. ESO keeps it in sync.
EOF
