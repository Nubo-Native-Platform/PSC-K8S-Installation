#!/usr/bin/env bash
# 08 — Install OpenBao (open-source Vault fork) as an HA cluster with Integrated
# Storage (Raft, 3 replicas), then initialize and unseal it. Run from a master.
#
#   sudo ./scripts/08-openbao.sh
#
# Config via env vars (all optional):
#   OPENBAO_NAMESPACE   default openbao
#   OPENBAO_REPLICAS    default 3   (Raft voters; use 3 or 5)
#   OPENBAO_UI          default true
#   OPENBAO_INGRESS_TYPE ClusterIP|NodePort   default ClusterIP
#   OPENBAO_STORAGE_CLASS default = cluster default StorageClass
#   OPENBAO_INIT_FILE   default /root/openbao-init.json  (unseal keys + root token)
#
# SECURITY / STORAGE WARNINGS:
#   * The unseal keys and root token are written to OPENBAO_INIT_FILE (root-only).
#     Move them to real secret storage and remove the file. Losing them = losing
#     access; leaking them = full compromise.
#   * Raft (BoltDB) on NFS is NOT recommended (mmap + file locking). For
#     production use local/block volumes. This script works on any default SC for
#     testing but set OPENBAO_STORAGE_CLASS to local storage for real use.
set -euo pipefail

NS="${OPENBAO_NAMESPACE:-openbao}"
CHART_VERSION="${OPENBAO_CHART_VERSION:-0.29.6}"   # openbao-helm chart version (pinned)
REPLICAS="${OPENBAO_REPLICAS:-3}"
UI="${OPENBAO_UI:-true}"
INGRESS_TYPE="${OPENBAO_INGRESS_TYPE:-ClusterIP}"
STORAGE_CLASS="${OPENBAO_STORAGE_CLASS:-}"
INIT_FILE="${OPENBAO_INIT_FILE:-/root/openbao-init.json}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }
warn(){ echo -e "${y}[!]${n} $*"; }
die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"
command -v python3 >/dev/null || die "python3 required (to parse init output)"

# --- helm ---
if ! command -v helm >/dev/null 2>&1; then
  log "installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
fi

# Fetch the chart tarball from the stable github.com release URL. (The
# openbao.github.io repo index hands out pre-signed asset URLs that expire in
# ~1h, which breaks "helm install openbao/openbao" on slow/cached runs.)
CHART_TGZ="/tmp/openbao-${CHART_VERSION}.tgz"
log "downloading openbao-helm chart ${CHART_VERSION}"
curl -fsSL -o "$CHART_TGZ" \
  "https://github.com/openbao/openbao-helm/releases/download/openbao-${CHART_VERSION}/openbao-${CHART_VERSION}.tgz" \
  || die "could not download openbao chart ${CHART_VERSION}"

log "installing OpenBao (HA Raft, ${REPLICAS} replicas) in namespace ${NS}"
SC_ARGS=(); [[ -n "$STORAGE_CLASS" ]] && SC_ARGS=(--set "server.dataStorage.storageClass=${STORAGE_CLASS}")
helm upgrade --install openbao "$CHART_TGZ" -n "$NS" --create-namespace \
  --set server.ha.enabled=true \
  --set server.ha.raft.enabled=true \
  --set server.ha.replicas="${REPLICAS}" \
  --set "ui.enabled=${UI}" \
  "${SC_ARGS[@]}"

status_json(){ kubectl -n "$NS" exec "$1" -- bao status -format=json 2>/dev/null || true; }
# Wait until the 'bao' binary in the pod's main container responds (container
# Running). "Initialized" only covers init containers, so exec can race.
wait_bao_up(){ local p="$1" i; kubectl -n "$NS" get pod "$p" >/dev/null 2>&1 || { for i in $(seq 1 60); do kubectl -n "$NS" get pod "$p" >/dev/null 2>&1 && break; sleep 5; done; }
  for i in $(seq 1 60); do [[ "$(status_json "$p")" == *sealed* ]] && return 0; sleep 5; done; die "$p: bao never responded"; }

