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
#    ./deploy.sh knative         # install Knative (Serving/Eventing) on Istio
#    ./deploy.sh argocd          # install Argo CD (GitOps)
#    ./deploy.sh openbao         # install OpenBao (HA Raft secret manager)
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
NFS_ARCHIVE_ON_DELETE="${SET[NFS_ARCHIVE_ON_DELETE]:-true}"   # keep data on accidental PVC delete
NFS_ARCHIVE_RETENTION="${SET[NFS_ARCHIVE_RETENTION]:-3}"      # keep last N archived copies per PVC (0=all)
NFS_ARCHIVE_PRUNE_SCHEDULE="${SET[NFS_ARCHIVE_PRUNE_SCHEDULE]:-0 2 * * *}"
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

# ---- Autoscaling prerequisites ---------------------------------------------
METRICS_SERVER="${SET[METRICS_SERVER]:-true}"    # HPA + kubectl top (default on)
METRICS_SERVER_VERSION="${SET[METRICS_SERVER_VERSION]:-latest}"
VPA="${SET[VPA]:-true}"                           # Vertical Pod Autoscaler (default on)
VPA_VERSION="${SET[VPA_VERSION]:-1.8.0}"

# ---- Monitoring: Prometheus (no Grafana) -----------------------------------
PROMETHEUS="${SET[PROMETHEUS]:-true}"
PROMETHEUS_RETENTION="${SET[PROMETHEUS_RETENTION]:-7d}"
PROMETHEUS_STORAGE_CLASS="${SET[PROMETHEUS_STORAGE_CLASS]:-}"
BACKUP_ALERTS="${SET[BACKUP_ALERTS]:-true}"      # Prometheus alerts if backups stop

# ---- Backups to S3 (need S3 creds; keep those in a private *.local.conf) ----
VELERO="${SET[VELERO]:-false}"                 # Velero -> S3 (cluster + PV data)
NFS_S3_SYNC="${SET[NFS_S3_SYNC]:-false}"       # raw NFS export -> S3 CronJob
VELERO_BUCKET="${SET[VELERO_BUCKET]:-}"
VELERO_PREFIX="${SET[VELERO_PREFIX]:-velero}"                   # Velero's own bucket prefix (must not share root with restic)
VELERO_KEEP="${SET[VELERO_KEEP]:-4}"                            # always keep newest 4 (count)
VELERO_TTL="${SET[VELERO_TTL]:-720h0m0s}"                       # 30d backstop only
VELERO_EXCLUDE_NAMESPACES="${SET[VELERO_EXCLUDE_NAMESPACES]:-monitoring}"
NFS_S3_BUCKET="${SET[NFS_S3_BUCKET]:-}"; NFS_S3_PREFIX="${SET[NFS_S3_PREFIX]:-nfs-restic}"
NFS_S3_STORAGE_CLASS="${SET[NFS_S3_STORAGE_CLASS]:-STANDARD}"
NFS_S3_KEEP="${SET[NFS_S3_KEEP]:-4}"                            # always keep newest 4 daily snapshots
AWS_REGION="${SET[AWS_REGION]:-}"
AWS_ACCESS_KEY_ID="${SET[AWS_ACCESS_KEY_ID]:-}"; AWS_SECRET_ACCESS_KEY="${SET[AWS_SECRET_ACCESS_KEY]:-}"
# Automated OpenBao raft snapshot -> S3 (no passphrase needed; on by default when
# OpenBao + S3 are configured). And the encrypted DR key-bundle (needs a passphrase).
OPENBAO_SNAPSHOT="${SET[OPENBAO_SNAPSHOT]:-true}"
BAO_SNAP_SCHEDULE="${SET[BAO_SNAP_SCHEDULE]:-0 2 * * *}"; BAO_SNAP_KEEP="${SET[BAO_SNAP_KEEP]:-4}"
DR_BUNDLE="${SET[DR_BUNDLE]:-true}"            # store the DR key bundle in S3 (easy mode: plain, nothing to remember)
DR_ENCRYPT="${SET[DR_ENCRYPT]:-false}"         # advanced: true = passphrase-encrypt the bundle (you keep the passphrase)
DR_PASSPHRASE="${DR_PASSPHRASE:-}"             # env only (never inventory); prompted if DR_ENCRYPT and empty

