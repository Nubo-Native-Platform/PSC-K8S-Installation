#!/usr/bin/env bash
# Show installable patch versions for the configured (or given) minor track.
#   ./list-versions.sh          # uses K8S_MINOR from config
#   ./list-versions.sh 1.30     # any minor
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
resolve_k8s_minor
MINOR="${1:-$K8S_MINOR}"
PM="$(detect_pm)"
log "available patches on the v${MINOR} track:"
if [[ "$PM" == apt ]]; then
  command -v apt-cache >/dev/null || die "run on a node where the k8s apt repo is configured (after 01-prereqs.sh)"
  apt-cache madison kubeadm 2>/dev/null | awk '{print $3}' | grep "^${MINOR}\." || warn "no cached versions — run: sudo apt-get update"
else
  dnf --showduplicates list kubeadm --disableexcludes=kubernetes 2>/dev/null | awk '/kubeadm/{print $2}' | grep "^${MINOR}\." || true
fi
echo
log "latest stable overall: $(curl -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null || echo '(offline)')"
