#!/usr/bin/env bash
# 13 — Raw NFS-export -> S3 backup. Creates a CronJob that mounts the NFS export
# read-only and `aws s3 sync`s it to an S3 bucket/prefix. This is a file-level
# copy of the whole /srv/nfs/k8s, independent of Kubernetes/Velero.
# Run once from a master.
#
# NOTE: best-effort at the file level — it cannot read another app's PRIVATE
# files (mode 0600 owned by a different UID, e.g. OpenBao's raft data); those are
# skipped (the job still succeeds). For app-consistent backups of such data use
# Velero, or the app's native snapshot (OpenBao: `bao operator raft snapshot save`).
#
#   sudo NFS_S3_BUCKET=my-bucket AWS_REGION=us-east-1 \
#        AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
#        NFS_SERVER=192.168.18.69 NFS_PATH=/srv/nfs/k8s \
#        ./scripts/13-nfs-s3-sync.sh
#
# Config via env vars:
#   NFS_S3_BUCKET         (required) target S3 bucket
#   NFS_S3_PREFIX         default nfs-backup
#   AWS_REGION            (required)
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY  (required)
#   NFS_SERVER / NFS_PATH (required) the export to back up
#   NFS_S3_SCHEDULE       default "30 3 * * *" (daily 03:30)
#   NFS_S3_NAMESPACE      default nfs-provisioner
set -euo pipefail
NFS_S3_BUCKET="${NFS_S3_BUCKET:?set NFS_S3_BUCKET}"
NFS_S3_PREFIX="${NFS_S3_PREFIX:-nfs-backup}"
AWS_REGION="${AWS_REGION:?set AWS_REGION}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY}"
NFS_SERVER="${NFS_SERVER:?set NFS_SERVER}"
NFS_PATH="${NFS_PATH:-/srv/nfs/k8s}"
NFS_S3_SCHEDULE="${NFS_S3_SCHEDULE:-30 3 * * *}"
NS="${NFS_S3_NAMESPACE:-nfs-provisioner}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "creating/updating AWS credentials secret"
kubectl -n "$NS" create secret generic nfs-s3-aws-creds \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "creating NFS->S3 sync CronJob (s3://${NFS_S3_BUCKET}/${NFS_S3_PREFIX}, schedule '${NFS_S3_SCHEDULE}')"
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
      backoffLimit: 2
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: sync
              image: amazon/aws-cli:2.17.20
              env:
                - { name: AWS_DEFAULT_REGION, value: "${AWS_REGION}" }
                - name: AWS_ACCESS_KEY_ID
                  valueFrom: { secretKeyRef: { name: nfs-s3-aws-creds, key: AWS_ACCESS_KEY_ID } }
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom: { secretKeyRef: { name: nfs-s3-aws-creds, key: AWS_SECRET_ACCESS_KEY } }
              command: ["/bin/sh","-c"]
              args:
                # aws s3 sync exits 2 when it merely SKIPS unreadable files (e.g.
                # another app's private 0600 data like OpenBao's raft files); that
                # is not a failure for a best-effort file-level backup. Only a real
                # error (exit 1) should fail the job.
                - |
                  aws s3 sync /export "s3://${NFS_S3_BUCKET}/${NFS_S3_PREFIX}/" --no-progress; rc=\$?
                  if [ "\$rc" = "0" ] || [ "\$rc" = "2" ]; then
                    echo "nfs->s3 sync done (rc=\$rc; rc=2 = some unreadable files skipped)"; exit 0
                  fi
                  echo "nfs->s3 sync FAILED (rc=\$rc)"; exit "\$rc"
              volumeMounts: [{ name: export, mountPath: /export, readOnly: true }]
          volumes:
            - name: export
              nfs: { server: "${NFS_SERVER}", path: "${NFS_PATH}", readOnly: true }
EOF

log "done. Run it now with:"
echo "  kubectl -n ${NS} create job --from=cronjob/nfs-s3-sync nfs-s3-sync-manual"
