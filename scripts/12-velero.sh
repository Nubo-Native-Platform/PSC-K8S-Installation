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
#   VELERO_TTL            default 360h0m0s (15d backup retention in S3)
#   VELERO_EXCLUDE_NAMESPACES  default "monitoring" (skip large/ephemeral data to
#                              save S3 cost; comma-separated)
set -euo pipefail
VELERO_VERSION="${VELERO_VERSION:-v1.16.1}"
VELERO_PLUGIN_AWS="${VELERO_PLUGIN_AWS:-v1.12.1}"
VELERO_BUCKET="${VELERO_BUCKET:?set VELERO_BUCKET}"
AWS_REGION="${AWS_REGION:?set AWS_REGION}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY}"
VELERO_SCHEDULE="${VELERO_SCHEDULE:-0 3 * * *}"
VELERO_TTL="${VELERO_TTL:-360h0m0s}"
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
  --backup-location-config "region=${AWS_REGION}" \
  --use-volume-snapshots=false \
  --use-node-agent \
  --default-volumes-to-fs-backup \
  --secret-file "$CREDS" \
  --wait
rm -f "$CREDS"

log "waiting for the node-agent (File System Backup) to roll out"
kubectl -n velero rollout status daemonset/node-agent --timeout=300s || warn "node-agent not ready yet"

log "backup storage location status:"
velero backup-location get 2>/dev/null || true

if [[ -n "$VELERO_SCHEDULE" ]]; then
  log "creating daily backup schedule (ttl ${VELERO_TTL}, excluding: ${VELERO_EXCLUDE_NAMESPACES:-none})"
  velero schedule delete daily-all --confirm >/dev/null 2>&1 || true
  EXC=(); [[ -n "$VELERO_EXCLUDE_NAMESPACES" ]] && EXC=(--exclude-namespaces "$VELERO_EXCLUDE_NAMESPACES")
  velero schedule create daily-all --schedule "${VELERO_SCHEDULE}" --ttl "${VELERO_TTL}" \
    --default-volumes-to-fs-backup "${EXC[@]}" 2>/dev/null || warn "could not create schedule"
fi

echo
log "================= VELERO READY ================="
cat <<EOF
Ad-hoc backup + restore test:
  velero backup create test-\$(date +%s) --wait
  velero backup get
  velero restore create --from-backup <name>
PV data (incl. NFS-backed PVCs) is captured via File System Backup to S3.
EOF
