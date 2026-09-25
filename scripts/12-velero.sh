#!/usr/bin/env bash
# 12 — Install Velero and back up the cluster (resources + PV data) to AWS S3.
# Run once from a master. PV data is captured with File System Backup (node
# agent), so NFS-backed PVCs are copied to S3 too (no CSI snapshots needed).
#
#   sudo VELERO_BUCKET=my-bucket AWS_REGION=us-east-1 \
#        AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
#        ./scripts/12-velero.sh
#
# Config via env vars:
#   VELERO_BUCKET         (required) S3 bucket for backups
#   AWS_REGION            (required) e.g. us-east-1
#   AWS_ACCESS_KEY_ID     (required) credentials for the bucket
#   AWS_SECRET_ACCESS_KEY (required)
#   VELERO_VERSION        default v1.16.1
#   VELERO_PLUGIN_AWS     default v1.12.1
#   VELERO_SCHEDULE       default "0 3 * * *" (daily 03:00); "" to skip the schedule
#   VELERO_KEEP           default 4 — ALWAYS keep the newest N backups (count-based;
#                         an outage can't age them away). A pruner CronJob enforces it.
#   VELERO_TTL            default 720h0m0s (30d) — safety backstop only: backups are
#                         removed once they are BOTH beyond the newest N and 30d old.
#   VELERO_EXCLUDE_NAMESPACES  default "monitoring" (skip large/ephemeral data to
#                              save S3 cost; comma-separated)
set -euo pipefail
VELERO_VERSION="${VELERO_VERSION:-v1.16.1}"
VELERO_PLUGIN_AWS="${VELERO_PLUGIN_AWS:-v1.12.1}"
VELERO_BUCKET="${VELERO_BUCKET:?set VELERO_BUCKET}"
# Velero validates that its location contains ONLY its own layout, so it must have
# its OWN prefix — otherwise other data in the bucket (e.g. the restic nfs-restic/
# repo) makes the BackupStorageLocation "unavailable" and blocks all restores.
VELERO_PREFIX="${VELERO_PREFIX:-velero}"
AWS_REGION="${AWS_REGION:?set AWS_REGION}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY}"
VELERO_SCHEDULE="${VELERO_SCHEDULE:-0 3 * * *}"
VELERO_KEEP="${VELERO_KEEP:-4}"
VELERO_TTL="${VELERO_TTL:-720h0m0s}"
VELERO_EXCLUDE_NAMESPACES="${VELERO_EXCLUDE_NAMESPACES:-monitoring}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"

# --- velero CLI ---
if ! command -v velero >/dev/null 2>&1; then
  log "downloading velero CLI ${VELERO_VERSION}"
  TARBALL="velero-${VELERO_VERSION}-linux-amd64.tar.gz"
  curl -fsSL -o "/tmp/${TARBALL}" \
    "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/${TARBALL}" \
    || die "could not download velero ${VELERO_VERSION} (override VELERO_VERSION)"
  tar -xzf "/tmp/${TARBALL}" -C /tmp
  install -m 0755 "/tmp/velero-${VELERO_VERSION}-linux-amd64/velero" /usr/local/bin/velero
fi
log "velero: $(velero version --client-only 2>/dev/null | head -1)"

# --- credentials (written to a temp file, removed after install) ---
CREDS="$(mktemp)"; umask 077
cat > "$CREDS" <<EOF
[default]
aws_access_key_id=${AWS_ACCESS_KEY_ID}
aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}
EOF

log "installing Velero (provider aws, bucket ${VELERO_BUCKET}, region ${AWS_REGION})"
velero install \
  --provider aws \
  --plugins "velero/velero-plugin-for-aws:${VELERO_PLUGIN_AWS}" \
  --bucket "${VELERO_BUCKET}" \
  --prefix "${VELERO_PREFIX}" \
  --backup-location-config "region=${AWS_REGION}" \
  --use-volume-snapshots=false \
  --use-node-agent \
  --default-volumes-to-fs-backup \
  --secret-file "$CREDS" \
  --wait
