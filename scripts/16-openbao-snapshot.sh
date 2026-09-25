#!/usr/bin/env bash
# 16 — Automated OpenBao raft-snapshot -> S3 (daily CronJob). Run once on a master.
#
# OpenBao's data can't be captured by Velero/restic (private, encrypted), so this
# takes a raft snapshot via the HTTP API and uploads it to s3://<bucket>/openbao/.
# The snapshot is useless without the unseal keys (kept in the DR bundle), so it is
# safe in the bucket. Snapshots are tiny; the job writes to /tmp (tmpfs) — never to
# the NFS-backed volume, which can OOM the OpenBao pods.
#
#   sudo BAO_SNAP_BUCKET=my-bucket AWS_REGION=... AWS_ACCESS_KEY_ID=... \
#        AWS_SECRET_ACCESS_KEY=... BAO_TOKEN=<root> ./scripts/16-openbao-snapshot.sh
#
# Required: BAO_SNAP_BUCKET, AWS_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY.
# BAO_TOKEN optional — falls back to root_token in /root/openbao-init.json.
# Optional: BAO_SNAP_PREFIX (openbao), BAO_SNAP_SCHEDULE ("0 2 * * *"),
#           BAO_SNAP_KEEP (4), OPENBAO_NS (openbao), BAO_ADDR.
set -euo pipefail
BAO_SNAP_BUCKET="${BAO_SNAP_BUCKET:?set BAO_SNAP_BUCKET}"
AWS_REGION="${AWS_REGION:?set AWS_REGION}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY}"
BAO_SNAP_PREFIX="${BAO_SNAP_PREFIX:-openbao}"
BAO_SNAP_SCHEDULE="${BAO_SNAP_SCHEDULE:-0 2 * * *}"
BAO_SNAP_KEEP="${BAO_SNAP_KEEP:-4}"
OPENBAO_NS="${OPENBAO_NS:-openbao}"
# Snapshots must hit the ACTIVE node. The 'openbao-active' service targets it
# directly; if your chart doesn't create it, set BAO_ADDR to the plain service and
# the job follows the 307 redirect (curl -L) to the active node.
BAO_ADDR="${BAO_ADDR:-http://openbao-active.${OPENBAO_NS}.svc:8200}"
IMAGE="${BAO_SNAP_IMAGE:-amazon/aws-cli:2.15.0}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"

BAO_TOKEN="${BAO_TOKEN:-}"
if [[ -z "$BAO_TOKEN" && -f /root/openbao-init.json ]]; then
  BAO_TOKEN="$(sed -n 's/.*"root_token"[: ]*"\([^"]*\)".*/\1/p;s/.*"initial_root_token"[: ]*"\([^"]*\)".*/\1/p' /root/openbao-init.json | head -1)"
fi
[[ -n "$BAO_TOKEN" ]] || die "no BAO_TOKEN and none found in /root/openbao-init.json"

log "storing snapshot credentials (Secret openbao-snapshot-creds in $OPENBAO_NS)"
kubectl -n "$OPENBAO_NS" create secret generic openbao-snapshot-creds \
  --from-literal=BAO_TOKEN="$BAO_TOKEN" \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "installing OpenBao snapshot CronJob (schedule '${BAO_SNAP_SCHEDULE}', keep ${BAO_SNAP_KEEP}) -> s3://${BAO_SNAP_BUCKET}/${BAO_SNAP_PREFIX}/"
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata: { name: openbao-snapshot, namespace: ${OPENBAO_NS} }
spec:
  schedule: "${BAO_SNAP_SCHEDULE}"
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
            - name: snapshot
              image: ${IMAGE}
              env:
                - { name: BAO_ADDR, value: "${BAO_ADDR}" }
                - { name: AWS_DEFAULT_REGION, value: "${AWS_REGION}" }
                - { name: BUCKET, value: "${BAO_SNAP_BUCKET}" }
                - { name: PREFIX, value: "${BAO_SNAP_PREFIX}" }
                - { name: KEEP, value: "${BAO_SNAP_KEEP}" }
                - name: BAO_TOKEN
                  valueFrom: { secretKeyRef: { name: openbao-snapshot-creds, key: BAO_TOKEN } }
                - name: AWS_ACCESS_KEY_ID
                  valueFrom: { secretKeyRef: { name: openbao-snapshot-creds, key: AWS_ACCESS_KEY_ID } }
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom: { secretKeyRef: { name: openbao-snapshot-creds, key: AWS_SECRET_ACCESS_KEY } }
              command: ["/bin/sh","-c"]
              args:
                - |
                  set -e
                  TS=\$(date -u +%Y%m%d-%H%M%S)
                  echo "taking raft snapshot from \$BAO_ADDR"
                  curl -sfL --max-time 120 -H "X-Vault-Token: \$BAO_TOKEN" \
                    "\$BAO_ADDR/v1/sys/storage/raft/snapshot" -o /tmp/bao.snap
                  SZ=\$(wc -c < /tmp/bao.snap); echo "snapshot \$SZ bytes"
                  [ "\$SZ" -gt 0 ] || { echo "empty snapshot"; exit 1; }
                  aws s3 cp /tmp/bao.snap "s3://\$BUCKET/\$PREFIX/bao-\$TS.snap"
                  aws s3 cp /tmp/bao.snap "s3://\$BUCKET/\$PREFIX/bao-latest.snap"
                  echo "pruning to newest \$KEEP"
                  aws s3 ls "s3://\$BUCKET/\$PREFIX/" | awk '/bao-[0-9]/{print \$4}' | sort \
                    | head -n -\$KEEP | while read f; do aws s3 rm "s3://\$BUCKET/\$PREFIX/\$f"; done
                  echo "openbao snapshot done"
EOF

log "running an immediate snapshot to verify"
kubectl -n "$OPENBAO_NS" delete job openbao-snapshot-now --ignore-not-found >/dev/null 2>&1
kubectl -n "$OPENBAO_NS" create job openbao-snapshot-now --from=cronjob/openbao-snapshot >/dev/null 2>&1
for i in $(seq 1 24); do
  s=$(kubectl -n "$OPENBAO_NS" get job openbao-snapshot-now -o jsonpath='{.status.succeeded}' 2>/dev/null)
  f=$(kubectl -n "$OPENBAO_NS" get job openbao-snapshot-now -o jsonpath='{.status.failed}' 2>/dev/null)
  [ "$s" = "1" ] && { log "verify snapshot SUCCEEDED"; break; }
  [ "${f:-0}" -ge 2 ] 2>/dev/null && { warn "verify snapshot FAILED:"; kubectl -n "$OPENBAO_NS" logs job/openbao-snapshot-now --tail=15; break; }
  sleep 5
done
kubectl -n "$OPENBAO_NS" delete job openbao-snapshot-now --wait=false >/dev/null 2>&1
log "OpenBao snapshots now run ${BAO_SNAP_SCHEDULE} to s3://${BAO_SNAP_BUCKET}/${BAO_SNAP_PREFIX}/"
