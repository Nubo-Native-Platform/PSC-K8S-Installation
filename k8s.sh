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
#   Install storage (run on a master) — Longhorn (default) or NFS:
#     curl -sfL https://YOUR_HOST/k8s.sh | sudo bash -s -- storage
#     curl -sfL https://YOUR_HOST/k8s.sh | sudo STORAGE=nfs \
#       NFS_SERVER=192.168.18.69 NFS_PATH=/srv/nfs/k8s bash -s -- storage
#
#   Upgrade (one minor at a time, control plane first):
#     curl -sfL https://YOUR_HOST/k8s.sh | sudo bash -s -- upgrade 1.37.0 first-master
#
#  CONFIG = environment variables (all optional, sane defaults):
#     K8S_MINOR=latest K8S_PATCH= CNI=flannel HA_MODE=single \
#     POD_CIDR=10.244.0.0/16 CONTROL_PLANE_ENDPOINT= \
#     STORAGE=longhorn NFS_SERVER= NFS_PATH= LONGHORN_VERSION=v1.10.0 \
#     curl -sfL https://YOUR_HOST/k8s.sh | sudo bash -s -- init
# =============================================================================
set -euo pipefail

# ---------- defaults (override with env vars) --------------------------------
K8S_MINOR="${K8S_MINOR:-latest}"   # 'latest' = newest stable minor (auto-detected); or pin e.g. 1.37
K8S_PATCH="${K8S_PATCH:-}"          # empty = latest patch on the minor; or pin e.g. 1.37.0
CNI="${CNI:-flannel}"                       # flannel | calico
HA_MODE="${HA_MODE:-single}"                # single | multi
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
MAX_PODS="${MAX_PODS:-110}"                 # kubelet maxPods per node (default 110)
# inotify limits (kernel default max_user_instances=128 is too low for k8s nodes)
INOTIFY_MAX_USER_INSTANCES="${INOTIFY_MAX_USER_INSTANCES:-8192}"
INOTIFY_MAX_USER_WATCHES="${INOTIFY_MAX_USER_WATCHES:-1048576}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-}"
APISERVER_ADVERTISE_ADDRESS="${APISERVER_ADVERTISE_ADDRESS:-}"

# ---- storage backend: longhorn | nfs | none ---------------------------------
STORAGE="${STORAGE:-longhorn}"
# Longhorn
LONGHORN_VERSION="${LONGHORN_VERSION:-v1.10.0}"
LONGHORN_SET_DEFAULT_SC="${LONGHORN_SET_DEFAULT_SC:-true}"
# NFS (external NFS server + nfs-subdir-external-provisioner)
NFS_SERVER="${NFS_SERVER:-}"                # NFS server IP/host (required for STORAGE=nfs)
NFS_PATH="${NFS_PATH:-/srv/nfs/k8s}"        # exported path on the NFS server
NFS_SC_NAME="${NFS_SC_NAME:-nfs-client}"    # StorageClass name to create
# Safety: archive (rename to archived-*) instead of deleting data when a PVC is
# removed, so an accidental PVC delete does NOT wipe the data. Set false to
# hard-delete on PVC removal.
NFS_ARCHIVE_ON_DELETE="${NFS_ARCHIVE_ON_DELETE:-true}"
# Retention: keep only the last N archived copies of each PVC (grouped by
# namespace+PVC name) as a recovery window; a CronJob prunes older ones so
# archives don't grow forever. 0 = keep everything (no pruning).
NFS_ARCHIVE_RETENTION="${NFS_ARCHIVE_RETENTION:-3}"
NFS_ARCHIVE_PRUNE_SCHEDULE="${NFS_ARCHIVE_PRUNE_SCHEDULE:-0 2 * * *}"   # cron (default daily 02:00)
NFS_PROVISIONER_IMAGE="${NFS_PROVISIONER_IMAGE:-registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2}"
NFS_SET_DEFAULT_SC="${NFS_SET_DEFAULT_SC:-true}"
NFS_NAMESPACE="${NFS_NAMESPACE:-nfs-provisioner}"

JOIN="${JOIN:-}"                            # full join command (for `join`)