# ---- Knative + Istio (optional) --------------------------------------------
KNATIVE="${SET[KNATIVE]:-true}"                  # installed by default; set false to skip
KNATIVE_EVENTING="${SET[KNATIVE_EVENTING]:-true}"
ISTIO_VERSION="${SET[ISTIO_VERSION]:-1.31.1}"
KNATIVE_VERSION="${SET[KNATIVE_VERSION]:-knative-v1.23.0}"
KNATIVE_INGRESS_TYPE="${SET[KNATIVE_INGRESS_TYPE]:-NodePort}"
KNATIVE_DOMAIN_IP="${SET[KNATIVE_DOMAIN_IP]:-${M_IP[0]}}"

# ---- Argo CD (optional) ----------------------------------------------------
ARGOCD="${SET[ARGOCD]:-true}"                    # installed by default; set false to skip
ARGOCD_VERSION="${SET[ARGOCD_VERSION]:-v3.5.3}"
ARGOCD_INGRESS_TYPE="${SET[ARGOCD_INGRESS_TYPE]:-NodePort}"

# ---- OpenBao secret manager (optional) -------------------------------------
OPENBAO="${SET[OPENBAO]:-true}"                  # installed by default; set false to skip
OPENBAO_REPLICAS="${SET[OPENBAO_REPLICAS]:-3}"
OPENBAO_INGRESS_TYPE="${SET[OPENBAO_INGRESS_TYPE]:-ClusterIP}"
OPENBAO_STORAGE_CLASS="${SET[OPENBAO_STORAGE_CLASS]:-}"

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
  echo "STORAGE='$STORAGE' LONGHORN_VERSION='$LONGHORN_VERSION' NFS_SERVER='$NFS_SERVER' NFS_PATH='$NFS_PATH' NFS_SC_NAME='$NFS_SC_NAME' NFS_ARCHIVE_ON_DELETE='$NFS_ARCHIVE_ON_DELETE' NFS_ARCHIVE_RETENTION='$NFS_ARCHIVE_RETENTION' NFS_ARCHIVE_PRUNE_SCHEDULE='$NFS_ARCHIVE_PRUNE_SCHEDULE'"
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
  [[ "$METRICS_SERVER" == true ]] && cmd_metrics
  [[ "$VPA" == true ]] && cmd_vpa
  [[ "$PROMETHEUS" == true ]] && cmd_prometheus
  [[ "$KNATIVE" == true ]] && cmd_knative
  [[ "$ARGOCD" == true ]] && cmd_argocd
  [[ "$OPENBAO" == true ]] && cmd_openbao
  [[ "$VELERO" == true ]] && cmd_velero
  [[ "$NFS_S3_SYNC" == true ]] && cmd_nfs_s3
  [[ "$BACKUP_ALERTS" == true && "$PROMETHEUS" == true ]] && cmd_backup_alerts
  # DR protection: auto OpenBao snapshot + accept-to-store encrypted key bundle.
  cmd_dr_protect

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

knative_envstr(){
  echo "ISTIO_VERSION='$ISTIO_VERSION' KNATIVE_VERSION='$KNATIVE_VERSION' KNATIVE_EVENTING='$KNATIVE_EVENTING' KNATIVE_INGRESS_TYPE='$KNATIVE_INGRESS_TYPE' KNATIVE_DOMAIN_IP='$KNATIVE_DOMAIN_IP'"
}

# Install metrics-server (HPA + kubectl top), via the first master.
cmd_metrics(){
  [[ -f "$HERE/scripts/09-metrics-server.sh" ]] || die "scripts/09-metrics-server.sh not found"
  local M0="${M_IP[0]}"; step "installing metrics-server (via $M0)"
  push_as "$SSH_USER" "$M0" "$HERE/scripts/09-metrics-server.sh"
  rsh "$M0" "sudo METRICS_SERVER_VERSION='$METRICS_SERVER_VERSION' bash /tmp/09-metrics-server.sh"
}

# Install Prometheus (no Grafana), via the first master.
cmd_prometheus(){
  [[ -f "$HERE/scripts/11-prometheus.sh" ]] || die "scripts/11-prometheus.sh not found"
  local M0="${M_IP[0]}"; step "installing Prometheus (via $M0)"
  push_as "$SSH_USER" "$M0" "$HERE/scripts/11-prometheus.sh"
  rsh "$M0" "sudo PROMETHEUS_RETENTION='$PROMETHEUS_RETENTION' PROMETHEUS_STORAGE_CLASS='$PROMETHEUS_STORAGE_CLASS' bash /tmp/11-prometheus.sh"
}

