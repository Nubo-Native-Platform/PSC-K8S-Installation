#!/usr/bin/env bash
# =============================================================================
#  deploy.sh — orchestrate a whole cluster from ONE machine (Ansible-style).
#  Reads inventory.conf, SSHes to every node, and runs k8s.sh on each.
#
#    ./deploy.sh                 # full install (all nodes) + storage
#    ./deploy.sh -i my.conf      # use a different inventory
#    ./deploy.sh check           # test SSH + sudo to every node
#    ./deploy.sh storage         # (re)install Longhorn only
#    ./deploy.sh upgrade 1.31.2  # rolling upgrade of the whole cluster
#    ./deploy.sh reset           # kubeadm reset every node (DESTROYS cluster)
#
#  Needs on THIS machine: bash, ssh, scp. Nodes need: sudo, curl. Linux/mac/WSL.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INV="$HERE/inventory.conf"

# ---- arg parse ----
[[ "${1:-}" == "-i" ]] && { INV="$2"; shift 2; }
ACTION="${1:-install}"

g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; b='\033[0;36m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }
step(){ echo -e "\n${b}==>${n} $*"; }
warn(){ echo -e "${y}[!]${n} $*"; }
die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }

[[ -f "$INV" ]] || die "inventory not found: $INV"
[[ -f "$HERE/k8s.sh" ]] || die "k8s.sh not found next to deploy.sh"

# ---- parse inventory.conf ----
declare -A SET; MASTERS=(); WORKERS=(); M_IP=(); W_IP=(); section=""
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"; line="$(echo "$line" | sed 's/[[:space:]]*$//;s/^[[:space:]]*//')"
  [[ -z "$line" ]] && continue
  case "$line" in
    "[settings]") section=settings; continue;;
    "[masters]")  section=masters;  continue;;
    "[workers]")  section=workers;  continue;;
  esac
  if [[ "$section" == settings ]]; then
    k="${line%%=*}"; v="${line#*=}"; SET[$k]="$v"
  elif [[ "$section" == masters ]]; then
    name="$(awk '{print $1}' <<<"$line")"; ip="$(awk '{print $2}' <<<"$line")"
    MASTERS+=("$name"); M_IP+=("$ip")
  elif [[ "$section" == workers ]]; then
    name="$(awk '{print $1}' <<<"$line")"; ip="$(awk '{print $2}' <<<"$line")"
    WORKERS+=("$name"); W_IP+=("$ip")
  fi
done < "$INV"

