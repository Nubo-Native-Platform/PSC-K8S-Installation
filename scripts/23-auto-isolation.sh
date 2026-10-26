#!/usr/bin/env bash
# 23 — Auto-isolate NEW namespaces (Kyverno + Istio). Run on a master.
#
# After `install`, every namespace created from then on (kubectl, Helm, Argo CD, ...)
# is isolated automatically, exactly as `22-namespace-isolation.sh isolate` would do:
#   - label istio-injection=enabled
#   - Sidecar/default (REGISTRY_ONLY, egress ./*)
#   - ValidatingAdmissionPolicy + binding (pods must run istio-proxy; no hostNetwork)
#   - AuthorizationPolicy (only the namespace itself may call INTO it)
# Namespaces that ALREADY exist are NOT touched (they keep talking to each other).
# Open a new namespace up afterwards with scripts/22-namespace-isolation.sh allow ...
#
# Opt a new namespace OUT by creating it with the label:
#   psc.nubo-native-platform.io/isolation=off
# Platform namespaces (kube-*, istio-system, argocd, openbao, ...) are always skipped.
#
# Usage:
#   sudo ./scripts/23-auto-isolation.sh install
#   sudo ./scripts/23-auto-isolation.sh status
#   sudo ./scripts/23-auto-isolation.sh remove     # stops auto-isolation; keeps Kyverno
#
# Config (env):
#   KYVERNO_VERSION       chart version (default: latest)
#   KYVERNO_NS            Kyverno namespace (default kyverno)
#   INSTALL_KYVERNO       true|false  install Kyverno if missing (default true)
#   AUTO_ISOLATION_EXCLUDE  extra namespace names/patterns to skip, comma separated
#   REMOVE_KYVERNO        true        also uninstall Kyverno on 'remove'
#   DRY_RUN               true        print the YAML, change nothing
set -euo pipefail

KYVERNO_VERSION="${KYVERNO_VERSION:-}"
KYVERNO_NS="${KYVERNO_NS:-kyverno}"
INSTALL_KYVERNO="${INSTALL_KYVERNO:-true}"
AUTO_ISOLATION_EXCLUDE="${AUTO_ISOLATION_EXCLUDE:-}"
REMOVE_KYVERNO="${REMOVE_KYVERNO:-false}"
DRY_RUN="${DRY_RUN:-false}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

LBL_KEY="psc.nubo-native-platform.io/isolation"
ANN_KEY="psc.nubo-native-platform.io/allowed-namespaces"
ANN_FROM="psc.nubo-native-platform.io/allowed-callers"

g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }

# Same platform list as 22-namespace-isolation.sh, plus kube-* and the Kyverno namespace.
SKIP="kube-* default istio-system istio-ingress knative-serving knative-eventing argocd openbao velero \
monitoring ingress-nginx cert-manager external-secrets kubescape headlamp longhorn-system nfs-provisioner ${KYVERNO_NS}"

