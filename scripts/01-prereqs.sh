#!/usr/bin/env bash
# 01 — Node prep: kernel, containerd, and kubeadm/kubelet/kubectl.
# Run on EVERY node (masters and workers) before init/join.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
resolve_k8s_minor
PM="$(detect_pm)"

log "disabling swap"
swapoff -a
sed -i.bak '/\bswap\b/ s/^/#/' /etc/fstab || true

log "loading kernel modules + sysctl for k8s networking"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay; modprobe br_netfilter
cat >/etc/sysctl.d/99-k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
# Raise inotify limits (configurable). The kernel default max_user_instances
# (128) is far too low for busy nodes: kubelet/containerd and log watchers
# exhaust it, which makes "kubectl logs" return nothing and leaves pods stuck
# not-Ready / CrashLoopBackOff with "too many open files".
fs.inotify.max_user_instances       = ${INOTIFY_MAX_USER_INSTANCES:-8192}
fs.inotify.max_user_watches         = ${INOTIFY_MAX_USER_WATCHES:-1048576}
EOF
sysctl --system >/dev/null

# --- container runtime: containerd ------------------------------------------
log "installing containerd"
if [[ "$PM" == apt ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt_update
  apt-get install -y -qq ca-certificates curl gnupg apt-transport-https
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) stable" \
    >/etc/apt/sources.list.d/docker.list
  apt_update
  apt-get install -y -qq containerd.io
else
  dnf install -y -q dnf-plugins-core curl
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf install -y -q containerd.io
fi

log "configuring containerd (SystemdCgroup=true)"
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd >/dev/null

# --- kubeadm / kubelet / kubectl --------------------------------------------
log "installing kube tools for v${K8S_MINOR} (patch: ${K8S_PATCH:-latest})"
VER="$(pkg_version)"
if [[ "$PM" == apt ]]; then
  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list
  apt_update
  if [[ -n "$VER" ]]; then
    apt-get install -y -qq --allow-change-held-packages kubelet="$VER" kubeadm="$VER" kubectl="$VER"
  else
    apt-get install -y -qq kubelet kubeadm kubectl
  fi
  apt-mark hold kubelet kubeadm kubectl >/dev/null
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
  if [[ -n "$VER" ]]; then
    dnf install -y -q --disableexcludes=kubernetes kubelet-"$VER" kubeadm-"$VER" kubectl-"$VER"
  else
    dnf install -y -q --disableexcludes=kubernetes kubelet kubeadm kubectl
  fi
fi
systemctl enable kubelet >/dev/null

# open-iscsi is required by Longhorn — install now so workers are ready.
log "installing open-iscsi + nfs client (needed by Longhorn)"
if [[ "$PM" == apt ]]; then
  apt-get install -y -qq open-iscsi nfs-common
else
  dnf install -y -q iscsi-initiator-utils nfs-utils
fi
systemctl enable --now iscsid >/dev/null 2>&1 || true

log "prereqs done on this node ($(node_ip))"
