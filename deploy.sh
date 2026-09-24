#!/usr/bin/env bash
# =============================================================================
#  deploy.sh — orchestrate a whole cluster from ONE machine (Ansible-style).
#  Reads inventory.conf, SSHes to every node, and runs k8s.sh on each.
#
#    ./deploy.sh                 # ONE-SHOT: bootstrap + provision LB/NFS + build all
#    ./deploy.sh -i my.conf      # use a different inventory
#    ./deploy.sh check           # test SSH + sudo to every node
#    ./deploy.sh bootstrap       # only install SSH keys + passwordless sudo
#    ./deploy.sh provision       # only set up the LB and/or NFS server
#    ./deploy.sh add-worker w6 10.0.0.26 [pw]   # join ONE new worker later
#    ./deploy.sh remove-worker prod1-...-w6 [ip] # drain + remove a worker
#    ./deploy.sh storage         # (re)install storage (Longhorn or NFS) only
#    ./deploy.sh kubeconfig      # fetch admin kubeconfig to ./kubeconfig
#    ./deploy.sh upgrade 1.37.0  # rolling upgrade of the whole cluster
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
# Node lines are:  <name>  <ip>  [password]
# The optional 3rd column is used ONLY for the one-time SSH bootstrap (install
# key + passwordless sudo). Keep passwords in a private, git-ignored inventory.
declare -A SET; MASTERS=(); WORKERS=(); M_IP=(); W_IP=(); M_PW=(); W_PW=(); section=""
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
    name="$(awk '{print $1}' <<<"$line")"; ip="$(awk '{print $2}' <<<"$line")"; pw="$(awk '{print $3}' <<<"$line")"
    MASTERS+=("$name"); M_IP+=("$ip"); M_PW+=("$pw")
  elif [[ "$section" == workers ]]; then
    name="$(awk '{print $1}' <<<"$line")"; ip="$(awk '{print $2}' <<<"$line")"; pw="$(awk '{print $3}' <<<"$line")"
    WORKERS+=("$name"); W_IP+=("$ip"); W_PW+=("$pw")
  fi
done < "$INV"