# Install the Vertical Pod Autoscaler, via the first master.
cmd_vpa(){
  [[ -f "$HERE/scripts/10-vpa.sh" ]] || die "scripts/10-vpa.sh not found"
  local M0="${M_IP[0]}"; step "installing VPA (via $M0)"
  push_as "$SSH_USER" "$M0" "$HERE/scripts/10-vpa.sh"
  rsh "$M0" "sudo VPA_VERSION='$VPA_VERSION' bash /tmp/10-vpa.sh"
}

# Install Velero (backup to S3), via the first master.
cmd_velero(){
  [[ -f "$HERE/scripts/12-velero.sh" ]] || die "scripts/12-velero.sh not found"
  [[ -n "$VELERO_BUCKET" && -n "$AWS_REGION" && -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]] \
    || die "Velero needs VELERO_BUCKET, AWS_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (put them in a private *.local.conf)"
  local M0="${M_IP[0]}"; step "installing Velero (via $M0)"
  push_as "$SSH_USER" "$M0" "$HERE/scripts/12-velero.sh"
  rsh "$M0" "sudo VELERO_BUCKET='$VELERO_BUCKET' VELERO_PREFIX='$VELERO_PREFIX' AWS_REGION='$AWS_REGION' AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID' AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY' VELERO_KEEP='$VELERO_KEEP' VELERO_TTL='$VELERO_TTL' VELERO_EXCLUDE_NAMESPACES='$VELERO_EXCLUDE_NAMESPACES' bash /tmp/12-velero.sh"
}

# Install the raw NFS-export -> S3 sync CronJob, via the first master.
cmd_nfs_s3(){
  [[ -f "$HERE/scripts/13-nfs-s3-sync.sh" ]] || die "scripts/13-nfs-s3-sync.sh not found"
  [[ -n "$NFS_S3_BUCKET" && -n "$AWS_REGION" && -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" && -n "$NFS_SERVER" ]] \
    || die "NFS->S3 needs NFS_S3_BUCKET, AWS_REGION, AWS creds, and NFS_SERVER"
  local M0="${M_IP[0]}"; step "installing NFS->S3 sync (via $M0)"
  push_as "$SSH_USER" "$M0" "$HERE/scripts/13-nfs-s3-sync.sh"
  rsh "$M0" "sudo NFS_S3_BUCKET='$NFS_S3_BUCKET' NFS_S3_PREFIX='$NFS_S3_PREFIX' NFS_S3_STORAGE_CLASS='$NFS_S3_STORAGE_CLASS' NFS_S3_KEEP='$NFS_S3_KEEP' AWS_REGION='$AWS_REGION' AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID' AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY' NFS_SERVER='$NFS_SERVER' NFS_PATH='$NFS_PATH' bash /tmp/13-nfs-s3-sync.sh"
}

# Install the automated OpenBao raft-snapshot -> S3 CronJob (no passphrase needed).
cmd_openbao_snapshot(){
  [[ -f "$HERE/scripts/16-openbao-snapshot.sh" ]] || die "scripts/16-openbao-snapshot.sh not found"
  local bucket="${VELERO_BUCKET:-$NFS_S3_BUCKET}"
  [[ -n "$bucket" && -n "$AWS_REGION" && -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]] \
    || die "OpenBao snapshot needs a bucket (VELERO_BUCKET/NFS_S3_BUCKET), AWS_REGION and AWS creds"
  local M0="${M_IP[0]}"; step "installing automated OpenBao snapshot -> s3://$bucket/openbao (via $M0)"
  push_as "$SSH_USER" "$M0" "$HERE/scripts/16-openbao-snapshot.sh"
  rsh "$M0" "sudo BAO_SNAP_BUCKET='$bucket' BAO_SNAP_PREFIX='openbao' BAO_SNAP_SCHEDULE='$BAO_SNAP_SCHEDULE' BAO_SNAP_KEEP='$BAO_SNAP_KEEP' AWS_REGION='$AWS_REGION' AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID' AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY' bash /tmp/16-openbao-snapshot.sh"
}

# DR-protection run at the end of install. Sets up the automated OpenBao snapshot
# (no passphrase) and — by default (easy mode) — stores the DR key bundle in S3 so
# recovery needs nothing but an AWS login. With DR_ENCRYPT=true it becomes the
# advanced, passphrase-encrypted bundle (asks you to accept + own a passphrase).
# Skipped automatically if S3 isn't configured.
cmd_dr_protect(){
  local bucket="${VELERO_BUCKET:-$NFS_S3_BUCKET}"
  [[ -n "$bucket" && -n "$AWS_REGION" && -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]] || {
    warn "S3 not configured — skipping DR protection (run './deploy.sh openbao-snapshot' and './deploy.sh dr-bundle' later)"; return 0; }
  # 1. OpenBao snapshot: automatic, no passphrase.
  if [[ "$OPENBAO" == true && "$OPENBAO_SNAPSHOT" == true ]]; then cmd_openbao_snapshot || warn "openbao snapshot setup had issues"; fi
  # 2. DR key bundle.
  [[ "$DR_BUNDLE" == true ]] || { log "DR key bundle disabled. Store it any time: ./deploy.sh -i <inv> dr-bundle"; return 0; }
  if [[ "$DR_ENCRYPT" == true ]]; then
    echo; step "DR key bundle (encrypted)"
    cat <<EOF
Stores your recovery KEYS in S3, encrypted with a passphrase you choose.
At recovery you need TWO things kept OFF the cluster:
  1) your AWS login    2) THIS passphrase (store it in a password manager)
If you lose the passphrase, this bundle cannot be recovered.
EOF
    local ans=""
    if [[ -n "$DR_PASSPHRASE" ]]; then ans=y; else read -rp "Create the encrypted DR bundle now? [Y/n] " ans; ans="${ans:-y}"; fi
    [[ "$ans" =~ ^[Yy]$ ]] && cmd_dr_bundle || warn "skipped. Later:  DR_ENCRYPT=true ./deploy.sh -i <inv> dr-bundle"
  else
    # Easy mode: store the bundle in S3 automatically, nothing to remember.
    step "DR key bundle (easy mode — stored in S3, recovery needs only your AWS login)"
    cmd_dr_bundle
  fi
}