# ---------- helpers ----------------------------------------------------------
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }
warn(){ echo -e "${y}[!]${n} $*"; }
die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "run as root (use sudo)"; }
pm(){ command -v apt-get >/dev/null && echo apt || { command -v dnf >/dev/null && echo dnf || die "need apt or dnf"; }; }
# apt-get update can hit transient mirror-sync errors ("File has unexpected
# size"); retry a few times before giving up.
apt_update(){ local i; for i in 1 2 3 4 5; do apt-get update -qq -o DPkg::Lock::Timeout=600 && return 0; warn "apt-get update failed (attempt $i/5) — retrying in 5s"; sleep 5; done; die "apt-get update failed after 5 attempts"; }
# apt-get install can also fail transiently, and the dpkg lock is often held by
# unattended-upgrades on a fresh VM. Wait up to 10min for the lock, and retry.
apt_install(){ local i; for i in 1 2 3; do DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o DPkg::Lock::Timeout=600 "$@" && return 0; warn "apt-get install failed (attempt $i/3) — retrying in 10s"; sleep 10; done; die "apt-get install failed: $*"; }
ver(){ [[ -n "$K8S_PATCH" ]] && echo "${K8S_PATCH}-1.1" || echo ""; }
myip(){ [[ -n "$APISERVER_ADVERTISE_ADDRESS" ]] && echo "$APISERVER_ADVERTISE_ADDRESS" || ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'; }

# Resolve K8S_MINOR=latest|auto|empty -> the newest stable minor from upstream.
# e.g. stable.txt = v1.37.0  ->  K8S_MINOR=1.37   (pin K8S_MINOR=1.36 to override)
resolve_k8s_minor(){
  case "${K8S_MINOR:-latest}" in
    latest|auto|"")
      local s; s="$(curl -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null || true)"
      [[ "$s" =~ ^v[0-9]+\.[0-9]+ ]] || die "could not fetch latest Kubernetes version; set K8S_MINOR (e.g. 1.37)"
      K8S_MINOR="$(echo "${s#v}" | cut -d. -f1,2)"
      log "latest stable Kubernetes -> v${K8S_MINOR} (${s})"
      ;;
  esac
}

# ---------- node prep (shared by init & join) --------------------------------
prep(){
  local P; P="$(pm)"
  resolve_k8s_minor
  log "prep: swap off, kernel modules, sysctl"
  swapoff -a; sed -i.bak '/\bswap\b/ s/^/#/' /etc/fstab || true
  printf 'overlay\nbr_netfilter\n' >/etc/modules-load.d/k8s.conf
  modprobe overlay; modprobe br_netfilter
  cat >/etc/sysctl.d/99-k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
# Raise inotify limits (configurable). The kernel default max_user_instances
# (128) is far too low for busy nodes: kubelet/containerd and log watchers
# exhaust it, which makes "kubectl logs" return nothing and leaves pods stuck
# not-Ready / CrashLoopBackOff with "too many open files".
fs.inotify.max_user_instances       = ${INOTIFY_MAX_USER_INSTANCES}
fs.inotify.max_user_watches         = ${INOTIFY_MAX_USER_WATCHES}
EOF
  sysctl --system >/dev/null

  log "installing containerd"
  if [[ "$P" == apt ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt_update
    apt_install ca-certificates curl gnupg apt-transport-https
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo "$VERSION_CODENAME") stable" >/etc/apt/sources.list.d/docker.list
    apt_update; apt_install containerd.io
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
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" >/etc/apt/sources.list.d/kubernetes.list
    apt_update
    if [[ -n "$V" ]]; then apt_install kubelet="$V" kubeadm="$V" kubectl="$V"; else apt_install kubelet kubeadm kubectl; fi
    apt-mark hold kubelet kubeadm kubectl >/dev/null
    apt_install open-iscsi nfs-common
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

# Set kubelet maxPods (run AFTER kubeadm init/join has written config.yaml).
# Note: with a /24 per-node podCIDR there are 254 pod IPs, so keep MAX_PODS<=250.
apply_max_pods(){
  [[ -n "$MAX_PODS" && "$MAX_PODS" != 110 ]] || return 0
  local f=/var/lib/kubelet/config.yaml
  [[ -f "$f" ]] || { warn "kubelet config not found; skipping maxPods"; return 0; }
  if grep -q '^maxPods:' "$f"; then sed -i "s/^maxPods:.*/maxPods: ${MAX_PODS}/" "$f"; else echo "maxPods: ${MAX_PODS}" >>"$f"; fi
  systemctl restart kubelet
  log "kubelet maxPods set to ${MAX_PODS}"
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
  apply_max_pods

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
  apply_max_pods
  log "joined. From a master:  kubectl get nodes -o wide"
}

# ---------- print a fresh join command ---------------------------------------
cmd_token(){
  need_root; export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
  echo "JOIN=\"$(kubeadm token create --print-join-command)\""
}

# ---------- storage: dispatch longhorn | nfs | none --------------------------
cmd_storage(){
  export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
  command -v kubectl >/dev/null || die "run on a master"
  case "$STORAGE" in
    longhorn) storage_longhorn ;;
    nfs)      storage_nfs ;;
    none)     warn "STORAGE=none — skipping storage install" ;;
    *) die "unknown STORAGE: $STORAGE (use longhorn | nfs | none)" ;;
  esac
}

