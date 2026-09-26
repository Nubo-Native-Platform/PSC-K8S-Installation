#!/usr/bin/env bash
# 21 — Headlamp: an open-source web dashboard for Kubernetes, with the Kubescape
# plugin so the cluster's security/compliance scan results show in a browser.
# Run once on a master. Exposed via the nginx Ingress (reachable through HAProxy).
#
#   sudo HEADLAMP_HOST=headlamp.192.168.18.51.sslip.io ./scripts/21-headlamp.sh
#
# Config (env):
#   HEADLAMP_NS            default headlamp
#   HEADLAMP_HOST          Ingress host (required for the Ingress; e.g. sslip.io name)
#   INGRESS_CLASS          default nginx
#   KUBESCAPE_PLUGIN_VER   Kubescape Headlamp plugin release (default v0.11.2)
#   HEADLAMP_ADMIN         bind the login SA to cluster-admin (default false = read-only view)
set -euo pipefail
HEADLAMP_NS="${HEADLAMP_NS:-headlamp}"
HEADLAMP_HOST="${HEADLAMP_HOST:-}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
KUBESCAPE_PLUGIN_VER="${KUBESCAPE_PLUGIN_VER:-v0.11.2}"
HEADLAMP_ADMIN="${HEADLAMP_ADMIN:-false}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"
command -v helm >/dev/null || die "helm not found"

helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ >/dev/null 2>&1 || true
helm repo update headlamp >/dev/null 2>&1 || true

PLUGIN_URL="https://github.com/kubescape/headlamp-plugin/releases/download/${KUBESCAPE_PLUGIN_VER}/headlamp-plugin-${KUBESCAPE_PLUGIN_VER}.tar.gz"
VALUES="$(mktemp)"
cat > "$VALUES" <<YAML
config:
  pluginsDir: /headlamp/plugins
  watchPlugins: false
initContainers:
  - name: kubescape-plugin
    image: alpine:3.20
    command: ["/bin/sh","-c"]
    args:
      - "apk add --no-cache ca-certificates tar >/dev/null 2>&1; wget -qO /tmp/ks.tgz ${PLUGIN_URL} && tar xzf /tmp/ks.tgz -C /headlamp/plugins && echo INSTALLED && ls /headlamp/plugins"
    volumeMounts:
      - { name: plugins, mountPath: /headlamp/plugins }
volumeMounts:
  - { name: plugins, mountPath: /headlamp/plugins }
volumes:
  - { name: plugins, emptyDir: {} }
YAML
if [[ -n "$HEADLAMP_HOST" ]]; then
  cat >> "$VALUES" <<YAML
ingress:
  enabled: true
  ingressClassName: ${INGRESS_CLASS}
  hosts:
    - host: ${HEADLAMP_HOST}
      paths:
        - { path: /, type: Prefix }
YAML
else
  warn "HEADLAMP_HOST not set — installing without an Ingress (reach it via kubectl port-forward)"
fi

# The chart's CDN (release-assets.githubusercontent.com) can be flaky — pull the
# chart to a local file with retries, then install from it.
log "fetching Headlamp chart"
CHART=""
for i in $(seq 1 8); do
  if helm pull headlamp/headlamp -d /tmp 2>/dev/null; then CHART=$(ls -t /tmp/headlamp-*.tgz 2>/dev/null | head -1); [ -n "$CHART" ] && break; fi
  warn "chart pull attempt $i failed — retrying"; sleep 6
done
[[ -n "$CHART" ]] || die "could not pull the Headlamp chart"

log "installing Headlamp + Kubescape plugin (${KUBESCAPE_PLUGIN_VER})"
helm upgrade --install headlamp "$CHART" -n "$HEADLAMP_NS" --create-namespace -f "$VALUES" --wait --timeout 6m \
  || die "headlamp install failed"
rm -f "$VALUES"

# --- login access: a ServiceAccount token ----------------------------------
log "granting the headlamp ServiceAccount read access (Kubescape CRDs + cluster)"
if [[ "$HEADLAMP_ADMIN" == true ]]; then
  kubectl create clusterrolebinding headlamp-admin --clusterrole=cluster-admin --serviceaccount="${HEADLAMP_NS}:headlamp" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
else
  kubectl create clusterrolebinding headlamp-view --clusterrole=view --serviceaccount="${HEADLAMP_NS}:headlamp" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f - >/dev/null <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: headlamp-security-read }
rules:
  - apiGroups: ["spdx.softwarecomposition.kubescape.io"]
    resources: ["*"]
    verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: headlamp-security-read }
subjects: [{ kind: ServiceAccount, name: headlamp, namespace: ${HEADLAMP_NS} }]
roleRef: { kind: ClusterRole, name: headlamp-security-read, apiGroup: rbac.authorization.k8s.io }
YAML
fi

kubectl -n "$HEADLAMP_NS" rollout status deploy/headlamp --timeout=180s >/dev/null 2>&1 || true
echo
log "================= HEADLAMP READY ================="
[[ -n "$HEADLAMP_HOST" ]] && echo "URL   : http://${HEADLAMP_HOST}/   (through the HAProxy LB / nginx ingress)"
[[ -z "$HEADLAMP_HOST" ]] && echo "Access: kubectl -n ${HEADLAMP_NS} port-forward svc/headlamp 8080:80  ->  http://localhost:8080"
cat <<EOF
Login : choose "Token" and paste a token from:
    kubectl create token headlamp -n ${HEADLAMP_NS} --duration=24h
The Kubescape plugin adds a "Kubescape" section (compliance + vulnerabilities).
EOF