[[ ${#MASTERS[@]} -ge 1 ]] || die "no [masters] defined in inventory"

SSH_USER="${SET[SSH_USER]:-root}"
SSH_PORT="${SET[SSH_PORT]:-22}"
SSH_KEY="${SET[SSH_KEY]:-}"; SSH_KEY="${SSH_KEY/#\~/$HOME}"
K8S_MINOR="${SET[K8S_MINOR]:-1.31}"; K8S_PATCH="${SET[K8S_PATCH]:-}"
CNI="${SET[CNI]:-flannel}"; POD_CIDR="${SET[POD_CIDR]:-10.244.0.0/16}"
CPE="${SET[CONTROL_PLANE_ENDPOINT]:-}"; LONGHORN="${SET[LONGHORN]:-true}"

# HA auto-detect
if [[ ${#MASTERS[@]} -gt 1 ]]; then
  HA_MODE=multi
  [[ -n "$CPE" ]] || die "You listed ${#MASTERS[@]} masters (HA) — set CONTROL_PLANE_ENDPOINT (VIP/LB) in inventory.conf"
else
  HA_MODE=single
fi

SSH_OPTS=( -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$SSH_PORT" )
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=( -i "$SSH_KEY" )
rsh(){ ssh "${SSH_OPTS[@]}" "${SSH_USER}@$1" "$2"; }
push(){ scp "${SSH_OPTS[@]}" "$HERE/k8s.sh" "${SSH_USER}@$1:/tmp/k8s.sh" >/dev/null; }

# common env prefix passed into k8s.sh on the remote node
envstr(){
  echo "K8S_MINOR='$K8S_MINOR' K8S_PATCH='$K8S_PATCH' CNI='$CNI' HA_MODE='$HA_MODE' POD_CIDR='$POD_CIDR' CONTROL_PLANE_ENDPOINT='$CPE'"
}

print_plan(){
  echo -e "${b}Cluster plan${n} (inventory: $INV)"
  echo "  mode      : $HA_MODE  (${#MASTERS[@]} master(s), ${#WORKERS[@]} worker(s))"
  echo "  k8s       : v${K8S_MINOR} ${K8S_PATCH:+patch $K8S_PATCH}"
  echo "  cni       : $CNI    storage: $([[ $LONGHORN == true ]] && echo longhorn || echo none)"
  [[ $HA_MODE == multi ]] && echo "  endpoint  : $CPE"
  echo "  ssh       : ${SSH_USER}@... :$SSH_PORT ${SSH_KEY:+key=$SSH_KEY}"
  printf "  masters   :"; for i in "${!MASTERS[@]}"; do printf " %s(%s)" "${MASTERS[$i]}" "${M_IP[$i]}"; done; echo
  printf "  workers   :"; for i in "${!WORKERS[@]}"; do printf " %s(%s)" "${WORKERS[$i]}" "${W_IP[$i]}"; done; echo
}

cmd_check(){
  print_plan; step "testing SSH + sudo on every node"
  local ok=1
  for i in "${!MASTERS[@]}"; do
    if rsh "${M_IP[$i]}" "sudo -n true 2>/dev/null || sudo true" >/dev/null 2>&1; then log "OK  ${MASTERS[$i]} (${M_IP[$i]})"; else warn "FAIL ${MASTERS[$i]} (${M_IP[$i]})"; ok=0; fi
  done
  for i in "${!WORKERS[@]}"; do
    if rsh "${W_IP[$i]}" "sudo -n true 2>/dev/null || sudo true" >/dev/null 2>&1; then log "OK  ${WORKERS[$i]} (${W_IP[$i]})"; else warn "FAIL ${WORKERS[$i]} (${W_IP[$i]})"; ok=0; fi
  done
  [[ $ok == 1 ]] && log "all nodes reachable" || die "some nodes failed — fix SSH/sudo above"
}

cmd_install(){
  print_plan
  echo; read -rp "Proceed with install? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || die "aborted"

  local M0="${M_IP[0]}"
  step "1/4  init primary master  ${MASTERS[0]} ($M0)"
  push "$M0"
  rsh "$M0" "sudo $(envstr) bash /tmp/k8s.sh init"

  step "2/4  fetching join commands from $M0"
  WJOIN="$(rsh "$M0" "sudo bash /tmp/k8s.sh token" | sed -n 's/^JOIN=//p' | tr -d '\"')"
  [[ -n "$WJOIN" ]] || die "could not get worker join command"
  if [[ $HA_MODE == multi ]]; then
    CK="$(rsh "$M0" "sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1")"
    MJOIN="$WJOIN --control-plane --certificate-key $CK"
  fi

  if [[ $HA_MODE == multi && ${#MASTERS[@]} -gt 1 ]]; then
    step "3/4  joining extra masters"
    for i in $(seq 1 $((${#MASTERS[@]}-1))); do
      log "join master ${MASTERS[$i]} (${M_IP[$i]})"; push "${M_IP[$i]}"
      rsh "${M_IP[$i]}" "sudo $(envstr) JOIN='$MJOIN' bash /tmp/k8s.sh join"
    done
  fi

  step "3/4  joining workers"
  for i in "${!WORKERS[@]}"; do
    log "join worker ${WORKERS[$i]} (${W_IP[$i]})"; push "${W_IP[$i]}"
    rsh "${W_IP[$i]}" "sudo $(envstr) JOIN='$WJOIN' bash /tmp/k8s.sh join"
  done

  if [[ "$LONGHORN" == true ]]; then
    step "4/4  installing Longhorn storage (via $M0)"
    rsh "$M0" "sudo bash /tmp/k8s.sh storage" || warn "storage step reported issues"
  fi

  step "DONE"; rsh "$M0" "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide" || true
  log "kubeconfig on primary master: /etc/kubernetes/admin.conf  (scp it to your laptop for kubectl)"
}

cmd_storage(){ push "${M_IP[0]}"; rsh "${M_IP[0]}" "sudo LONGHORN_VERSION=${SET[LONGHORN_VERSION]:-v1.7.2} bash /tmp/k8s.sh storage"; }

cmd_upgrade(){
  local T="${1:?usage: deploy.sh upgrade <version e.g 1.31.2>}"
  print_plan; echo; read -rp "Upgrade whole cluster to v$T (one minor only)? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || die "aborted"
  step "upgrade primary master ${MASTERS[0]}"; push "${M_IP[0]}"
  rsh "${M_IP[0]}" "sudo bash /tmp/k8s.sh upgrade $T first-master"
  for i in $(seq 1 $((${#MASTERS[@]}-1)) 2>/dev/null); do
    [[ $i -lt ${#MASTERS[@]} ]] || break
    step "upgrade master ${MASTERS[$i]}"; push "${M_IP[$i]}"
    rsh "${M_IP[$i]}" "sudo bash /tmp/k8s.sh upgrade $T master"
  done
  for i in "${!WORKERS[@]}"; do
    step "upgrade worker ${WORKERS[$i]}"
    rsh "${M_IP[0]}" "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl drain ${WORKERS[$i]} --ignore-daemonsets --delete-emptydir-data --timeout=120s" || true
    push "${W_IP[$i]}"; rsh "${W_IP[$i]}" "sudo bash /tmp/k8s.sh upgrade $T worker"
    rsh "${M_IP[0]}" "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl uncordon ${WORKERS[$i]}" || true
  done
  log "cluster upgraded to v$T"
}

cmd_reset(){
  print_plan; echo; warn "This DESTROYS the cluster on every node."
  read -rp "Type the word DESTROY to continue: " a; [[ "$a" == DESTROY ]] || die "aborted"
  for ip in "${W_IP[@]}" "${M_IP[@]}"; do
    log "reset $ip"; rsh "$ip" "sudo kubeadm reset -f; sudo rm -rf /etc/cni/net.d ~/.kube" || true
  done
  log "reset complete"
}

case "$ACTION" in
  check)   cmd_check ;;
  install) cmd_install ;;
  storage) cmd_storage ;;
  upgrade) shift; cmd_upgrade "$@" ;;
  reset)   cmd_reset ;;
  *) die "unknown action: $ACTION (use: check | install | storage | upgrade <ver> | reset)";;
esac
