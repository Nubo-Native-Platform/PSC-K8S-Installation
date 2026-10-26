#!/usr/bin/env bash
# 22 — Namespace isolation (Istio sidecar based). Run on a master.
#
# Isolates a namespace so its pods can ONLY talk to services inside the same
# namespace (plus anything you explicitly allow). Other namespaces can still call
# INTO it. Works on Flannel (no NetworkPolicy support needed) because the block is
# enforced by the Istio sidecar, not by the CNI.
#
# What "isolate" creates, all scoped to the one namespace:
#   1. label  istio-injection=enabled          (pods get the istio-proxy sidecar)
#   2. Sidecar/default  REGISTRY_ONLY           (egress limited to ./* + allowed list)
#   3. ValidatingAdmissionPolicy + binding      (rejects pods WITHOUT the sidecar or
#                                                with hostNetwork, so isolation can't be skipped)
#
# Usage (on a master, as root or with KUBECONFIG set):
#   sudo ./scripts/22-namespace-isolation.sh isolate <ns> [allow-ns1,allow-ns2]
#   sudo ./scripts/22-namespace-isolation.sh allow <ns> <other-ns> [<other-ns> ...]
#   sudo ./scripts/22-namespace-isolation.sh unallow <ns> <other-ns> [<other-ns> ...]
#   sudo ./scripts/22-namespace-isolation.sh allow-external <ns> <host> [port] [TLS|HTTP]
#   sudo ./scripts/22-namespace-isolation.sh allow-from <ns> <caller-ns> [<caller-ns> ...]    # let others call INTO <ns>
#   sudo ./scripts/22-namespace-isolation.sh unallow-from <ns> <caller-ns> [...]
#   sudo ./scripts/22-namespace-isolation.sh status <ns>
#   sudo ./scripts/22-namespace-isolation.sh remove <ns>
#
# Config (env):
#   ISOLATION_ADMISSION       true|false  create the admission policy (default true)
#   ISOLATION_ALLOW_EXISTING  true        allow isolating a namespace that already has pods
#   ISOLATION_FORCE           true        allow system namespaces (NOT recommended)
#   ISOLATION_YES             true        skip the confirmation prompt on 'remove'
#   DRY_RUN                   true        print what would be applied, change nothing
set -euo pipefail

ISOLATION_ADMISSION="${ISOLATION_ADMISSION:-true}"
ISOLATION_ALLOW_EXISTING="${ISOLATION_ALLOW_EXISTING:-false}"
ISOLATION_FORCE="${ISOLATION_FORCE:-false}"
ISOLATION_YES="${ISOLATION_YES:-false}"
DRY_RUN="${DRY_RUN:-false}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

ANN_KEY="psc.nubo-native-platform.io/allowed-namespaces"
ANN_FROM="psc.nubo-native-platform.io/allowed-callers"
LBL_KEY="psc.nubo-native-platform.io/isolation"

g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }

# Namespaces that cluster components depend on. Isolating them would break the cluster.
PROTECTED="default kube-system kube-public kube-node-lease kube-flannel istio-system istio-ingress \
knative-serving knative-eventing argocd openbao velero monitoring ingress-nginx cert-manager \
external-secrets kubescape headlamp longhorn-system nfs-provisioner"