log "waiting for openbao-0 to start (it will be sealed — expected)"
wait_bao_up openbao-0
is_initialized(){ status_json openbao-0 | python3 -c 'import sys,json
try: print(str(json.load(sys.stdin).get("initialized")).lower())
except Exception: print("false")'; }
is_sealed(){ status_json "$1" | python3 -c 'import sys,json
try: print(str(json.load(sys.stdin).get("sealed")).lower())
except Exception: print("true")'; }

# --- init (once) ---
if [[ "$(is_initialized)" != "true" ]]; then
  log "initializing OpenBao (key-shares=5, key-threshold=3)"
  INIT_JSON="$(kubectl -n "$NS" exec openbao-0 -- bao operator init -key-shares=5 -key-threshold=3 -format=json)"
  umask 077; echo "$INIT_JSON" > "$INIT_FILE"; chmod 600 "$INIT_FILE"
  log "unseal keys + root token saved to ${INIT_FILE} (root-only) — SECURE THESE"
else
  warn "OpenBao already initialized; using existing ${INIT_FILE} to unseal"
  [[ -f "$INIT_FILE" ]] || die "no ${INIT_FILE}; cannot unseal without the keys"
  INIT_JSON="$(cat "$INIT_FILE")"
fi

readarray -t KEYS < <(echo "$INIT_JSON" | python3 -c 'import sys,json;print("\n".join(json.load(sys.stdin)["unseal_keys_b64"][:3]))')
ROOT="$(echo "$INIT_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["root_token"])')"
[[ ${#KEYS[@]} -eq 3 ]] || die "could not read 3 unseal keys from ${INIT_FILE}"

unseal_pod(){ local p="$1"; [[ "$(is_sealed "$p")" == "false" ]] && { log "$p already unsealed"; return 0; }
  local k; for k in "${KEYS[@]}"; do kubectl -n "$NS" exec "$p" -- bao operator unseal "$k" >/dev/null; done; log "$p unsealed"; }

log "unsealing openbao-0 (raft leader)"
unseal_pod openbao-0

for i in $(seq 1 $((REPLICAS-1))); do
  p="openbao-$i"
  wait_bao_up "$p"
  log "joining $p to raft + unsealing"
  kubectl -n "$NS" exec "$p" -- bao operator raft join http://openbao-0.openbao-internal:8200 >/dev/null 2>&1 || true
  sleep 3
  unseal_pod "$p"
done

if [[ "$INGRESS_TYPE" != ClusterIP ]]; then
  log "exposing openbao service as ${INGRESS_TYPE}"
  kubectl -n "$NS" patch svc openbao -p "{\"spec\":{\"type\":\"${INGRESS_TYPE}\"}}" || warn "could not patch service"
fi

log "waiting for all OpenBao pods to become Ready"
# The chart's StatefulSet uses the OnDelete strategy, so "rollout status" does
# not apply; wait on pod readiness instead (pods report Ready once unsealed).
kubectl -n "$NS" wait --for=condition=Ready pod -l app.kubernetes.io/name=openbao --timeout=180s \
  || warn "not all pods Ready yet — check: kubectl -n ${NS} get pods"

echo
log "================= OPENBAO READY (HA Raft x${REPLICAS}) ================="
log "unseal keys + root token: ${INIT_FILE}  (root-only; move to a safe place)"
log "raft peers:"; kubectl -n "$NS" exec openbao-0 -- sh -c "BAO_TOKEN='${ROOT}' bao operator raft list-peers" 2>/dev/null || warn "list-peers not ready yet"
cat <<EOF

Access (from your machine, with kubectl):
  kubectl -n ${NS} port-forward svc/openbao 8200:8200 &
  export BAO_ADDR=http://127.0.0.1:8200
  bao login <root-token from ${INIT_FILE}>
  # UI: http://127.0.0.1:8200/ui

After a pod/node restart, unsealed state is lost (no auto-unseal): re-run this
script, or unseal manually with 3 keys from ${INIT_FILE}.
EOF