rm -f "$CREDS"

log "waiting for the node-agent (File System Backup) to roll out"
kubectl -n velero rollout status daemonset/node-agent --timeout=300s || warn "node-agent not ready yet"

# FSB restore-helper must run as a NUMERIC non-root user, otherwise its
# 'restore-wait' init container fails on pods that set runAsNonRoot (e.g. Argo CD)
# with "image has non-numeric user (cnb), cannot verify user is non-root".
log "configuring FSB restore-helper securityContext (numeric non-root user)"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: fs-restore-action-config
  namespace: velero
  labels:
    velero.io/plugin-config: ""
    velero.io/pod-volume-restore: RestoreItemAction
data:
  secCtxRunAsUser: "1000"
  secCtxRunAsGroup: "1000"
  secCtxRunAsNonRoot: "true"
EOF

log "backup storage location status:"
velero backup-location get 2>/dev/null || true

if [[ -n "$VELERO_SCHEDULE" ]]; then
  log "creating daily backup schedule (ttl ${VELERO_TTL}, excluding: ${VELERO_EXCLUDE_NAMESPACES:-none})"
  velero schedule delete daily-all --confirm >/dev/null 2>&1 || true
  EXC=(); [[ -n "$VELERO_EXCLUDE_NAMESPACES" ]] && EXC=(--exclude-namespaces "$VELERO_EXCLUDE_NAMESPACES")
  velero schedule create daily-all --schedule "${VELERO_SCHEDULE}" --ttl "${VELERO_TTL}" \
    --default-volumes-to-fs-backup "${EXC[@]}" 2>/dev/null || warn "could not create schedule"
fi

# --- keep-last-N pruner: ALWAYS retain the newest VELERO_KEEP backups ---------
# Count-based, so an outage can't age them away; TTL above is only a 30d backstop.
log "installing Velero keep-last-${VELERO_KEEP} pruner CronJob"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: { name: velero-pruner, namespace: velero }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: velero-pruner, namespace: velero }
rules:
  - { apiGroups: ["velero.io"], resources: ["backups"], verbs: ["get","list"] }
  - { apiGroups: ["velero.io"], resources: ["deletebackuprequests"], verbs: ["create"] }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: velero-pruner, namespace: velero }
subjects: [{ kind: ServiceAccount, name: velero-pruner, namespace: velero }]
roleRef: { kind: Role, name: velero-pruner, apiGroup: rbac.authorization.k8s.io }
---
apiVersion: batch/v1
kind: CronJob
metadata: { name: velero-backup-pruner, namespace: velero }
spec:
  schedule: "45 3 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: velero-pruner
          containers:
            - name: pruner
              image: alpine/k8s:1.31.1
              env: [{ name: KEEP, value: "${VELERO_KEEP}" }]
              command: ["/bin/sh","-c"]
              args:
                - |
                  set -e
                  names=\$(kubectl get backups.velero.io -n velero -l velero.io/schedule-name=daily-all \
                    --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
                  echo "\$names" | grep -c . | xargs -I{} echo "total daily-all backups: {}"
                  echo "\$names" | head -n -\${KEEP} | while read -r b; do
                    [ -z "\$b" ] && continue
                    echo "pruning backup \$b"
                    echo "{\"apiVersion\":\"velero.io/v1\",\"kind\":\"DeleteBackupRequest\",\"metadata\":{\"generateName\":\"prune-\"},\"spec\":{\"backupName\":\"\$b\"}}" | kubectl -n velero create -f - >/dev/null
                  done
                  echo "velero prune done (kept newest \${KEEP})"
EOF

echo
log "================= VELERO READY ================="
cat <<EOF
Ad-hoc backup + restore test:
  velero backup create test-\$(date +%s) --wait
  velero backup get
  velero restore create --from-backup <name>
PV data (incl. NFS-backed PVCs) is captured via File System Backup to S3.
EOF