# Build + upload the DR "break-glass" bundle (keys + inventory + runbook) to S3.
# Easy mode (default): plain, protected by the bucket's encryption + private access
# (recovery needs only the AWS login). DR_ENCRYPT=true: passphrase-encrypted.
cmd_dr_bundle(){
  [[ -f "$HERE/scripts/15-dr-bundle.sh" ]] || die "scripts/15-dr-bundle.sh not found"
  local bucket="${VELERO_BUCKET:-$NFS_S3_BUCKET}"
  [[ -n "$bucket" && -n "$AWS_REGION" && -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]] \
    || die "DR bundle needs a bucket (VELERO_BUCKET/NFS_S3_BUCKET), AWS_REGION and AWS creds (put them in a private *.local.conf)"
  local pp="${DR_PASSPHRASE:-}"
  if [[ "$DR_ENCRYPT" == true && -z "$pp" ]]; then
    read -rsp "DR bundle passphrase (keep this OFF-cluster; you need it to recover): " pp; echo
    local pp2; read -rsp "Confirm passphrase: " pp2; echo
    [[ "$pp" == "$pp2" ]] || die "passphrases did not match"
    [[ -n "$pp" ]] || die "empty passphrase"
  fi
  local M0="${M_IP[0]}"; step "building DR bundle (encrypt=$DR_ENCRYPT) -> s3://$bucket/dr-bundle (via $M0)"
  push_as "$SSH_USER" "$M0" "$HERE/scripts/15-dr-bundle.sh"
  push_as "$SSH_USER" "$M0" "$INV"
  [[ -f "$HERE/docs/DISASTER-RECOVERY.md" ]] && push_as "$SSH_USER" "$M0" "$HERE/docs/DISASTER-RECOVERY.md"
  rsh "$M0" "sudo DR_BUCKET='$bucket' DR_PREFIX='dr-bundle' DR_ENCRYPT='$DR_ENCRYPT' VELERO_PREFIX='$VELERO_PREFIX' NFS_S3_PREFIX='$NFS_S3_PREFIX' AWS_REGION='$AWS_REGION' AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID' AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY' DR_PASSPHRASE='$pp' INVENTORY_FILE='/tmp/$(basename "$INV")' RUNBOOK_FILE='/tmp/DISASTER-RECOVERY.md' bash /tmp/15-dr-bundle.sh"
  # clean the staged (plaintext) inventory/runbook off the master
  rsh "$M0" "rm -f /tmp/$(basename "$INV") /tmp/DISASTER-RECOVERY.md /tmp/15-dr-bundle.sh" 2>/dev/null || true
}

# List Velero backups available for restore (from S3).
cmd_backups(){ rsh "${M_IP[0]}" "sudo KUBECONFIG=/etc/kubernetes/admin.conf velero backup get"; }

