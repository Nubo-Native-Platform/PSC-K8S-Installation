#!/usr/bin/env bash
# 13 — Raw NFS-export -> S3 backup using restic (deduplicated + incremental).
# Creates a CronJob that mounts the NFS export read-only and backs it up to a
# restic repository in S3, keeping only the last N snapshots. Because restic
# deduplicates and only uploads changed data, keeping "4 sets" costs roughly ONE
# copy plus deltas — not 4x full copies. Backups are encrypted. Run from a master.
#
# NOTE: best-effort at the file level — it cannot read another app's PRIVATE
# files (mode 0600 owned by a different UID, e.g. OpenBao's raft data); restic
# reports them as unreadable and still completes the snapshot. For app-consistent
# backups of such data use Velero, or OpenBao's `bao operator raft snapshot save`.
#
#   sudo NFS_S3_BUCKET=my-bucket AWS_REGION=us-east-1 \
#        AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
#        NFS_SERVER=192.168.18.69 NFS_PATH=/srv/nfs/k8s \
#        ./scripts/13-nfs-s3-sync.sh
#
# Config via env vars:
#   NFS_S3_BUCKET         (required) target S3 bucket
#   NFS_S3_PREFIX         default nfs-restic  (restic repo path in the bucket)
#   AWS_REGION            (required)
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY  (required)
#   NFS_SERVER / NFS_PATH (required) the export to back up
#   NFS_S3_SCHEDULE       default "30 3 * * *" (daily 03:30)
#   NFS_S3_STORAGE_CLASS  default STANDARD
#   NFS_S3_KEEP           default 4  (restic keeps the newest N snapshots)
#   RESTIC_VERSION        default 0.17.3
#   NFS_S3_NAMESPACE      default nfs-provisioner
#
# The restic repository password is generated once and stored in the
# 'nfs-s3-restic-creds' Secret. KEEP IT SAFE — without it the backups cannot be
# restored. It is reused on re-runs (never regenerated, which would orphan the repo).
set -euo pipefail
NFS_S3_BUCKET="${NFS_S3_BUCKET:?set NFS_S3_BUCKET}"
NFS_S3_PREFIX="${NFS_S3_PREFIX:-nfs-restic}"
AWS_REGION="${AWS_REGION:?set AWS_REGION}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY}"
NFS_SERVER="${NFS_SERVER:?set NFS_SERVER}"
NFS_PATH="${NFS_PATH:-/srv/nfs/k8s}"
NFS_S3_SCHEDULE="${NFS_S3_SCHEDULE:-30 3 * * *}"
NFS_S3_STORAGE_CLASS="${NFS_S3_STORAGE_CLASS:-STANDARD}"
NFS_S3_KEEP="${NFS_S3_KEEP:-4}"
RESTIC_VERSION="${RESTIC_VERSION:-0.17.3}"
NS="${NFS_S3_NAMESPACE:-nfs-provisioner}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Reuse an existing restic password (repo is unreadable if it changes); else make one.
if kubectl -n "$NS" get secret nfs-s3-restic-creds >/dev/null 2>&1; then
  log "reusing existing restic repository password (secret nfs-s3-restic-creds)"
  RPW="$(kubectl -n "$NS" get secret nfs-s3-restic-creds -o jsonpath='{.data.RESTIC_PASSWORD}' | base64 -d)"
else
  RPW="$(openssl rand -base64 24 2>/dev/null || head -c 18 /dev/urandom | base64)"
  warn "generated a new restic repository password — SAVE IT (needed to restore):"
  echo "    RESTIC_PASSWORD = ${RPW}"
fi
kubectl -n "$NS" create secret generic nfs-s3-restic-creds \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=RESTIC_PASSWORD="$RPW" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

REPO="s3:s3.${AWS_REGION}.amazonaws.com/${NFS_S3_BUCKET}/${NFS_S3_PREFIX}"
log "creating restic NFS->S3 CronJob (repo ${REPO}, keep last ${NFS_S3_KEEP}, schedule '${NFS_S3_SCHEDULE}')"
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata: { name: nfs-s3-sync, namespace: ${NS} }
spec:
  schedule: "${NFS_S3_SCHEDULE}"
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
            - name: restic
              image: restic/restic:${RESTIC_VERSION}
              env:
                - { name: AWS_DEFAULT_REGION, value: "${AWS_REGION}" }
                - { name: RESTIC_REPOSITORY, value: "${REPO}" }
                - { name: KEEP, value: "${NFS_S3_KEEP}" }
                - { name: SC, value: "${NFS_S3_STORAGE_CLASS}" }
                - name: AWS_ACCESS_KEY_ID
                  valueFrom: { secretKeyRef: { name: nfs-s3-restic-creds, key: AWS_ACCESS_KEY_ID } }
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom: { secretKeyRef: { name: nfs-s3-restic-creds, key: AWS_SECRET_ACCESS_KEY } }
                - name: RESTIC_PASSWORD
                  valueFrom: { secretKeyRef: { name: nfs-s3-restic-creds, key: RESTIC_PASSWORD } }
              command: ["/bin/sh","-c"]
              args:
                - |
                  # No 'set -e': restic exit 3 (some files unreadable, e.g. OpenBao
                  # private data) still creates a valid snapshot and must not abort.
                  restic snapshots >/dev/null 2>&1 || { echo "initializing restic repo"; restic init || exit 1; }
                  echo "backing up /export ..."
                  if restic backup /export --host nfs --tag nfs --exclude '/export/archived-*' -o s3.storage-class=\${SC}; then rc=0; else rc=\$?; fi
                  if [ "\$rc" != "0" ] && [ "\$rc" != "3" ]; then echo "restic backup FAILED (rc=\$rc)"; exit "\$rc"; fi
                  echo "pruning to newest \${KEEP} snapshots"
                  restic forget --group-by host --keep-last "\${KEEP}" --prune || exit 1
                  echo "restic backup done (kept newest \${KEEP})"
              volumeMounts: [{ name: export, mountPath: /export, readOnly: true }]
          volumes:
            - name: export
              nfs: { server: "${NFS_SERVER}", path: "${NFS_PATH}", readOnly: true }
EOF

log "done. Run it now with:"
echo "  kubectl -n ${NS} create job --from=cronjob/nfs-s3-sync nfs-s3-sync-manual"
echo "Restore: run a restic pod against ${REPO} — see docs/BACKUP-RESTORE.md."
