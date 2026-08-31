#!/usr/bin/env bash
# =============================================================================
#  k8s.sh — one-file Kubernetes installer (kubeadm + containerd)
#
#  USAGE (host this file publicly, then):
#
#   Install control plane (first master):
#     curl -sfL https://YOUR_HOST/k8s.sh | sudo bash -s -- init
#
#   Join a worker  (grab JOIN cmd from master's output / `k8s.sh token`):
#     curl -sfL https://YOUR_HOST/k8s.sh | sudo bash -s -- join
#
#   Install Longhorn storage (run on a master):
#     curl -sfL https://YOUR_HOST/k8s.sh | sudo bash -s -- storage
#
#   Upgrade (one minor at a time, control plane first):
#     curl -sfL https://YOUR_HOST/k8s.sh | sudo bash -s -- upgrade 1.31.2 first-master
#
#  CONFIG = environment variables (all optional, sane defaults):
#     K8S_MINOR=1.31 K8S_PATCH= CNI=flannel HA_MODE=single \
#     POD_CIDR=10.244.0.0/16 CONTROL_PLANE_ENDPOINT= LONGHORN_VERSION=v1.7.2 \
#     curl -sfL https://YOUR_HOST/k8s.sh | sudo bash -s -- init
# =============================================================================
set -euo pipefail

# ---------- defaults (override with env vars) --------------------------------
K8S_MINOR="${K8S_MINOR:-1.31}"
K8S_PATCH="${K8S_PATCH:-}"
CNI="${CNI:-flannel}"                       # flannel | calico
HA_MODE="${HA_MODE:-single}"                # single | multi
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-}"
APISERVER_ADVERTISE_ADDRESS="${APISERVER_ADVERTISE_ADDRESS:-}"
LONGHORN_VERSION="${LONGHORN_VERSION:-v1.7.2}"
LONGHORN_SET_DEFAULT_SC="${LONGHORN_SET_DEFAULT_SC:-true}"
JOIN="${JOIN:-}"                            # full join command (for `join`)

# ---------- helpers ----------------------------------------------------------
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }
warn(){ echo -e "${y}[!]${n} $*"; }
die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "run as root (use sudo)"; }
pm(){ command -v apt-get >/dev/null && echo apt || { command -v dnf >/dev/null && echo dnf || die "need apt or dnf"; }; }
ver(){ [[ -n "$K8S_PATCH" ]] && echo "${K8S_PATCH}-1.1" || echo ""; }
myip(){ [[ -n "$APISERVER_ADVERTISE_ADDRESS" ]] && echo "$APISERVER_ADVERTISE_ADDRESS" || ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'; }

# ---------- node prep (shared by init & join) --------------------------------
prep(){
  local P; P="$(pm)"
  log "prep: swap off, kernel modules, sysctl"
  swapoff -a; sed -i.bak '/\bswap\b/ s/^/#/' /etc/fstab || true
  printf 'overlay\nbr_netfilter\n' >/etc/modules-load.d/k8s.conf
  modprobe overlay; modprobe br_netfilter
  cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system >/dev/null

  log "installing containerd"
  if [[ "$P" == apt ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg apt-transport-https
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo "$VERSION_CODENAME") stable" >/etc/apt/sources.list.d/docker.list
    apt-get update -qq; apt-get install -y -qq containerd.io
  else
    dnf install -y -q dnf-plugins-core curl
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf install -y -q containerd.io
  fi
  mkdir -p /etc/containerd
  containerd config default >/etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl restart containerd; systemctl enable containerd >/dev/null

  log "installing kubeadm/kubelet/kubectl v${K8S_MINOR} (${K8S_PATCH:-latest})"
  local V; V="$(ver)"
  if [[ "$P" == apt ]]; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" >/etc/apt/sources.list.d/kubernetes.list
    apt-get update -qq
    if [[ -n "$V" ]]; then apt-get install -y -qq kubelet="$V" kubeadm="$V" kubectl="$V"; else apt-get install -y -qq kubelet kubeadm kubectl; fi
    apt-mark hold kubelet kubeadm kubectl >/dev/null
    apt-get install -y -qq open-iscsi nfs-common
  else
    cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
    if [[ -n "$V" ]]; then dnf install -y -q --disableexcludes=kubernetes kubelet-"$V" kubeadm-"$V" kubectl-"$V"; else dnf install -y -q --disableexcludes=kubernetes kubelet kubeadm kubectl; fi
    dnf install -y -q iscsi-initiator-utils nfs-utils
  fi
  systemctl enable kubelet >/dev/null
  systemctl enable --now iscsid >/dev/null 2>&1 || true
}

# ---------- init first control plane -----------------------------------------
cmd_init(){
  need_root; prep
  local IP; IP="$(myip)"; [[ -n "$IP" ]] || die "no IP; set APISERVER_ADVERTISE_ADDRESS"
  local args=( --pod-network-cidr="$POD_CIDR" --service-cidr="$SERVICE_CIDR" --apiserver-advertise-address="$IP" )
  [[ -n "$K8S_PATCH" ]] && args+=( --kubernetes-version="v${K8S_PATCH}" )
  if [[ "$HA_MODE" == multi ]]; then
    [[ -n "$CONTROL_PLANE_ENDPOINT" ]] || die "HA_MODE=multi needs CONTROL_PLANE_ENDPOINT (VIP/LB)"
    args+=( --control-plane-endpoint="$CONTROL_PLANE_ENDPOINT" --upload-certs )
  elif [[ -n "$CONTROL_PLANE_ENDPOINT" ]]; then
    args+=( --control-plane-endpoint="$CONTROL_PLANE_ENDPOINT" )
  fi
  log "kubeadm init on $IP (HA_MODE=$HA_MODE)"
  kubeadm init "${args[@]}"

  export KUBECONFIG=/etc/kubernetes/admin.conf
  mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    h="$(getent passwd "$SUDO_USER" | cut -d: -f6)"; mkdir -p "$h/.kube"
    cp -f /etc/kubernetes/admin.conf "$h/.kube/config"; chown -R "$SUDO_USER":"$SUDO_USER" "$h/.kube"
  fi

  log "installing CNI: $CNI"
  case "$CNI" in
    flannel) kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml ;;
    calico)  kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/tigera-operator.yaml
             curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/custom-resources.yaml | sed "s#192.168.0.0/16#${POD_CIDR}#" | kubectl apply -f - ;;
    *) die "unknown CNI: $CNI" ;;
  esac

  echo; log "================= CLUSTER READY ================="
  echo; echo "  Join a WORKER — run this on each worker node:"
  echo -e "    ${y}curl -sfL $SELF_URL | sudo JOIN=\"$(kubeadm token create --print-join-command)\" bash -s -- join${n}"
  if [[ "$HA_MODE" == multi ]]; then
    CK="$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)"
    echo; echo "  Join a MASTER (HA) — run on each extra control-plane node:"
    echo -e "    ${y}curl -sfL $SELF_URL | sudo JOIN=\"$(kubeadm token create --print-join-command) --control-plane --certificate-key ${CK}\" bash -s -- join${n}"
  fi
  echo; echo "  Then add storage:  curl -sfL $SELF_URL | sudo bash -s -- storage"
  echo;  log "Check nodes:  kubectl get nodes -o wide"
}