[[ ${#MASTERS[@]} -ge 1 ]] || die "no [masters] defined in inventory"

SSH_USER="${SET[SSH_USER]:-root}"
SSH_PORT="${SET[SSH_PORT]:-22}"
SSH_KEY="${SET[SSH_KEY]:-}"; SSH_KEY="${SSH_KEY/#\~/$HOME}"
K8S_MINOR="${SET[K8S_MINOR]:-latest}"; K8S_PATCH="${SET[K8S_PATCH]:-}"
# Resolve K8S_MINOR=latest|auto|empty to the newest stable minor (once, here on
# the control machine) so every node installs the same version.
case "$K8S_MINOR" in
  latest|auto|"")
    S="$(curl -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null || true)"
    if [[ "$S" =~ ^v[0-9]+\.[0-9]+ ]]; then
      K8S_MINOR="$(echo "${S#v}" | cut -d. -f1,2)"; log "latest stable Kubernetes -> v${K8S_MINOR} (${S})"
    else
      warn "could not fetch latest version here; each node will auto-detect"; K8S_MINOR="latest"
    fi ;;
esac
CNI="${SET[CNI]:-flannel}"; POD_CIDR="${SET[POD_CIDR]:-10.244.0.0/16}"
CPE="${SET[CONTROL_PLANE_ENDPOINT]:-}"
MAX_PODS="${SET[MAX_PODS]:-110}"       # kubelet maxPods per node (<=250 with a /24 podCIDR)
INOTIFY_MAX_USER_INSTANCES="${SET[INOTIFY_MAX_USER_INSTANCES]:-8192}"
INOTIFY_MAX_USER_WATCHES="${SET[INOTIFY_MAX_USER_WATCHES]:-1048576}"

# ---- storage backend: longhorn | nfs | none --------------------------------
# Back-compat: honour a legacy LONGHORN=true/false if STORAGE is not set.
STORAGE="${SET[STORAGE]:-}"
if [[ -z "$STORAGE" ]]; then
  if [[ "${SET[LONGHORN]:-true}" == true ]]; then STORAGE=longhorn; else STORAGE=none; fi
fi
LONGHORN_VERSION="${SET[LONGHORN_VERSION]:-v1.10.0}"
NFS_SERVER="${SET[NFS_SERVER]:-}"; NFS_PATH="${SET[NFS_PATH]:-/srv/nfs/k8s}"
NFS_SC_NAME="${SET[NFS_SC_NAME]:-nfs-client}"
[[ "$STORAGE" == nfs && -z "$NFS_SERVER" ]] && die "STORAGE=nfs — set NFS_SERVER (NFS server IP) in inventory.conf"

# Fetch the admin kubeconfig to this machine at the end of install? (true|false)
FETCH_KUBECONFIG="${SET[FETCH_KUBECONFIG]:-true}"

# ---- optional auto-provisioning of the LB and NFS server (one-shot install) --
# LB_HOST: host to run HAProxy on (fronts the masters for HA). If set, deploy.sh
#          installs HAProxy there and uses LB_HOST:6443 as the endpoint.
# NFS_SETUP=true: deploy.sh sets up the NFS server on NFS_SERVER first.
# These hosts may use a different SSH user (e.g. a Debian proxy) — override with
# LB_SSH_USER / NFS_SSH_USER.
LB_HOST="${SET[LB_HOST]:-}";        LB_SSH_USER="${SET[LB_SSH_USER]:-$SSH_USER}"
NFS_SETUP="${SET[NFS_SETUP]:-false}"; NFS_SSH_USER="${SET[NFS_SSH_USER]:-$SSH_USER}"
NFS_CIDR="${SET[NFS_CIDR]:-}"
# Optional passwords for the infra hosts' one-time bootstrap (node passwords come
# from the 3rd inventory column). BOOTSTRAP=auto runs it only if any password is set.
LB_PASSWORD="${SET[LB_PASSWORD]:-}"; NFS_PASSWORD="${SET[NFS_PASSWORD]:-}"
BOOTSTRAP="${SET[BOOTSTRAP]:-auto}"    # auto | true | false

# HA auto-detect
if [[ ${#MASTERS[@]} -gt 1 ]]; then
  HA_MODE=multi
  # If no endpoint given but an LB host is, derive the endpoint from it.
  [[ -z "$CPE" && -n "$LB_HOST" ]] && CPE="${LB_HOST}:6443"
  [[ -n "$CPE" ]] || die "You listed ${#MASTERS[@]} masters (HA) — set CONTROL_PLANE_ENDPOINT, or set LB_HOST to auto-provision HAProxy, in inventory.conf"
else
  HA_MODE=single
fi

# NOTE: ssh takes the port as -p, but scp takes it as -P, so keep the port out
# of the shared options and pass it per-command (this bit us once already).
SSH_OPTS=( -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 )
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=( -i "$SSH_KEY" )
rsh(){ ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "${SSH_USER}@$1" "$2"; }
push(){ scp "${SSH_OPTS[@]}" -P "$SSH_PORT" "$HERE/k8s.sh" "${SSH_USER}@$1:/tmp/k8s.sh" >/dev/null; }
# generic variants that take an explicit user + file (for LB/NFS hosts)
rsh_as(){ ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$1@$2" "$3"; }
push_as(){ scp "${SSH_OPTS[@]}" -P "$SSH_PORT" "$3" "$1@$2:/tmp/$(basename "$3")" >/dev/null; }

# Provision the LB (HAProxy) and/or NFS server if the inventory asks for it.
provision_infra(){
  if [[ "$STORAGE" == nfs && "$NFS_SETUP" == true ]]; then
    [[ -f "$HERE/scripts/nfs-server-setup.sh" ]] || die "scripts/nfs-server-setup.sh not found"
    step "0/4  provisioning NFS server on $NFS_SERVER (user $NFS_SSH_USER)"
    push_as "$NFS_SSH_USER" "$NFS_SERVER" "$HERE/scripts/nfs-server-setup.sh"
    rsh_as "$NFS_SSH_USER" "$NFS_SERVER" "sudo NFS_PATH='$NFS_PATH' ${NFS_CIDR:+NFS_CIDR='$NFS_CIDR'} bash /tmp/nfs-server-setup.sh"
  fi
  if [[ "$HA_MODE" == multi && -n "$LB_HOST" ]]; then
    [[ -f "$HERE/scripts/lb-haproxy-setup.sh" ]] || die "scripts/lb-haproxy-setup.sh not found"
    step "0/4  provisioning HAProxy LB on $LB_HOST (user $LB_SSH_USER)"
    push_as "$LB_SSH_USER" "$LB_HOST" "$HERE/scripts/lb-haproxy-setup.sh"
    rsh_as "$LB_SSH_USER" "$LB_HOST" "sudo bash /tmp/lb-haproxy-setup.sh ${M_IP[*]}"
  fi
}

# ---- one-time SSH bootstrap (install key + passwordless sudo) ----------------
# Uses passwords (node 3rd column, or LB_PASSWORD/NFS_PASSWORD) via sshpass, or
# plink (PuTTY) as a fallback on Windows. After this, everything is key-based.
PUBKEY_FILE="${SSH_KEY:-$HOME/.ssh/id_rsa}.pub"
_PLINK=""; command -v plink >/dev/null 2>&1 && _PLINK="plink"; [[ -z "$_PLINK" && -x "/c/Program Files/PuTTY/plink.exe" ]] && _PLINK="/c/Program Files/PuTTY/plink.exe"

# bootstrap_host <user> <ip> <password>
bootstrap_host(){
  local u="$1" ip="$2" pw="$3"
  [[ -n "$pw" ]] || { warn "no password for $u@$ip — skipping (assuming key already works)"; return 0; }
  [[ -f "$PUBKEY_FILE" ]] || die "public key not found: $PUBKEY_FILE (generate one: ssh-keygen -t rsa -b 4096)"
  local pub; pub="$(cat "$PUBKEY_FILE")"
  local remote="mkdir -p ~/.ssh && chmod 700 ~/.ssh && (grep -qF '$pub' ~/.ssh/authorized_keys 2>/dev/null || echo '$pub' >> ~/.ssh/authorized_keys) && chmod 600 ~/.ssh/authorized_keys && echo '$pw' | sudo -S bash -c 'echo \"$u ALL=(ALL) NOPASSWD:ALL\" >/etc/sudoers.d/90-$u-nopasswd && chmod 440 /etc/sudoers.d/90-$u-nopasswd' && echo BOOTSTRAP_OK"
  if command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$SSH_PORT" "$u@$ip" "$remote" >/dev/null \
      && log "bootstrapped $u@$ip" || die "bootstrap failed for $u@$ip (check password/connectivity)"
  elif [[ -n "$_PLINK" ]]; then
    echo y | "$_PLINK" -ssh -pw "$pw" "$u@$ip" "exit" >/dev/null 2>&1 || true   # cache host key
    "$_PLINK" -ssh -batch -pw "$pw" "$u@$ip" "$remote" >/dev/null \
      && log "bootstrapped $u@$ip" || die "bootstrap failed for $u@$ip (check password/connectivity)"
  else
    die "need 'sshpass' (Linux/mac/WSL) or PuTTY 'plink' (Windows) to bootstrap with passwords; or run ssh-copy-id manually and remove the password column"
  fi
}

bootstrap_all(){
  step "0/4  bootstrapping SSH keys + passwordless sudo"
  local i
  for i in "${!MASTERS[@]}"; do bootstrap_host "$SSH_USER" "${M_IP[$i]}" "${M_PW[$i]}"; done
  for i in "${!WORKERS[@]}"; do bootstrap_host "$SSH_USER" "${W_IP[$i]}" "${W_PW[$i]}"; done
  [[ "$STORAGE" == nfs && "$NFS_SETUP" == true && -n "$NFS_PASSWORD" ]] && bootstrap_host "$NFS_SSH_USER" "$NFS_SERVER" "$NFS_PASSWORD"
  [[ "$HA_MODE" == multi && -n "$LB_HOST" && -n "$LB_PASSWORD" ]] && bootstrap_host "$LB_SSH_USER" "$LB_HOST" "$LB_PASSWORD"
}

# Should the auto-bootstrap run? true, or auto + at least one password present.
want_bootstrap(){
  [[ "$BOOTSTRAP" == false ]] && return 1
  [[ "$BOOTSTRAP" == true ]] && return 0
  local p; for p in "${M_PW[@]}" "${W_PW[@]}" "$LB_PASSWORD" "$NFS_PASSWORD"; do [[ -n "$p" ]] && return 0; done
  return 1
}

# common env prefix passed into k8s.sh on the remote node
envstr(){
  echo "K8S_MINOR='$K8S_MINOR' K8S_PATCH='$K8S_PATCH' CNI='$CNI' HA_MODE='$HA_MODE' POD_CIDR='$POD_CIDR' CONTROL_PLANE_ENDPOINT='$CPE' MAX_PODS='$MAX_PODS' INOTIFY_MAX_USER_INSTANCES='$INOTIFY_MAX_USER_INSTANCES' INOTIFY_MAX_USER_WATCHES='$INOTIFY_MAX_USER_WATCHES'"
}

# env prefix for the storage step (Longhorn or NFS provisioner)
storage_envstr(){
  echo "STORAGE='$STORAGE' LONGHORN_VERSION='$LONGHORN_VERSION' NFS_SERVER='$NFS_SERVER' NFS_PATH='$NFS_PATH' NFS_SC_NAME='$NFS_SC_NAME'"
}

print_plan(){
  echo -e "${b}Cluster plan${n} (inventory: $INV)"
  echo "  mode      : $HA_MODE  (${#MASTERS[@]} master(s), ${#WORKERS[@]} worker(s))"
  echo "  k8s       : v${K8S_MINOR} ${K8S_PATCH:+patch $K8S_PATCH}"
  if [[ "$STORAGE" == nfs ]]; then
    echo "  cni       : $CNI    storage: nfs (server=$NFS_SERVER path=$NFS_PATH sc=$NFS_SC_NAME)"
  else
    echo "  cni       : $CNI    storage: $STORAGE"
  fi
  [[ $HA_MODE == multi ]] && echo "  endpoint  : $CPE${LB_HOST:+  (HAProxy auto-provision on $LB_HOST)}"
  [[ "$STORAGE" == nfs && "$NFS_SETUP" == true ]] && echo "  nfs-setup : yes (auto-provision on $NFS_SERVER)"
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

  want_bootstrap && bootstrap_all
  provision_infra

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
    step "3a/4  joining extra masters"
    for i in $(seq 1 $((${#MASTERS[@]}-1))); do
      log "join master ${MASTERS[$i]} (${M_IP[$i]})"; push "${M_IP[$i]}"
      rsh "${M_IP[$i]}" "sudo $(envstr) JOIN='$MJOIN' bash /tmp/k8s.sh join"
    done
  fi

  step "3b/4  joining workers"
  for i in "${!WORKERS[@]}"; do
    log "join worker ${WORKERS[$i]} (${W_IP[$i]})"; push "${W_IP[$i]}"
    rsh "${W_IP[$i]}" "sudo $(envstr) JOIN='$WJOIN' bash /tmp/k8s.sh join"
  done

  if [[ "$STORAGE" != none ]]; then
    step "4/4  installing storage: $STORAGE (via $M0)"
    rsh "$M0" "sudo $(storage_envstr) bash /tmp/k8s.sh storage" || warn "storage step reported issues"
  fi

  step "DONE"; rsh "$M0" "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide" || true
  if [[ "$FETCH_KUBECONFIG" == true ]]; then
    fetch_kubeconfig
  else
    log "FETCH_KUBECONFIG=false — skipping. Get it later with: ./deploy.sh kubeconfig"
  fi
}

# Pull admin.conf from the primary master to THIS machine so kubectl works
# locally right away. The server field already points at the right address
# (the control-plane endpoint for HA, or the master's IP for single-master).
fetch_kubeconfig(){
  local M0="${M_IP[0]}" out="$HERE/kubeconfig"
  step "fetching kubeconfig -> $out"
  if rsh "$M0" "sudo cat /etc/kubernetes/admin.conf" >"$out.tmp" 2>/dev/null && [[ -s "$out.tmp" ]]; then
    mv -f "$out.tmp" "$out"; chmod 600 "$out"
    log "kubeconfig saved: $out"
    log "use it with:   export KUBECONFIG=\"$out\"   &&   kubectl get nodes"
    command -v kubectl >/dev/null && { log "quick check:"; KUBECONFIG="$out" kubectl get nodes 2>/dev/null || warn "kubectl couldn't reach the API from here (check routing/firewall to the endpoint)"; }
  else
    rm -f "$out.tmp"; warn "could not fetch kubeconfig automatically; on the master it is at /etc/kubernetes/admin.conf"
  fi
}

cmd_storage(){ push "${M_IP[0]}"; rsh "${M_IP[0]}" "sudo $(storage_envstr) bash /tmp/k8s.sh storage"; }

# Add a single worker to an existing cluster (does NOT touch existing nodes).
#   ./deploy.sh add-worker <name> <ip> [password]
cmd_add_worker(){
  local name="${1:?usage: deploy.sh add-worker <name> <ip> [password]}"
  local ip="${2:?usage: deploy.sh add-worker <name> <ip> [password]}"
  local pw="${3:-}"
  local M0="${M_IP[0]}"
  [[ -n "$pw" ]] && bootstrap_host "$SSH_USER" "$ip" "$pw"
  step "adding worker $name ($ip)"
  push "$M0"
  local WJOIN; WJOIN="$(rsh "$M0" "sudo bash /tmp/k8s.sh token" | sed -n 's/^JOIN=//p' | tr -d '\"')"
  [[ -n "$WJOIN" ]] || die "could not get a join token from $M0"
  push "$ip"
  rsh "$ip" "sudo $(envstr) JOIN='$WJOIN' bash /tmp/k8s.sh join"
  log "worker $name joined. Verify from a master:  kubectl get nodes -o wide"
}

# Remove a worker from the cluster: drain -> delete -> (optional) reset the node.
#   ./deploy.sh remove-worker <node-name> [ip]
# <node-name> is the Kubernetes node name (from 'kubectl get nodes', i.e. the
# host's hostname). Pass [ip] to also run 'kubeadm reset' on the node itself.
cmd_remove_worker(){
  local node="${1:?usage: deploy.sh remove-worker <node-name> [ip]}"
  local ip="${2:-}"
  local M0="${M_IP[0]}"
  step "removing worker $node"
  warn "This evicts all workloads from $node and removes it from the cluster."
  read -rp "Type the node name '$node' to confirm: " a; [[ "$a" == "$node" ]] || die "aborted"
  local K="sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl"
  rsh "$M0" "$K cordon $node" || true
  rsh "$M0" "$K drain $node --ignore-daemonsets --delete-emptydir-data --force --timeout=120s" || warn "drain reported issues (continuing)"
  rsh "$M0" "$K delete node $node" || die "failed to delete node $node from the cluster"
  if [[ -n "$ip" ]]; then
    log "resetting kubeadm on $ip"
    rsh "$ip" "sudo kubeadm reset -f; sudo rm -rf /etc/cni/net.d ~/.kube" || warn "reset on $ip reported issues"
  else
    warn "node deleted from cluster. To clean the machine itself: ssh to it and run 'sudo kubeadm reset -f'"
  fi
  log "worker $node removed. Verify:  kubectl get nodes"
}

cmd_upgrade(){
  local T="${1:?usage: deploy.sh upgrade <version e.g 1.37.0>}"
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
  check)      cmd_check ;;
  install)    cmd_install ;;
  bootstrap)  print_plan; bootstrap_all ;;
  provision)  print_plan; provision_infra ;;
  add-worker)    shift; cmd_add_worker "$@" ;;
  remove-worker) shift; cmd_remove_worker "$@" ;;
  storage)    cmd_storage ;;
  kubeconfig) fetch_kubeconfig ;;
  upgrade)    shift; cmd_upgrade "$@" ;;
  reset)      cmd_reset ;;
  *) die "unknown action: $ACTION (use: check | bootstrap | install | provision | add-worker <name> <ip> [pw] | remove-worker <node> [ip] | storage | kubeconfig | upgrade <ver> | reset)";;
esac
