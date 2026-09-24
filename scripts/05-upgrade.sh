#!/usr/bin/env bash
# 05 — Upgrade Kubernetes. Run per node, control-plane FIRST.
#
#   # bump ONE minor at a time (e.g. 1.36 -> 1.37). k8s does not support
#   # skipping minors. For 1.35 -> 1.37, run this twice.
#
#   On the FIRST master:   sudo ./05-upgrade.sh 1.37.0 first-master
#   On other masters:      sudo ./05-upgrade.sh 1.37.0 master
#   On each worker:        sudo ./05-upgrade.sh 1.37.0 worker
#
# Arg1 = target full version (e.g. 1.37.0). Arg2 = role.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
TARGET="${1:?usage: 05-upgrade.sh <version e.g. 1.37.0> <first-master|master|worker>}"
ROLE="${2:?role required: first-master | master | worker}"
PM="$(detect_pm)"
MINOR="$(echo "$TARGET" | cut -d. -f1,2)"
VER="${TARGET}-1.1"

log "pointing package repo at v${MINOR} and installing kubeadm ${TARGET}"
if [[ "$PM" == apt ]]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${MINOR}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${MINOR}/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list
  apt_update
  apt-mark unhold kubeadm >/dev/null
  apt-get install -y -qq --allow-change-held-packages kubeadm="$VER"
  apt-mark hold kubeadm >/dev/null
else
  sed -i "s#v[0-9]*\.[0-9]*/rpm#v${MINOR}/rpm#g" /etc/yum.repos.d/kubernetes.repo
  dnf install -y -q --disableexcludes=kubernetes kubeadm-"$VER"
fi
kubeadm version

# --- apply control-plane upgrade --------------------------------------------
if [[ "$ROLE" == "first-master" ]]; then
  log "planning upgrade"; kubeadm upgrade plan "v${TARGET}" || true
  log "applying upgrade on first control-plane node"
  kubeadm upgrade apply "v${TARGET}" -y
elif [[ "$ROLE" == "master" ]]; then
  log "upgrading additional control-plane node"
  kubeadm upgrade node
else
  log "upgrading worker node config"
  kubeadm upgrade node
fi

# --- drain, upgrade kubelet/kubectl, uncordon -------------------------------
NODE="$(hostname)"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
if [[ "$ROLE" == "worker" ]]; then
  warn "drain the worker from a MASTER before continuing if you want zero-disruption:"
  warn "  kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data"
fi

log "upgrading kubelet + kubectl to ${TARGET}"
if [[ "$PM" == apt ]]; then
  apt-mark unhold kubelet kubectl >/dev/null
  apt-get install -y -qq --allow-change-held-packages kubelet="$VER" kubectl="$VER"
  apt-mark hold kubelet kubectl >/dev/null
else
  dnf install -y -q --disableexcludes=kubernetes kubelet-"$VER" kubectl-"$VER"
fi
systemctl daemon-reload
systemctl restart kubelet

log "node upgraded to v${TARGET}. Verify: kubectl get nodes"
[[ "$ROLE" == "first-master" ]] && warn "Now update config/cluster.env: K8S_MINOR=$MINOR (K8S_PATCH=$TARGET) and upgrade the remaining nodes."