# ---------- join worker / master ---------------------------------------------
cmd_join(){
  need_root; prep
  [[ -n "$JOIN" ]] || die "no JOIN command. On a master run:  k8s.sh token   then pass JOIN=\"kubeadm join ...\""
  log "joining cluster"; eval "$JOIN"
  log "joined. From a master:  kubectl get nodes -o wide"
}

# ---------- print a fresh join command ---------------------------------------
cmd_token(){
  need_root; export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
  echo "JOIN=\"$(kubeadm token create --print-join-command)\""
}

# ---------- longhorn storage -------------------------------------------------
cmd_storage(){
  export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
  command -v kubectl >/dev/null || die "run on a master"
  log "installing Longhorn ${LONGHORN_VERSION}"
  kubectl apply -f "https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_VERSION}/deploy/longhorn.yaml"
  kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=600s || warn "longhorn-manager still rolling out"
  if [[ "$LONGHORN_SET_DEFAULT_SC" == true ]]; then
    for sc in $(kubectl get sc -o name); do kubectl annotate "$sc" storageclass.kubernetes.io/is-default-class- >/dev/null 2>&1 || true; done
    kubectl annotate sc longhorn storageclass.kubernetes.io/is-default-class=true --overwrite
  fi
  log "done:"; kubectl get sc
}

# ---------- upgrade (one minor at a time) ------------------------------------
cmd_upgrade(){
  need_root
  local T="${1:?usage: upgrade <version e.g 1.31.2> <first-master|master|worker>}"
  local ROLE="${2:?role: first-master|master|worker}"
  local P; P="$(pm)"; local M; M="$(echo "$T" | cut -d. -f1,2)"; local V="${T}-1.1"
  log "repo -> v${M}, install kubeadm ${T}"
  if [[ "$P" == apt ]]; then
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${M}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${M}/deb/ /" >/etc/apt/sources.list.d/kubernetes.list
    apt-get update -qq; apt-mark unhold kubeadm >/dev/null
    apt-get install -y -qq --allow-change-held-packages kubeadm="$V"; apt-mark hold kubeadm >/dev/null
  else
    sed -i "s#v[0-9]*\.[0-9]*/rpm#v${M}/rpm#g" /etc/yum.repos.d/kubernetes.repo
    dnf install -y -q --disableexcludes=kubernetes kubeadm-"$V"
  fi
  case "$ROLE" in
    first-master) kubeadm upgrade apply "v${T}" -y ;;
    master|worker) kubeadm upgrade node ;;
    *) die "bad role $ROLE" ;;
  esac
  log "upgrading kubelet+kubectl to ${T}"
  if [[ "$P" == apt ]]; then
    apt-mark unhold kubelet kubectl >/dev/null
    apt-get install -y -qq --allow-change-held-packages kubelet="$V" kubectl="$V"; apt-mark hold kubelet kubectl >/dev/null
  else
    dnf install -y -q --disableexcludes=kubernetes kubelet-"$V" kubectl-"$V"
  fi
  systemctl daemon-reload; systemctl restart kubelet
  log "node now v${T}"
}

# ---------- dispatch ---------------------------------------------------------
SELF_URL="${SELF_URL:-https://YOUR_HOST/k8s.sh}"   # set to your public URL
case "${1:-help}" in
  init)    cmd_init ;;
  join)    cmd_join ;;
  token)   cmd_token ;;
  storage) cmd_storage ;;
  upgrade) shift; cmd_upgrade "$@" ;;
  *) cat <<EOF
k8s.sh — one-file Kubernetes installer

  init                         install first control plane + CNI
  join            (JOIN=...)   join this node (worker or master)
  token                        print a fresh JOIN=... command (run on a master)
  storage                      install Longhorn + default StorageClass
  upgrade <ver> <role>         role = first-master | master | worker

Config via env vars: K8S_MINOR K8S_PATCH CNI HA_MODE POD_CIDR
  CONTROL_PLANE_ENDPOINT APISERVER_ADVERTISE_ADDRESS LONGHORN_VERSION

Example:
  curl -sfL $SELF_URL | sudo K8S_MINOR=1.31 CNI=flannel bash -s -- init
EOF
  ;;
esac