# Easy restore:  ./deploy.sh restore <backup-name> [namespace]
cmd_restore(){
  local b="${1:?usage: deploy.sh restore <backup-name> [namespace]}"; local ns="${2:-}"
  local inc=""; [[ -n "$ns" ]] && inc="--include-namespaces $ns"
  local rn="restore-${b}-$(date +%s)"
  step "restoring from backup '$b'${ns:+ (namespace $ns)}"
  rsh "${M_IP[0]}" "sudo KUBECONFIG=/etc/kubernetes/admin.conf velero restore create $rn --from-backup $b $inc --wait"
  rsh "${M_IP[0]}" "sudo KUBECONFIG=/etc/kubernetes/admin.conf velero restore describe $rn" || true
}

# Install backup alerting (Prometheus rules + Velero ServiceMonitor).
cmd_backup_alerts(){
  [[ -f "$HERE/scripts/14-backup-alerts.sh" ]] || die "scripts/14-backup-alerts.sh not found"
  local M0="${M_IP[0]}"; step "installing backup alerts (via $M0)"
  push_as "$SSH_USER" "$M0" "$HERE/scripts/14-backup-alerts.sh"
  rsh "$M0" "sudo bash /tmp/14-backup-alerts.sh"
}

# Install Knative (Serving + optional Eventing) on Istio, via the first master.
cmd_knative(){
  [[ -f "$HERE/scripts/06-knative-istio.sh" ]] || die "scripts/06-knative-istio.sh not found"
  local M0="${M_IP[0]}"
  step "installing Knative + Istio (via $M0)"
  push_as "$SSH_USER" "$M0" "$HERE/scripts/06-knative-istio.sh"
  rsh "$M0" "sudo $(knative_envstr) bash /tmp/06-knative-istio.sh"
}

# Install Argo CD (GitOps CD), via the first master.
cmd_argocd(){
  [[ -f "$HERE/scripts/07-argocd.sh" ]] || die "scripts/07-argocd.sh not found"
  local M0="${M_IP[0]}"
  step "installing Argo CD (via $M0)"
  push_as "$SSH_USER" "$M0" "$HERE/scripts/07-argocd.sh"
  rsh "$M0" "sudo ARGOCD_VERSION='$ARGOCD_VERSION' ARGOCD_INGRESS_TYPE='$ARGOCD_INGRESS_TYPE' bash /tmp/07-argocd.sh"
}

# Install OpenBao (HA Raft secret manager), via the first master.
cmd_openbao(){
  [[ -f "$HERE/scripts/08-openbao.sh" ]] || die "scripts/08-openbao.sh not found"
  local M0="${M_IP[0]}"
  step "installing OpenBao (via $M0)"
  push_as "$SSH_USER" "$M0" "$HERE/scripts/08-openbao.sh"
  rsh "$M0" "sudo OPENBAO_REPLICAS='$OPENBAO_REPLICAS' OPENBAO_INGRESS_TYPE='$OPENBAO_INGRESS_TYPE' OPENBAO_STORAGE_CLASS='$OPENBAO_STORAGE_CLASS' bash /tmp/08-openbao.sh"
}

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
  metrics)    cmd_metrics ;;
  vpa)        cmd_vpa ;;
  prometheus) cmd_prometheus ;;
  knative)    cmd_knative ;;
  argocd)     cmd_argocd ;;
  openbao)    cmd_openbao ;;
  velero)     cmd_velero ;;
  nfs-s3-sync) cmd_nfs_s3 ;;
  backup-alerts) cmd_backup_alerts ;;
  dr-bundle)  cmd_dr_bundle ;;
  openbao-snapshot) cmd_openbao_snapshot ;;
  dr-protect) cmd_dr_protect ;;
  backups)    cmd_backups ;;
  restore)    shift; cmd_restore "$@" ;;
  kubeconfig) fetch_kubeconfig ;;
  upgrade)    shift; cmd_upgrade "$@" ;;
  reset)      cmd_reset ;;
  *) die "unknown action: $ACTION (use: check | bootstrap | install | provision | add-worker <name> <ip> [pw] | remove-worker <node> [ip] | storage | metrics | vpa | prometheus | knative | argocd | openbao | velero | nfs-s3-sync | backup-alerts | dr-bundle | openbao-snapshot | dr-protect | backups | restore <backup> [ns] | kubeconfig | upgrade <ver> | reset)";;
esac
