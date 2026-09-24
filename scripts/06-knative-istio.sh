#!/usr/bin/env bash
# 06 — Install Knative (Serving + optional Eventing) on top of Istio, with
# working Istio sidecar injection. Run once from a master (uses kubectl).
#
#   sudo ./scripts/06-knative-istio.sh
#   sudo KNATIVE_EVENTING=true KNATIVE_DOMAIN_IP=192.168.18.64 ./scripts/06-knative-istio.sh
#
# What it does:
#   1) installs Istio (istioctl) and sets the ingress gateway to NodePort
#   2) installs Knative Serving + the net-istio networking layer
#   3) enables automatic Istio sidecar injection for knative-serving (PERMISSIVE mTLS)
#   4) points the Knative domain at <KNATIVE_DOMAIN_IP>.sslip.io (Magic DNS) so
#      services get resolvable URLs reachable on the gateway NodePort
#   5) optionally installs Knative Eventing (brokers/triggers, in-memory channel)
#
# Config via env vars (all optional):
#   ISTIO_VERSION        default 1.31.1
#   KNATIVE_VERSION      default knative-v1.23.0   (used for serving + net-istio + eventing)
#   KNATIVE_EVENTING     true|false                default false
#   KNATIVE_INGRESS_TYPE NodePort|LoadBalancer     default NodePort
#   KNATIVE_DOMAIN       explicit domain (e.g. apps.example.com); overrides the IP option
#   KNATIVE_DOMAIN_IP    node IP for Magic DNS (<ip>.sslip.io); default = this node's IP
set -euo pipefail

ISTIO_VERSION="${ISTIO_VERSION:-1.31.1}"
KNATIVE_VERSION="${KNATIVE_VERSION:-knative-v1.23.0}"
KNATIVE_EVENTING="${KNATIVE_EVENTING:-false}"
KNATIVE_INGRESS_TYPE="${KNATIVE_INGRESS_TYPE:-NodePort}"
KNATIVE_DOMAIN="${KNATIVE_DOMAIN:-}"
KNATIVE_DOMAIN_IP="${KNATIVE_DOMAIN_IP:-}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }
warn(){ echo -e "${y}[!]${n} $*"; }
die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"

# --- 1) Istio ---------------------------------------------------------------
if ! command -v istioctl >/dev/null 2>&1; then
  log "downloading istioctl ${ISTIO_VERSION}"
  curl -sL https://istio.io/downloadIstio | ISTIO_VERSION="${ISTIO_VERSION}" sh - >/dev/null
  install -m 0755 "istio-${ISTIO_VERSION}/bin/istioctl" /usr/local/bin/istioctl
fi
log "installing Istio $(istioctl version --remote=false 2>/dev/null | head -1)"
istioctl install -y
log "setting istio-ingressgateway service type to ${KNATIVE_INGRESS_TYPE}"
kubectl -n istio-system patch svc istio-ingressgateway -p "{\"spec\":{\"type\":\"${KNATIVE_INGRESS_TYPE}\"}}"

# --- 2) Knative Serving + net-istio -----------------------------------------
log "installing Knative Serving ${KNATIVE_VERSION}"
kubectl apply -f "https://github.com/knative/serving/releases/download/${KNATIVE_VERSION}/serving-crds.yaml"
kubectl apply -f "https://github.com/knative/serving/releases/download/${KNATIVE_VERSION}/serving-core.yaml"
log "installing net-istio ${KNATIVE_VERSION}"
kubectl apply -f "https://github.com/knative/net-istio/releases/download/${KNATIVE_VERSION}/net-istio.yaml"

# --- 3) sidecar injection + PERMISSIVE mTLS for knative-serving --------------
log "enabling Istio sidecar injection on knative-serving"
kubectl label namespace knative-serving istio-injection=enabled --overwrite
kubectl apply -f - <<'EOF'
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata: { name: default, namespace: knative-serving }
spec: { mtls: { mode: PERMISSIVE } }
EOF

# --- 4) domain (Magic DNS via sslip.io) -------------------------------------
if [[ -z "$KNATIVE_DOMAIN" ]]; then
  local_ip="${KNATIVE_DOMAIN_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')}"
  [[ -n "$local_ip" ]] && KNATIVE_DOMAIN="${local_ip}.sslip.io"
fi
if [[ -n "$KNATIVE_DOMAIN" ]]; then
  log "setting Knative domain -> ${KNATIVE_DOMAIN}"
  kubectl patch configmap/config-domain -n knative-serving --type merge \
    -p "{\"data\":{\"example.com\":null,\"${KNATIVE_DOMAIN}\":\"\"}}"
else
  warn "no domain set; services will use the default example.com — set KNATIVE_DOMAIN_IP"
fi

log "waiting for Knative Serving to be ready"
kubectl -n knative-serving rollout status deploy/controller --timeout=300s
kubectl -n knative-serving rollout status deploy/activator  --timeout=300s

# --- 5) Eventing (optional) -------------------------------------------------
if [[ "$KNATIVE_EVENTING" == true ]]; then
  log "installing Knative Eventing ${KNATIVE_VERSION}"
  kubectl apply -f "https://github.com/knative/eventing/releases/download/${KNATIVE_VERSION}/eventing-crds.yaml"
  kubectl apply -f "https://github.com/knative/eventing/releases/download/${KNATIVE_VERSION}/eventing-core.yaml"
  kubectl apply -f "https://github.com/knative/eventing/releases/download/${KNATIVE_VERSION}/in-memory-channel.yaml"
  kubectl apply -f "https://github.com/knative/eventing/releases/download/${KNATIVE_VERSION}/mt-channel-broker.yaml"
  kubectl -n knative-eventing rollout status deploy/eventing-controller --timeout=300s
fi

NP="$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)"
echo
log "================= KNATIVE READY ================="
log "Istio ingress gateway (${KNATIVE_INGRESS_TYPE}) HTTP nodePort: ${NP:-<n/a>}"
log "Knative domain: ${KNATIVE_DOMAIN:-example.com}"
echo
cat <<EOF
Deploy a service:
  kubectl apply -f - <<'YAML'
  apiVersion: serving.knative.dev/v1
  kind: Service
  metadata: { name: hello }
  spec:
    template:
      spec:
        containers:
          - image: gcr.io/knative-samples/helloworld-go
            env: [{ name: TARGET, value: "World" }]
  YAML
  URL=\$(kubectl get ksvc hello -o jsonpath='{.status.url}')
  curl -H "Host: \${URL#http://}" http://<any-node-ip>:${NP:-<nodeport>}

Enable the Istio sidecar for your app's namespace + Knative service:
  kubectl label namespace <ns> istio-injection=enabled
  # add to the Knative Service spec.template.metadata.annotations:
  #   sidecar.istio.io/inject: "true"
EOF
