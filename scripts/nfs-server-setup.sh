#!/usr/bin/env bash
# nfs-server-setup.sh — turn a plain Ubuntu/RHEL box into an NFS server for
# Kubernetes dynamic storage (used by STORAGE=nfs / 04b-storage-nfs.sh).
#
# Run this ON THE FILE SERVER (e.g. 192.168.18.69), as root:
#   sudo ./nfs-server-setup.sh
#
# Config via env vars (all optional):
#   NFS_PATH   exported directory              (default /srv/nfs/k8s)
#   NFS_CIDR   client network allowed to mount (default auto: this host's /24)
#   NFS_OPTS   export options                  (default rw,sync,no_subtree_check,no_root_squash)
#
# Example — export to the 192.168.18.0/24 lab network:
#   sudo NFS_PATH=/srv/nfs/k8s NFS_CIDR=192.168.18.0/24 ./nfs-server-setup.sh
set -euo pipefail

g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }
warn(){ echo -e "${y}[!]${n} $*"; }
die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root (use sudo)"

NFS_PATH="${NFS_PATH:-/srv/nfs/k8s}"
# Hardened defaults: root_squash + all_squash map every client UID (incl. root)
# to 'nobody', so a compromised client can't act as root on the server, and no
# file is owned by root. The dynamic provisioner and both root/non-root pods
# still work (verified). Set NFS_OPTS to override.
NFS_OPTS="${NFS_OPTS:-rw,sync,no_subtree_check,root_squash,all_squash,anonuid=65534,anongid=65534}"
# Default client CIDR = this host's primary IPv4 /24 (e.g. 192.168.18.0/24).
if [[ -z "${NFS_CIDR:-}" ]]; then
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
  [[ -n "$ip" ]] || die "could not auto-detect network; set NFS_CIDR (e.g. 192.168.18.0/24)"
  NFS_CIDR="$(echo "$ip" | awk -F. '{print $1"."$2"."$3".0/24"}')"
  warn "NFS_CIDR not set — defaulting to ${NFS_CIDR} (override with NFS_CIDR=...)"
fi

pm(){ command -v apt-get >/dev/null && echo apt || { command -v dnf >/dev/null && echo dnf || die "need apt or dnf"; }; }
P="$(pm)"

log "installing NFS server packages"
if [[ "$P" == apt ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq nfs-kernel-server
  SVC=nfs-kernel-server
else
  dnf install -y -q nfs-utils
  SVC=nfs-server
fi

log "creating export directory ${NFS_PATH} (owned by nobody, mode 0755)"
mkdir -p "$NFS_PATH"
# With all_squash the provisioner writes as 'nobody', so the export root is owned
# by nobody and only 0755 (no world-write). Per-PVC subdirs are created 0777 by
# the provisioner so pods of any UID can use their own volume.
chown nobody:nogroup "$NFS_PATH" 2>/dev/null || chown 65534:65534 "$NFS_PATH"
chmod 0755 "$NFS_PATH"

# Defensive: if this export ALREADY holds data created before all_squash was
# applied (files owned by real UIDs like 100), those files become unreadable once
# all_squash maps every client to the anon UID (65534) — e.g. OpenBao's raft
# node-id, which then fails to open on the next pod restart ("permission denied").
# Re-home any such pre-existing data to the anon UID so a mid-life hardening of
# the export never strands running workloads. (Fresh subdirs are already 65534.)
if [[ "${NFS_OPTS}" == *all_squash* ]] && [[ -n "$(ls -A "$NFS_PATH" 2>/dev/null)" ]]; then
  if find "$NFS_PATH" -maxdepth 3 ! -uid 65534 -print -quit 2>/dev/null | grep -q .; then
    log "re-homing pre-existing export data to anon uid 65534 (all_squash consistency)"
    chown -R 65534:65534 "$NFS_PATH"/* 2>/dev/null || true
  fi
fi

log "configuring /etc/exports  (${NFS_PATH}  ${NFS_CIDR}(${NFS_OPTS}))"
LINE="${NFS_PATH} ${NFS_CIDR}(${NFS_OPTS})"
touch /etc/exports
# replace any existing line for this path, else append
if grep -qE "^${NFS_PATH//\//\\/}[[:space:]]" /etc/exports; then
  sed -i "s#^${NFS_PATH//\//\\/}[[:space:]].*#${LINE}#" /etc/exports
else
  echo "$LINE" >>/etc/exports
fi

log "applying exports + enabling service"
exportfs -ra
systemctl enable --now "$SVC" >/dev/null 2>&1 || systemctl restart "$SVC"

# Open the firewall if one is active.
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  log "ufw active — allowing NFS from ${NFS_CIDR}"
  ufw allow from "$NFS_CIDR" to any port nfs >/dev/null 2>&1 || ufw allow nfs >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  log "firewalld active — allowing nfs/mountd/rpc-bind"
  firewall-cmd --permanent --add-service={nfs,mountd,rpc-bind} >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi

echo
log "NFS server ready."
log "current exports:"; exportfs -v || true
echo
log "Now, on a master, create the StorageClass pointing here:"
echo "    STORAGE=nfs NFS_SERVER=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}') NFS_PATH=${NFS_PATH}"
echo "    (via  ./deploy.sh storage   or   scripts/04b-storage-nfs.sh)"
