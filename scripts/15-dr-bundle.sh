#!/usr/bin/env bash
# 15 — DR "break-glass" bundle: collect everything needed to recover from a total
# loss, encrypt it with a single passphrase, and upload to S3. Runs on a master.
#
# The bundle contains the KEYS to your S3 backups (OpenBao unseal keys + root
# token, the restic repo password), the topology (inventory), and the recovery
# runbook. It is encrypted with AES-256 (openssl, PBKDF2) using YOUR passphrase,
# so it is safe to keep in the SAME bucket as the backups: without the passphrase
# it is useless. After a disaster you only need two things off-cluster:
#   1. your AWS login (to reach the bucket)      2. this passphrase.
#
#   sudo DR_PASSPHRASE=... AWS_REGION=... AWS_ACCESS_KEY_ID=... \
#        AWS_SECRET_ACCESS_KEY=... DR_BUCKET=my-bucket \
#        INVENTORY_FILE=/tmp/inventory.conf RUNBOOK_FILE=/tmp/DISASTER-RECOVERY.md \
#        ./scripts/15-dr-bundle.sh
#
# Required env: DR_BUCKET, AWS_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
#               DR_PASSPHRASE. Optional: DR_PREFIX (default dr-bundle),
#               INVENTORY_FILE, RUNBOOK_FILE, NFS_S3_PREFIX, VELERO_PREFIX,
#               OPENBAO_NS (default openbao), NFS_NS (default nfs-provisioner).
set -euo pipefail
DR_BUCKET="${DR_BUCKET:?set DR_BUCKET}"
AWS_REGION="${AWS_REGION:?set AWS_REGION}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY}"
# DR_ENCRYPT=true -> passphrase-encrypted bundle (advanced; you keep the passphrase).
# DR_ENCRYPT=false (default, "easy mode") -> plain bundle, protected only by the
# bucket's own encryption + private/IAM access. Simpler (nothing to remember) but
# anyone who can READ the bucket also gets the recovery keys.
DR_ENCRYPT="${DR_ENCRYPT:-false}"
DR_PASSPHRASE="${DR_PASSPHRASE:-}"
[[ "$DR_ENCRYPT" == true && -z "$DR_PASSPHRASE" ]] && { echo "DR_ENCRYPT=true needs DR_PASSPHRASE" >&2; exit 1; }
DR_PREFIX="${DR_PREFIX:-dr-bundle}"
VELERO_PREFIX="${VELERO_PREFIX:-velero}"
NFS_S3_PREFIX="${NFS_S3_PREFIX:-nfs-restic}"
OPENBAO_NS="${OPENBAO_NS:-openbao}"
NFS_NS="${NFS_NS:-nfs-provisioner}"
INVENTORY_FILE="${INVENTORY_FILE:-}"
RUNBOOK_FILE="${RUNBOOK_FILE:-}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v openssl >/dev/null || die "openssl not found"
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"

