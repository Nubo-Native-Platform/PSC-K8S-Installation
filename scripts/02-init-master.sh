#!/usr/bin/env bash
# 02 — Initialize the FIRST control-plane node, then install the CNI.
# Run on exactly one master. Prints join commands at the end.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root

IP="$(node_ip)"; [[ -n "$IP" ]] || die "could not detect node IP; set APISERVER_ADVERTISE_ADDRESS"
VER_ARG=""; [[ -n "${K8S_PATCH:-}" ]] && VER_ARG="--kubernetes-version=v${K8S_PATCH}"

# Flannel wants 10.244.0.0/16; Calico wants 192.168.0.0/16 by default.
if [[ "$CNI" == "calico" && "$POD_CIDR" == "10.244.0.0/16" ]]; then
  warn "CNI=calico but POD_CIDR is Flannel's default — consider 192.168.0.0/16"
fi

ARGS=(
  --pod-network-cidr="$POD_CIDR"
  --service-cidr="$SERVICE_CIDR"
  --apiserver-advertise-address="$IP"
  $VER_ARG
)
if [[ "$HA_MODE" == "multi" ]]; then
  [[ -n "${CONTROL_PLANE_ENDPOINT:-}" ]] || die "HA_MODE=multi needs CONTROL_PLANE_ENDPOINT (VIP/LB)"
  ARGS+=( --control-plane-endpoint="$CONTROL_PLANE_ENDPOINT" --upload-certs )
  log "initializing HA control plane (endpoint: $CONTROL_PLANE_ENDPOINT)"
else
  [[ -n "${CONTROL_PLANE_ENDPOINT:-}" ]] && ARGS+=( --control-plane-endpoint="$CONTROL_PLANE_ENDPOINT" )
  log "initializing single control plane on $IP"
fi

kubeadm init "${ARGS[@]}" | tee /var/log/kubeadm-init.log

# --- kubeconfig for root + the invoking sudo user ---------------------------
export KUBECONFIG=/etc/kubernetes/admin.conf
mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
  u_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  mkdir -p "$u_home/.kube"
  cp -f /etc/kubernetes/admin.conf "$u_home/.kube/config"
  chown -R "$SUDO_USER":"$SUDO_USER" "$u_home/.kube"
fi

# --- CNI --------------------------------------------------------------------
log "installing CNI: $CNI"
case "$CNI" in
  flannel)
    kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
    ;;
  calico)
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/tigera-operator.yaml
    curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/custom-resources.yaml \
      | sed "s#192.168.0.0/16#${POD_CIDR}#" | kubectl apply -f -
    ;;
  *) die "unknown CNI: $CNI (use flannel or calico)";;
esac

# --- stash join commands ----------------------------------------------------
mkdir -p "$ROOT_DIR/config"
kubeadm token create --print-join-command >"$ROOT_DIR/config/join-worker.sh"
chmod +x "$ROOT_DIR/config/join-worker.sh"
log "worker join command saved -> config/join-worker.sh"

if [[ "$HA_MODE" == "multi" ]]; then
  CERT_KEY="$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)"
  echo "$(cat "$ROOT_DIR/config/join-worker.sh") --control-plane --certificate-key ${CERT_KEY}" \
    >"$ROOT_DIR/config/join-master.sh"
  chmod +x "$ROOT_DIR/config/join-master.sh"
  log "master join command saved -> config/join-master.sh (cert-key valid ~2h)"
fi

echo
log "control plane ready. Check: kubectl get nodes"
