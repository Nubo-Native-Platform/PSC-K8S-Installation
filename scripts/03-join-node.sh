#!/usr/bin/env bash
# 03 — Join this node to the cluster.
#   sudo ./03-join-node.sh worker    # default
#   sudo ./03-join-node.sh master    # extra control-plane node (HA)
# Requires 01-prereqs.sh already run here. Copy the config/join-*.sh from the
# first master (or paste the token args), OR pass the full join command as args.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
ROLE="${1:-worker}"

if [[ "$ROLE" == master ]]; then
  JOIN_FILE="$ROOT_DIR/config/join-master.sh"
else
  JOIN_FILE="$ROOT_DIR/config/join-worker.sh"
fi

if [[ $# -gt 1 ]]; then
  shift; log "joining as $ROLE using command-line args"; eval "$*"
elif [[ -f "$JOIN_FILE" ]]; then
  log "joining as $ROLE using $JOIN_FILE"; bash "$JOIN_FILE"
else
  die "no join info. Copy $JOIN_FILE from the first master, or pass the join command as arguments.
Regenerate on a master with:
  kubeadm token create --print-join-command"
fi

log "joined. From a master run: kubectl get nodes -o wide"