clear_default_sc(){ for sc in $(kubectl get sc -o name); do kubectl annotate "$sc" storageclass.kubernetes.io/is-default-class- >/dev/null 2>&1 || true; done; }

storage_longhorn(){
  log "installing Longhorn ${LONGHORN_VERSION}"
  kubectl apply -f "https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_VERSION}/deploy/longhorn.yaml"
  kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=600s || warn "longhorn-manager still rolling out"
  if [[ "$LONGHORN_SET_DEFAULT_SC" == true ]]; then
    clear_default_sc
    kubectl annotate sc longhorn storageclass.kubernetes.io/is-default-class=true --overwrite
  fi
  log "done:"; kubectl get sc
}

# NFS: deploy nfs-subdir-external-provisioner against an EXISTING NFS server.
# The NFS server itself is set up separately (see scripts/nfs-server-setup.sh).
storage_nfs(){
  [[ -n "$NFS_SERVER" ]] || die "STORAGE=nfs needs NFS_SERVER (IP/host of the NFS server)"
  log "installing NFS provisioner (server=${NFS_SERVER} path=${NFS_PATH} sc=${NFS_SC_NAME})"
  kubectl create namespace "$NFS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  # RBAC
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: { name: nfs-client-provisioner, namespace: ${NFS_NAMESPACE} }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: nfs-client-provisioner-runner }
rules:
  - { apiGroups: [""], resources: ["nodes"], verbs: ["get","list","watch"] }
  - { apiGroups: [""], resources: ["persistentvolumes"], verbs: ["get","list","watch","create","delete"] }
  - { apiGroups: [""], resources: ["persistentvolumeclaims"], verbs: ["get","list","watch","update"] }
  - { apiGroups: ["storage.k8s.io"], resources: ["storageclasses"], verbs: ["get","list","watch"] }
  - { apiGroups: [""], resources: ["events"], verbs: ["create","update","patch"] }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: run-nfs-client-provisioner }
subjects:
  - { kind: ServiceAccount, name: nfs-client-provisioner, namespace: ${NFS_NAMESPACE} }
roleRef: { kind: ClusterRole, name: nfs-client-provisioner-runner, apiGroup: rbac.authorization.k8s.io }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: leader-locking-nfs-client-provisioner, namespace: ${NFS_NAMESPACE} }
rules:
  - { apiGroups: [""], resources: ["endpoints"], verbs: ["get","list","watch","create","update","patch"] }
  - { apiGroups: ["coordination.k8s.io"], resources: ["leases"], verbs: ["get","list","watch","create","update","patch"] }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: leader-locking-nfs-client-provisioner, namespace: ${NFS_NAMESPACE} }
subjects:
  - { kind: ServiceAccount, name: nfs-client-provisioner, namespace: ${NFS_NAMESPACE} }
roleRef: { kind: Role, name: leader-locking-nfs-client-provisioner, apiGroup: rbac.authorization.k8s.io }
EOF

  # Provisioner deployment
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-client-provisioner
  namespace: ${NFS_NAMESPACE}
  labels: { app: nfs-client-provisioner }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector: { matchLabels: { app: nfs-client-provisioner } }
  template:
    metadata: { labels: { app: nfs-client-provisioner } }
    spec:
      serviceAccountName: nfs-client-provisioner
      containers:
        - name: nfs-client-provisioner
          image: ${NFS_PROVISIONER_IMAGE}
          volumeMounts:
            - { name: nfs-client-root, mountPath: /persistentvolumes }
          env:
            - { name: PROVISIONER_NAME, value: k8s-sigs.io/nfs-subdir-external-provisioner }
            - { name: NFS_SERVER, value: "${NFS_SERVER}" }
            - { name: NFS_PATH, value: "${NFS_PATH}" }
      volumes:
        - name: nfs-client-root
          nfs: { server: "${NFS_SERVER}", path: "${NFS_PATH}" }
