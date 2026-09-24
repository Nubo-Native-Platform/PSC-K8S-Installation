#!/usr/bin/env bash
# 04b — NFS dynamic storage: deploy nfs-subdir-external-provisioner against an
# EXISTING NFS server and create an "nfs-client" StorageClass.
#
# Prereqs:
#   * An NFS server exporting a directory (see scripts/nfs-server-setup.sh).
#   * nfs-common / nfs-utils installed on every node (01-prereqs.sh does this).
#   * Run this once from any master (uses kubectl).
#
# Config comes from config/cluster.env: NFS_SERVER, NFS_PATH, NFS_SC_NAME,
# NFS_SET_DEFAULT_SC, NFS_PROVISIONER_IMAGE. Or override on the CLI:
#   sudo NFS_SERVER=192.168.18.69 NFS_PATH=/srv/nfs/k8s ./04b-storage-nfs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

command -v kubectl >/dev/null || die "kubectl not found — run this on a master"

NFS_SERVER="${NFS_SERVER:-}"
NFS_PATH="${NFS_PATH:-/srv/nfs/k8s}"
NFS_SC_NAME="${NFS_SC_NAME:-nfs-client}"
NFS_SET_DEFAULT_SC="${NFS_SET_DEFAULT_SC:-true}"
NFS_NAMESPACE="${NFS_NAMESPACE:-nfs-provisioner}"
NFS_PROVISIONER_IMAGE="${NFS_PROVISIONER_IMAGE:-registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2}"

[[ -n "$NFS_SERVER" ]] || die "set NFS_SERVER (NFS server IP/host) in config/cluster.env or on the CLI"

log "quick reachability check to ${NFS_SERVER}:2049 (NFS)"
timeout 5 bash -c "cat < /dev/null > /dev/tcp/${NFS_SERVER}/2049" 2>/dev/null \
  && log "NFS port reachable" || warn "could not reach ${NFS_SERVER}:2049 — make sure the NFS server is up and exporting ${NFS_PATH}"

log "installing NFS provisioner (server=${NFS_SERVER} path=${NFS_PATH} sc=${NFS_SC_NAME})"
kubectl create namespace "$NFS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- RBAC -------------------------------------------------------------------
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

# --- provisioner deployment -------------------------------------------------
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

# --- StorageClass -----------------------------------------------------------
DEFAULT_ANN=""
if [[ "$NFS_SET_DEFAULT_SC" == "true" ]]; then
  for sc in $(kubectl get sc -o name); do
    kubectl annotate "$sc" storageclass.kubernetes.io/is-default-class- >/dev/null 2>&1 || true
  done
  DEFAULT_ANN='storageclass.kubernetes.io/is-default-class: "true"'
fi
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${NFS_SC_NAME}
  annotations:
    ${DEFAULT_ANN}
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  archiveOnDelete: "false"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF

log "waiting for provisioner to roll out"
kubectl -n "$NFS_NAMESPACE" rollout status deploy/nfs-client-provisioner --timeout=300s || \
  warn "provisioner not ready yet — check: kubectl -n ${NFS_NAMESPACE} get pods"

log "done. StorageClasses:"; kubectl get sc
echo
log "test it:  kubectl apply -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: test-nfs }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${NFS_SC_NAME}
  resources: { requests: { storage: 1Gi } }
YAML
kubectl get pvc test-nfs   # should become Bound"