WORK="$(mktemp -d)"; chmod 700 "$WORK"
BUNDLE="$WORK/dr-bundle"; mkdir -p "$BUNDLE"
cleanup(){ rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

log "collecting OpenBao unseal keys + root token"
if [[ -f /root/openbao-init.json ]]; then
  cp /root/openbao-init.json "$BUNDLE/openbao-init.json"
else
  warn "/root/openbao-init.json not found — OpenBao keys NOT in bundle (add them manually!)"
fi

log "collecting restic repository password"
if kubectl -n "$NFS_NS" get secret nfs-s3-restic-creds >/dev/null 2>&1; then
  kubectl -n "$NFS_NS" get secret nfs-s3-restic-creds -o jsonpath='{.data.RESTIC_PASSWORD}' \
    | base64 -d > "$BUNDLE/restic-password.txt"
else
  warn "restic secret not found — password NOT in bundle"
fi

[[ -n "$INVENTORY_FILE" && -f "$INVENTORY_FILE" ]] && { cp "$INVENTORY_FILE" "$BUNDLE/inventory.conf"; log "included inventory"; }
[[ -n "$RUNBOOK_FILE"  && -f "$RUNBOOK_FILE"  ]] && { cp "$RUNBOOK_FILE"  "$BUNDLE/DISASTER-RECOVERY.md"; log "included runbook"; }

cat > "$BUNDLE/MANIFEST.txt" <<EOF
PSC-K8S disaster-recovery bundle
generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

S3 bucket : ${DR_BUCKET}   region: ${AWS_REGION}
  ${VELERO_PREFIX}/       Velero backups (k8s resources + PV data)
  ${NFS_S3_PREFIX}/       restic NFS file backup (encrypted with restic-password.txt)
  openbao/                OpenBao raft snapshots
  ${DR_PREFIX}/           this encrypted bundle

Files in this bundle:
  openbao-init.json       OpenBao unseal keys + root token (unseal after snapshot restore)
  restic-password.txt     restic repo password (to read ${NFS_S3_PREFIX}/)
  inventory.conf          cluster topology to rebuild with ./deploy.sh -i
  DISASTER-RECOVERY.md    step-by-step recovery runbook

RECOVER (short form):
  1. Fresh VMs, then:  ./deploy.sh -i inventory.conf check && ./deploy.sh -i inventory.conf
     (same DR_BUCKET/region so Velero sees the backups)
  2. velero backup get ; velero restore create ... --from-backup <newest>
  3. restic restore from ${NFS_S3_PREFIX}/ using restic-password.txt
  4. OpenBao: reinstall, restore latest openbao/*.snap, unseal with openbao-init.json
  Full detail: DISASTER-RECOVERY.md
EOF

STAMP="$(date -u +%Y%m%d-%H%M%S)"
if [[ "$DR_ENCRYPT" == true ]]; then
  EXT="enc"; OUT="$WORK/dr-bundle-${STAMP}.${EXT}"
  log "encrypting bundle (AES-256, PBKDF2)"
  tar -C "$WORK" -czf - dr-bundle \
    | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:DR_PASSPHRASE > "$OUT"
else
  EXT="tar.gz"; OUT="$WORK/dr-bundle-${STAMP}.${EXT}"
  warn "EASY MODE: bundle is NOT passphrase-encrypted — protected only by the bucket's"
  warn "encryption + private/IAM access. Anyone who can READ the bucket gets these keys."
  tar -C "$WORK" -czf "$OUT" dr-bundle
fi
SIZE=$(stat -c %s "$OUT" 2>/dev/null || echo '?')
log "bundle: ${SIZE} bytes (${EXT})"

log "uploading to s3://${DR_BUCKET}/${DR_PREFIX}/"
POD="drbundle-$RANDOM"
kubectl -n "$NFS_NS" run "$POD" --restart=Never --image=amazon/aws-cli:2.15.0 \
  --env=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" --env=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --env=AWS_DEFAULT_REGION="$AWS_REGION" --command -- sleep 180 >/dev/null 2>&1
kubectl -n "$NFS_NS" wait --for=condition=Ready "pod/$POD" --timeout=90s >/dev/null 2>&1 || die "upload pod not ready"
kubectl -n "$NFS_NS" exec -i "$POD" -- aws s3 cp - "s3://${DR_BUCKET}/${DR_PREFIX}/dr-bundle-${STAMP}.${EXT}" < "$OUT" >/dev/null 2>&1 \
  || die "upload failed"
kubectl -n "$NFS_NS" exec -i "$POD" -- aws s3 cp - "s3://${DR_BUCKET}/${DR_PREFIX}/dr-bundle-latest.${EXT}" < "$OUT" >/dev/null 2>&1 || true
# prune: keep only the newest 4 timestamped bundles (of this type)
kubectl -n "$NFS_NS" exec "$POD" -- sh -c "aws s3 ls s3://${DR_BUCKET}/${DR_PREFIX}/ | awk '/dr-bundle-[0-9].*\\.${EXT}\$/{print \$4}' | sort | head -n -4 | while read f; do aws s3 rm s3://${DR_BUCKET}/${DR_PREFIX}/\$f; done" >/dev/null 2>&1 || true
kubectl -n "$NFS_NS" delete pod "$POD" --wait=false >/dev/null 2>&1

echo
log "================= DR BUNDLE STORED ================="
if [[ "$DR_ENCRYPT" == true ]]; then
cat <<EOF
Location : s3://${DR_BUCKET}/${DR_PREFIX}/dr-bundle-latest.enc
Keep OFF-CLUSTER: your AWS login + the passphrase (that is ALL you need).
Recover:  aws s3 cp s3://${DR_BUCKET}/${DR_PREFIX}/dr-bundle-latest.enc - \\
            | openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass pass:'<PASSPHRASE>' | tar -xzf -
          cat dr-bundle/MANIFEST.txt
EOF
else
cat <<EOF
Location : s3://${DR_BUCKET}/${DR_PREFIX}/dr-bundle-latest.tar.gz  (EASY MODE, not passphrase-encrypted)
Keep OFF-CLUSTER: just your AWS login — nothing to remember.
Recover:  aws s3 cp s3://${DR_BUCKET}/${DR_PREFIX}/dr-bundle-latest.tar.gz - | tar -xzf -
          cat dr-bundle/MANIFEST.txt
Upgrade to passphrase-encrypted later:  DR_ENCRYPT=true ./deploy.sh -i <inv> dr-bundle
EOF
fi