usage(){ sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

apply(){ if [[ "$DRY_RUN" == true ]]; then echo "# ---- [dry-run] would apply ----"; cat; echo; else kubectl apply -f -; fi; }

names_yaml(){ # YAML list items of namespace names to skip
  local x
  for x in $SKIP; do echo "          - \"$x\""; done
  local -a a=(); IFS=',' read -ra a <<<"$AUTO_ISOLATION_EXCLUDE" || true
  for x in "${a[@]:-}"; do [[ -n "$x" ]] && echo "          - \"$x\""; done
  return 0
}

render_rbac(){
  cat <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: psc-auto-isolation
  labels:
    rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:
- apiGroups: ["networking.istio.io"]
  resources: ["sidecars"]
  verbs: ["create", "get", "list", "update", "patch", "delete"]
- apiGroups: ["security.istio.io"]
  resources: ["authorizationpolicies"]
  verbs: ["create", "get", "list", "update", "patch", "delete"]
- apiGroups: ["admissionregistration.k8s.io"]
  resources: ["validatingadmissionpolicies", "validatingadmissionpolicybindings"]
  verbs: ["create", "get", "list", "update", "patch", "delete"]
EOF
}

render_policies(){
  local skip; skip="$(names_yaml)"
  cat <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: psc-isolate-ns-label
  annotations:
    policies.kyverno.io/title: Enable Istio injection on new namespaces
spec:
  rules:
  - name: label-injection
    match:
      any:
      - resources:
          kinds: ["Namespace"]
          operations: ["CREATE"]
    exclude:
      any:
      - resources:
          names:
${skip}
      - resources:
          selector:
            matchLabels:
              ${LBL_KEY}: "off"
    mutate:
      patchStrategicMerge:
        metadata:
          labels:
            istio-injection: enabled
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: psc-isolate-ns-generate
  annotations:
    policies.kyverno.io/title: Isolate new namespaces (Sidecar + admission policy)
spec:
  generateExisting: false
  rules:
  - name: sidecar
    match:
      any:
      - resources:
          kinds: ["Namespace"]
          operations: ["CREATE"]
    exclude:
      any:
      - resources:
          names:
${skip}
      - resources:
          selector:
            matchLabels:
              ${LBL_KEY}: "off"
    generate:
      apiVersion: networking.istio.io/v1
      kind: Sidecar
      name: default
      namespace: "{{request.object.metadata.name}}"
      synchronize: false
      data:
        metadata:
          labels:
            ${LBL_KEY}: "true"
          annotations:
            ${ANN_KEY}: ""
        spec:
          outboundTrafficPolicy:
            mode: REGISTRY_ONLY
          egress:
          - hosts:
            - "./*"
  - name: inbound-policy
    match:
      any:
      - resources:
          kinds: ["Namespace"]
          operations: ["CREATE"]
    exclude:
      any:
      - resources:
          names:
${skip}
      - resources:
          selector:
            matchLabels:
              ${LBL_KEY}: "off"
    generate:
      apiVersion: security.istio.io/v1
      kind: AuthorizationPolicy
      name: isolation-ingress
      namespace: "{{request.object.metadata.name}}"
      synchronize: false
      data:
        metadata:
          labels:
            ${LBL_KEY}: "true"
          annotations:
            ${ANN_FROM}: ""
        spec:
          action: ALLOW
          rules:
          - from:
            - source:
                namespaces: ["{{request.object.metadata.name}}"]
  - name: admission-policy
    match:
      any:
      - resources:
          kinds: ["Namespace"]
          operations: ["CREATE"]
    exclude:
      any:
      - resources:
          names:
${skip}
      - resources:
          selector:
            matchLabels:
              ${LBL_KEY}: "off"
    generate:
      apiVersion: admissionregistration.k8s.io/v1
      kind: ValidatingAdmissionPolicy
      name: "{{request.object.metadata.name}}-require-sidecar"
      synchronize: false
      data:
        metadata:
          labels:
            ${LBL_KEY}: "true"
        spec:
          failurePolicy: Fail
          matchConstraints:
            resourceRules:
            - apiGroups: [""]
              apiVersions: ["v1"]
              operations: ["CREATE"]
              resources: ["pods"]
          validations:
          - expression: "(has(object.spec.initContainers) && object.spec.initContainers.exists(c, c.name == 'istio-proxy')) || object.spec.containers.exists(c, c.name == 'istio-proxy')"
            message: "pods in this namespace must run the istio-proxy sidecar"
          - expression: "!has(object.spec.hostNetwork) || !object.spec.hostNetwork"
            message: "hostNetwork is not allowed in this namespace"
  - name: admission-binding
    match:
      any:
      - resources:
          kinds: ["Namespace"]
          operations: ["CREATE"]
    exclude:
      any:
      - resources:
          names:
${skip}
      - resources:
          selector:
            matchLabels:
              ${LBL_KEY}: "off"
    generate:
      apiVersion: admissionregistration.k8s.io/v1
      kind: ValidatingAdmissionPolicyBinding
      name: "{{request.object.metadata.name}}-require-sidecar"
      synchronize: false
      data:
        metadata:
          labels:
            ${LBL_KEY}: "true"
        spec:
          policyName: "{{request.object.metadata.name}}-require-sidecar"
          validationActions: ["Deny"]
          matchResources:
            namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: "{{request.object.metadata.name}}"
EOF
}

preflight(){
  command -v kubectl >/dev/null || die "kubectl not found — run this on a master"
  kubectl get crd sidecars.networking.istio.io >/dev/null 2>&1 \
    || die "Istio CRDs not found — install Istio first (./deploy.sh knative)"
}

cmd_install(){
  if [[ "$DRY_RUN" != true ]]; then
    preflight
    if ! kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
      [[ "$INSTALL_KYVERNO" == true ]] || die "Kyverno not installed (set INSTALL_KYVERNO=true to install it)"
      command -v helm >/dev/null || die "helm not found"
      log "installing Kyverno"
      helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
      helm repo update kyverno >/dev/null 2>&1 || true
      local ver=(); [[ -n "$KYVERNO_VERSION" ]] && ver=(--version "$KYVERNO_VERSION")
      local ok=false i
      for i in 1 2 3; do
        if helm upgrade --install kyverno kyverno/kyverno -n "$KYVERNO_NS" --create-namespace \
            "${ver[@]}" --wait --timeout 8m; then ok=true; break; fi
        warn "helm attempt $i failed — retrying"; sleep 5
      done
      [[ "$ok" == true ]] || die "Kyverno install failed"
    fi
  fi
  log "granting Kyverno permission to create Sidecars and admission policies"
  render_rbac | apply
  log "creating the auto-isolation policies (new namespaces only)"
  render_policies | apply
  [[ "$DRY_RUN" == true ]] && return 0
  log "done. Test:  kubectl create namespace test-auto && $0 status test-auto"
  warn "existing namespaces are untouched; new ones are isolated until you run: 22-namespace-isolation.sh allow <ns> <other-ns>"
}

cmd_status(){
  local ns="${1:-}"
  echo "== Kyverno"
  kubectl -n "$KYVERNO_NS" get deploy --no-headers 2>/dev/null | sed 's/^/   /' || echo "   not installed"
  echo "== auto-isolation policies"
  kubectl get clusterpolicy psc-isolate-ns-label psc-isolate-ns-generate --no-headers 2>/dev/null | sed 's/^/   /' \
    || echo "   NOT installed — new namespaces are not isolated automatically"
  if [[ -n "$ns" ]]; then
    echo "== namespace $ns"
    kubectl get ns "$ns" --show-labels --no-headers | sed 's/^/   /'
    kubectl -n "$ns" get sidecar default --no-headers 2>/dev/null | sed 's/^/   sidecar: /' || echo "   sidecar: none"
    kubectl get validatingadmissionpolicybinding "${ns}-require-sidecar" --no-headers 2>/dev/null | sed 's/^/   admission: /' || echo "   admission: none"
  fi
}

cmd_remove(){
  log "removing auto-isolation policies (already isolated namespaces stay isolated)"
  kubectl delete clusterpolicy psc-isolate-ns-label psc-isolate-ns-generate --ignore-not-found
  kubectl delete clusterrole psc-auto-isolation --ignore-not-found
  if [[ "$REMOVE_KYVERNO" == true ]]; then
    log "uninstalling Kyverno"
    helm uninstall kyverno -n "$KYVERNO_NS" || true
  else
    warn "Kyverno left installed (REMOVE_KYVERNO=true to uninstall it)"
  fi
}

sub="${1:-}"; [[ $# -gt 0 ]] && shift || true
case "$sub" in
  install) cmd_install ;;
  status)  cmd_status "$@" ;;
  remove)  cmd_remove ;;
  -h|--help|help) usage 0 ;;
  "")      usage 1 ;;
  *)       die "unknown command: $sub (use: install | status | remove)" ;;
esac