EOF

  # StorageClass
  local DEFAULT_ANN=""
  [[ "$NFS_SET_DEFAULT_SC" == true ]] && { clear_default_sc; DEFAULT_ANN='storageclass.kubernetes.io/is-default-class: "true"'; }
  kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${NFS_SC_NAME}
  annotations:
    ${DEFAULT_ANN}
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  archiveOnDelete: "${NFS_ARCHIVE_ON_DELETE}"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF

  kubectl -n "$NFS_NAMESPACE" rollout status deploy/nfs-client-provisioner --timeout=300s || warn "provisioner still rolling out"

  # Retention pruner: keep only the last N archived-* copies per PVC group.
  if [[ "$NFS_ARCHIVE_ON_DELETE" == true && "${NFS_ARCHIVE_RETENTION}" =~ ^[0-9]+$ && "$NFS_ARCHIVE_RETENTION" -gt 0 ]]; then
    log "installing archive-retention CronJob (keep last ${NFS_ARCHIVE_RETENTION} per PVC, schedule '${NFS_ARCHIVE_PRUNE_SCHEDULE}')"
    kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata: { name: nfs-archive-pruner, namespace: ${NFS_NAMESPACE} }
spec:
  schedule: "${NFS_ARCHIVE_PRUNE_SCHEDULE}"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: pruner
              image: alpine:3.20
              env:
                - { name: KEEP, value: "${NFS_ARCHIVE_RETENTION}" }
              command: ["/bin/sh","-c"]
              args:
                - |
                  set -e
                  cd /export || exit 0
                  # group = archived dir name with the trailing -pvc-<uuid> removed
                  for d in archived-*; do
                    [ -d "\$d" ] || continue
                    grp=\$(printf '%s' "\$d" | sed -E 's/-pvc-[0-9a-f-]+\$//')
                    printf '%s|%s|%s\n' "\$grp" "\$(stat -c %Y "\$d")" "\$d"
                  done | sort -t'|' -k1,1 -k2,2nr \
                  | awk -F'|' -v keep="\$KEEP" '{c[\$1]++; if (c[\$1]>keep) print \$3}' \
                  | while read -r old; do echo "pruning \$old"; rm -rf "/export/\$old"; done
                  echo "retention pass done (keep=\$KEEP per PVC)"
              volumeMounts: [{ name: export, mountPath: /export }]
          volumes:
            - name: export
              nfs: { server: "${NFS_SERVER}", path: "${NFS_PATH}" }
EOF
  fi
  log "done:"; kubectl get sc
}

# ---------- upgrade (one minor at a time) ------------------------------------
cmd_upgrade(){
  need_root
  local T="${1:?usage: upgrade <version e.g 1.37.0> <first-master|master|worker>}"
  local ROLE="${2:?role: first-master|master|worker}"
  local P; P="$(pm)"; local M; M="$(echo "$T" | cut -d. -f1,2)"; local V="${T}-1.1"
  log "repo -> v${M}, install kubeadm ${T}"
  if [[ "$P" == apt ]]; then
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${M}/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${M}/deb/ /" >/etc/apt/sources.list.d/kubernetes.list
    apt_update; apt-mark unhold kubeadm >/dev/null
    apt_install --allow-change-held-packages kubeadm="$V"; apt-mark hold kubeadm >/dev/null
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
    apt_install --allow-change-held-packages kubelet="$V" kubectl="$V"; apt-mark hold kubelet kubectl >/dev/null
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
  storage                      install storage + default StorageClass
                               (STORAGE=longhorn | nfs | none)
  upgrade <ver> <role>         role = first-master | master | worker

Config via env vars: K8S_MINOR K8S_PATCH CNI HA_MODE POD_CIDR
  CONTROL_PLANE_ENDPOINT APISERVER_ADVERTISE_ADDRESS
  STORAGE LONGHORN_VERSION NFS_SERVER NFS_PATH NFS_SC_NAME

Examples:
  curl -sfL $SELF_URL | sudo K8S_MINOR=1.34 CNI=flannel bash -s -- init
  curl -sfL $SELF_URL | sudo STORAGE=nfs NFS_SERVER=192.168.18.69 \
    NFS_PATH=/srv/nfs/k8s bash -s -- storage
EOF
  ;;
esac
