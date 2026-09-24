#!/usr/bin/env bash
# lb-haproxy-setup.sh — stand up a simple L4 load balancer for the Kubernetes
# control plane (kube-apiserver :6443). HA (2+ masters) needs a single stable
# CONTROL_PLANE_ENDPOINT in front of all masters; this provides one with HAProxy.
#
# Run this on a host that is NOT one of the masters (e.g. the file server), then
# set CONTROL_PLANE_ENDPOINT=<this-host-ip>:6443 before deploying the cluster.
#
#   sudo ./lb-haproxy-setup.sh 192.168.18.61 192.168.18.62 192.168.18.63
#   # then in inventory.conf:  CONTROL_PLANE_ENDPOINT=192.168.18.69:6443
#
# Config via env vars (optional):
#   LB_PORT   listen port (default 6443)
#
# NOTE: a single HAProxy host is itself a single point of failure. For true HA,
# run HAProxy on 2+ hosts with keepalived sharing a virtual IP (VIP), and point
# CONTROL_PLANE_ENDPOINT at the VIP. This script covers the common lab/test case.
set -euo pipefail

g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }
warn(){ echo -e "${y}[!]${n} $*"; }
die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root (use sudo)"

LB_PORT="${LB_PORT:-6443}"
[[ $# -ge 1 ]] || die "usage: $0 <master1-ip> [master2-ip] [master3-ip] ..."
MASTERS=("$@")

pm(){ command -v apt-get >/dev/null && echo apt || { command -v dnf >/dev/null && echo dnf || die "need apt or dnf"; }; }
P="$(pm)"

log "installing haproxy"
if [[ "$P" == apt ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq; apt-get install -y -qq haproxy
else
  dnf install -y -q haproxy
fi

log "writing /etc/haproxy/haproxy.cfg  (frontend :${LB_PORT} -> ${#MASTERS[@]} masters)"
{
  cat <<EOF
global
    log /dev/log local0
    maxconn 4096
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 10s
    timeout client  1h
    timeout server  1h

frontend kube-apiserver
    bind *:${LB_PORT}
    default_backend kube-masters

backend kube-masters
    option tcp-check
    balance roundrobin
EOF
  i=1
  for ip in "${MASTERS[@]}"; do
    echo "    server master${i} ${ip}:6443 check fall 3 rise 2"
    i=$((i+1))
  done
} >/etc/haproxy/haproxy.cfg

# SELinux: allow haproxy to bind/connect on non-standard ports if enforcing.
if command -v getenforce >/dev/null && [[ "$(getenforce 2>/dev/null)" == Enforcing ]]; then
  setsebool -P haproxy_connect_any 1 >/dev/null 2>&1 || true
fi

log "enabling + restarting haproxy"
systemctl enable haproxy >/dev/null 2>&1 || true
systemctl restart haproxy

# firewall
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${LB_PORT}/tcp" >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${LB_PORT}/tcp" >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi

MYIP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
echo
log "HAProxy up. Control-plane endpoint:  ${MYIP}:${LB_PORT}"
log "Set this in inventory.conf:  CONTROL_PLANE_ENDPOINT=${MYIP}:${LB_PORT}"
warn "Backends will show DOWN until the first master has run 'kubeadm init' — that's expected."