usage(){ sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---- helpers -----------------------------------------------------------------
valid_ns(){ [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#1} -le 63 ]]; }
valid_host(){ [[ "$1" =~ ^(\*\.)?([a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }

csv_add(){ local csv="$1" item="$2"; case ",$csv," in *",$item,"*) echo "$csv";; *) echo "${csv:+$csv,}$item";; esac; }
csv_del(){ local csv="$1" item="$2" out="" x; local -a a=(); IFS=',' read -ra a <<<"$csv" || true
  for x in "${a[@]:-}"; do [[ -n "$x" && "$x" != "$item" ]] && out="${out:+$out,}$x"; done; echo "$out"; }

is_protected(){ local p; for p in $PROTECTED; do [[ "$p" == "$1" ]] && return 0; done; return 1; }

# apply YAML from stdin (or just print it when DRY_RUN=true)
apply(){
  if [[ "$DRY_RUN" == true ]]; then echo "# ---- [dry-run] would apply ----"; cat; echo; else kubectl apply -f - ; fi
}
run(){ if [[ "$DRY_RUN" == true ]]; then echo "[dry-run] $*"; else "$@"; fi; }

preflight(){
  command -v kubectl >/dev/null || die "kubectl not found — run this on a master"
  kubectl get crd sidecars.networking.istio.io >/dev/null 2>&1 \
    || die "Istio CRDs not found — install Istio first (./deploy.sh knative)"
  kubectl -n istio-system get deploy istiod >/dev/null 2>&1 \
    || warn "istiod deployment not found in istio-system — injection may not work"
}

get_allowed(){
  kubectl -n "$1" get sidecar default -o "jsonpath={.metadata.annotations.psc\\.nubo-native-platform\\.io/allowed-namespaces}" 2>/dev/null || true
}

get_callers(){
  kubectl -n "$1" get authorizationpolicy isolation-ingress -o "jsonpath={.metadata.annotations.psc\.nubo-native-platform\.io/allowed-callers}" 2>/dev/null || true
}
has_authz(){ kubectl -n "$1" get authorizationpolicy isolation-ingress >/dev/null 2>&1; }

# ---- renderers ---------------------------------------------------------------
render_sidecar(){   # $1=ns  $2=csv of allowed namespaces
  local ns="$1" csv="$2" x
  local -a a=()
  cat <<EOF
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: ${ns}
  labels:
    ${LBL_KEY}: "true"
  annotations:
    ${ANN_KEY}: "${csv}"
spec:
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY
  egress:
  - hosts:
    - "./*"
EOF
  IFS=',' read -ra a <<<"$csv" || true
  for x in "${a[@]:-}"; do [[ -n "$x" ]] && echo "    - \"${x}/*\""; done
  return 0
}

render_authz(){     # $1=ns  $2=csv of namespaces allowed to call INTO ns
  local ns="$1" csv="$2" x
  local -a a=()
  cat <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: isolation-ingress
  namespace: ${ns}
  labels:
    ${LBL_KEY}: "true"
  annotations:
    ${ANN_FROM}: "${csv}"
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces:
        - "${ns}"
EOF
  IFS=',' read -ra a <<<"$csv" || true
  for x in "${a[@]:-}"; do [[ -n "$x" ]] && echo "        - \"${x}\""; done
  return 0
}

render_admission(){ # $1=ns
  local ns="$1"
  cat <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: ${ns}-require-sidecar
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
    message: "pods in ${ns} must run the istio-proxy sidecar"
  - expression: "!has(object.spec.hostNetwork) || !object.spec.hostNetwork"
    message: "hostNetwork is not allowed in ${ns}"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: ${ns}-require-sidecar
  labels:
    ${LBL_KEY}: "true"
spec:
  policyName: ${ns}-require-sidecar
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: ${ns}
EOF
}

render_serviceentry(){ # $1=ns $2=host $3=port $4=protocol(TLS|HTTP)
  local ns="$1" host="$2" port="$3" proto="$4" name resolution="DNS"
  # Wildcard hosts can't be resolved by name; use NONE (traffic goes to the IP the app resolved).
  [[ "$host" == \*.* ]] && resolution="NONE"
  name="ext-$(echo "$host" | tr '[:upper:]' '[:lower:]' | sed 's/\*/wildcard/g; s/[^a-z0-9]/-/g')-${port}"
  name="${name:0:63}"; name="${name%-}"
  cat <<EOF
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    ${LBL_KEY}: "ext"
spec:
  exportTo: ["."]
  hosts: ["${host}"]
  ports:
  - number: ${port}
    name: $(echo "$proto" | tr '[:upper:]' '[:lower:]')-${port}
    protocol: ${proto}
  resolution: ${resolution}
  location: MESH_EXTERNAL
EOF
}

# ---- commands ----------------------------------------------------------------
cmd_isolate(){
  local ns="${1:-}" allow="${2:-}"
  [[ -n "$ns" ]] || die "usage: isolate <ns> [allow-ns1,allow-ns2]"
  valid_ns "$ns" || die "invalid namespace name: $ns"
  if is_protected "$ns" && [[ "$ISOLATION_FORCE" != true ]]; then
    die "'$ns' is a system/platform namespace — refusing (cluster components depend on it). Set ISOLATION_FORCE=true only if you are sure."
  fi
  preflight

  local csv="" x; local -a a=()
  IFS=',' read -ra a <<<"$allow" || true
  for x in "${a[@]:-}"; do
    [[ -z "$x" ]] && continue
    valid_ns "$x" || die "invalid allowed namespace: $x"
    [[ "$x" == "$ns" ]] && continue
    kubectl get ns "$x" >/dev/null 2>&1 || warn "allowed namespace '$x' does not exist (yet) — the entry is kept"
    csv="$(csv_add "$csv" "$x")"
  done

  if kubectl get ns "$ns" >/dev/null 2>&1; then
    local pods; pods="$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$pods" -gt 0 && "$ISOLATION_ALLOW_EXISTING" != true ]]; then
      die "namespace '$ns' already has $pods pod(s). Isolating a live namespace can break apps that call outside it, and pods only get the sidecar after a restart. Review the guide (docs/NAMESPACE-ISOLATION.md, 'existing namespace'), then re-run with ISOLATION_ALLOW_EXISTING=true."
    fi
  else
    log "creating namespace $ns"
    if [[ "$DRY_RUN" == true ]]; then echo "[dry-run] kubectl create namespace $ns"; else kubectl create namespace "$ns"; fi
  fi

  log "enabling Istio injection on $ns"
  if [[ "$DRY_RUN" == true ]] && ! kubectl get ns "$ns" >/dev/null 2>&1; then
    echo "[dry-run] kubectl label namespace $ns istio-injection=enabled --overwrite"
  else
    run kubectl label namespace "$ns" istio-injection=enabled --overwrite
  fi

  log "applying Sidecar (egress: ./*${csv:+, ${csv//,/, }}) in $ns"
  render_sidecar "$ns" "$csv" | apply

  log "applying AuthorizationPolicy (only $ns itself may call into it) in $ns"
  render_authz "$ns" "" | apply

  if [[ "$ISOLATION_ADMISSION" == true ]]; then
    local apis; apis="$(kubectl api-resources --api-group=admissionregistration.k8s.io -o name 2>/dev/null || true)"
    if [[ "$apis" == *validatingadmissionpolicies* ]]; then
      log "applying admission policy (pods must run istio-proxy; no hostNetwork) for $ns"
      render_admission "$ns" | apply
    else
      warn "ValidatingAdmissionPolicy API not available on this cluster — skipping the admission policy"
    fi
  else
    warn "admission policy skipped (ISOLATION_ADMISSION=false) — pods without the sidecar can bypass isolation"
  fi

  log "namespace '$ns' is isolated. Verify with:  $0 status $ns"
}

need_isolated(){
  local ns="${1:-}"
  [[ -n "$ns" ]] || die "namespace required"
  valid_ns "$ns" || die "invalid namespace name: $ns"
  preflight
  kubectl -n "$ns" get sidecar default >/dev/null 2>&1 \
    || die "'$ns' has no Sidecar/default — isolate it first:  $0 isolate $ns"
}

cmd_allow(){
  local ns="${1:-}"; shift || true
  [[ $# -ge 1 ]] || die "usage: allow <ns> <other-ns> [<other-ns> ...]"
  need_isolated "$ns"
  local csv x; csv="$(get_allowed "$ns")"
  for x in "$@"; do
    valid_ns "$x" || die "invalid namespace name: $x"
    [[ "$x" == "$ns" ]] && { warn "'$x' is the namespace itself — already allowed"; continue; }
    kubectl get ns "$x" >/dev/null 2>&1 || warn "namespace '$x' does not exist (yet) — the entry is kept"
    csv="$(csv_add "$csv" "$x")"
  done
  log "updating Sidecar in $ns (allowed: ${csv:-none})"
  render_sidecar "$ns" "$csv" | apply
  for x in "$@"; do
    [[ "$x" == "$ns" ]] && continue
    if has_authz "$x"; then
      log "'$x' is isolated too — letting $ns call into it"
      render_authz "$x" "$(csv_add "$(get_callers "$x")" "$ns")" | apply
    fi
  done
  warn "this lets EVERY pod in '$ns' call ALL services in: $*  (it is namespace-wide, not per workload)"
}

cmd_unallow(){
  local ns="${1:-}"; shift || true
  [[ $# -ge 1 ]] || die "usage: unallow <ns> <other-ns> [<other-ns> ...]"
  need_isolated "$ns"
  local csv x; csv="$(get_allowed "$ns")"
  for x in "$@"; do csv="$(csv_del "$csv" "$x")"; done
  log "updating Sidecar in $ns (allowed: ${csv:-none})"
  render_sidecar "$ns" "$csv" | apply
  for x in "$@"; do
    if has_authz "$x"; then render_authz "$x" "$(csv_del "$(get_callers "$x")" "$ns")" | apply; fi
  done
}

cmd_allow_from(){
  local ns="${1:-}"; shift || true
  [[ $# -ge 1 ]] || die "usage: allow-from <ns> <caller-ns> [<caller-ns> ...]"
  need_isolated "$ns"; has_authz "$ns" || die "'$ns' has no AuthorizationPolicy — re-run isolate on it"
  local csv x; csv="$(get_callers "$ns")"
  for x in "$@"; do valid_ns "$x" || die "invalid namespace name: $x"; csv="$(csv_add "$csv" "$x")"; done
  log "letting ${*} call into $ns"
  render_authz "$ns" "$csv" | apply
  warn "callers must have an Istio sidecar (istio-injection=enabled); pods without one have no identity and stay blocked"
}

cmd_unallow_from(){
  local ns="${1:-}"; shift || true
  [[ $# -ge 1 ]] || die "usage: unallow-from <ns> <caller-ns> [<caller-ns> ...]"
  need_isolated "$ns"; has_authz "$ns" || die "'$ns' has no AuthorizationPolicy"
  local csv x; csv="$(get_callers "$ns")"
  for x in "$@"; do csv="$(csv_del "$csv" "$x")"; done
  render_authz "$ns" "$csv" | apply
}

cmd_allow_external(){
  local ns="${1:-}" host="${2:-}" port="${3:-443}" proto="${4:-}"
  [[ -n "$ns" && -n "$host" ]] || die "usage: allow-external <ns> <host> [port] [TLS|HTTP]"
  need_isolated "$ns"
  valid_host "$host" || die "invalid host: $host (use a DNS name such as api.example.com or *.example.com)"
  [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || die "invalid port: $port"
  if [[ -z "$proto" ]]; then case "$port" in 80|8080) proto=HTTP;; *) proto=TLS;; esac; fi
  proto="$(echo "$proto" | tr '[:lower:]' '[:upper:]')"
  [[ "$proto" == TLS || "$proto" == HTTP ]] || die "protocol must be TLS or HTTP (got '$proto')"
  log "allowing $ns -> $host:$port ($proto)"
  render_serviceentry "$ns" "$host" "$port" "$proto" | apply
}

cmd_status(){
  local ns="${1:-}"
  [[ -n "$ns" ]] || die "usage: status <ns>"
  valid_ns "$ns" || die "invalid namespace name: $ns"
  preflight
  kubectl get ns "$ns" >/dev/null 2>&1 || die "namespace '$ns' not found"
  echo "== namespace labels"
  kubectl get ns "$ns" --show-labels --no-headers | sed 's/^/   /'
  echo "== Sidecar (egress policy)"
  if kubectl -n "$ns" get sidecar default >/dev/null 2>&1; then
    kubectl -n "$ns" get sidecar default -o jsonpath='   mode:  {.spec.outboundTrafficPolicy.mode}{"\n"}   hosts: {.spec.egress[*].hosts}{"\n"}'
  else
    echo "   NONE — namespace is NOT isolated"
  fi
  echo "== inbound (AuthorizationPolicy)"
  kubectl -n "$ns" get authorizationpolicy isolation-ingress -o jsonpath='   allowed callers: {.metadata.annotations.psc\.nubo-native-platform\.io/allowed-callers} (plus the namespace itself){"
"}' 2>/dev/null || echo "   NONE — other namespaces can call into $ns"
  echo "== external hosts allowed (ServiceEntry)"
  kubectl -n "$ns" get serviceentry -l "${LBL_KEY}=ext" --no-headers 2>/dev/null | sed 's/^/   /' || true
  echo "== admission policy"
  kubectl get validatingadmissionpolicybinding "${ns}-require-sidecar" --no-headers 2>/dev/null | sed 's/^/   /' \
    || echo "   none"
  echo "== pods (READY should be N/N with the istio-proxy sidecar counted)"
  kubectl -n "$ns" get pods --no-headers 2>/dev/null | sed 's/^/   /' || true
}

cmd_remove(){
  local ns="${1:-}"
  [[ -n "$ns" ]] || die "usage: remove <ns>"
  valid_ns "$ns" || die "invalid namespace name: $ns"
  preflight
  if [[ "$ISOLATION_YES" != true && "$DRY_RUN" != true ]]; then
    read -rp "Remove isolation from '$ns' (egress becomes open again)? Type the namespace name to confirm: " a
    [[ "$a" == "$ns" ]] || die "aborted"
  fi
  log "removing isolation objects from $ns (the namespace and its workloads are NOT deleted)"
  run kubectl delete validatingadmissionpolicybinding "${ns}-require-sidecar" --ignore-not-found
  run kubectl delete validatingadmissionpolicy "${ns}-require-sidecar" --ignore-not-found
  run kubectl -n "$ns" delete serviceentry -l "${LBL_KEY}=ext" --ignore-not-found
  run kubectl -n "$ns" delete authorizationpolicy isolation-ingress --ignore-not-found
  run kubectl -n "$ns" delete sidecar default --ignore-not-found
  run kubectl label namespace "$ns" istio-injection- || true
  warn "running pods keep their sidecar until restarted; only egress blocking is removed"
}

# ---- dispatch ----------------------------------------------------------------
sub="${1:-}"; [[ $# -gt 0 ]] && shift || true
case "$sub" in
  isolate)        cmd_isolate "$@" ;;
  allow)          cmd_allow "$@" ;;
  unallow)        cmd_unallow "$@" ;;
  allow-external) cmd_allow_external "$@" ;;
  allow-from)     cmd_allow_from "$@" ;;
  unallow-from)   cmd_unallow_from "$@" ;;
  status)         cmd_status "$@" ;;
  remove)         cmd_remove "$@" ;;
  -h|--help|help) usage 0 ;;
  "")             usage 1 ;;
  *)              die "unknown command: $sub (use: isolate | allow | unallow | allow-from | unallow-from | allow-external | status | remove)" ;;
esac
