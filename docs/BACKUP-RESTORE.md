# Backup & Restore

This cluster backs up to **AWS S3** with three complementary mechanisms. This
guide explains what each covers, the retention/cost settings, and — most
importantly — **how to restore**.

## What backs up what

| Mechanism | Backs up | Restore granularity |
|-----------|----------|---------------------|
| **Velero** (`./deploy.sh velero`) | Kubernetes resources **and** PersistentVolume data (File System Backup / kopia) | whole cluster, a namespace, or selected resources |
| **NFS → S3 sync** (`./deploy.sh nfs-s3-sync`) | raw files on the NFS export (`/srv/nfs/k8s`) | individual files/directories |
| **OpenBao raft snapshot** (manual) | OpenBao's own encrypted state | OpenBao data (its private files aren't readable by the file sync) |

> Velero is the primary DR tool. The NFS→S3 sync is a file-level safety copy.
> OpenBao must be snapshotted with its own tooling.

## Retention & cost

- **Velero**: backups expire after **15 days** (`VELERO_TTL=360h0m0s`); Velero
  deletes the expired backups' S3 objects itself. The `monitoring` namespace is
  **excluded** (`VELERO_EXCLUDE_NAMESPACES`) because the Prometheus TSDB is large
  and reproducible.
- **NFS→S3**: an S3 **lifecycle rule expires the `nfs-backup/` prefix after 3
  days**. The sync skips the transient `archived-*` copies to save space.
- **Storage class**: objects use `STANDARD`. For 3–15 day retention this is the
  cheapest option — `STANDARD_IA`/Glacier have 30/90-day *minimum-duration*
  charges that make short-lived backups **more** expensive, so don't use them
  here. (Use Glacier only for separate long-term archival copies.)
- **Bucket hardening** (applied once on the bucket):
  ```bash
  aws s3api put-public-access-block --bucket <BUCKET> \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket <BUCKET> \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
  aws s3api put-bucket-lifecycle-configuration --bucket <BUCKET> --lifecycle-configuration '{"Rules":[
    {"ID":"nfs-backup-3d","Filter":{"Prefix":"nfs-backup/"},"Status":"Enabled","Expiration":{"Days":3}},
    {"ID":"abort-mpu","Filter":{},"Status":"Enabled","AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}]}'
  ```
- The IAM key should be **S3-only**, scoped to this bucket.

Check current usage/cost:
```bash
aws s3 ls s3://<BUCKET> --recursive --summarize | tail -2   # object count + total bytes
```

---

## Restore with Velero

Run these from a master (or anywhere with `velero` + kubeconfig).

**1. See what backups exist**
```bash
velero backup get
velero backup describe <backup-name> --details
```

**2. Restore an entire backup** (e.g. after losing the cluster/namespaces)
```bash
velero restore create --from-backup <backup-name> --wait
velero restore describe <restore-name>
```

**3. Restore a single namespace**
```bash
velero restore create --from-backup <backup-name> \
  --include-namespaces <namespace> --wait
```

**4. Restore into a different namespace** (e.g. to inspect data safely)
```bash
velero restore create --from-backup <backup-name> \
  --include-namespaces app --namespace-mappings app:app-restored --wait
```

**5. Restore only specific resources**
```bash
velero restore create --from-backup <backup-name> \
  --include-resources persistentvolumeclaims,persistentvolumes,deployments --wait
```

PersistentVolume data is rehydrated automatically from S3 by the node-agent
(File System Backup) via an init container on each restored pod — no extra step.

**Verify a restore**
```bash
kubectl get pods -n <namespace>
kubectl exec -n <namespace> <pod> -- ls /your/mount   # confirm data is back
```

---

## Restore from the raw NFS→S3 copy

Use this to recover an individual file/volume directory (not a full cluster).

**1. List what's in S3**
```bash
aws s3 ls s3://<BUCKET>/nfs-backup/ --recursive
```
Each PVC is a folder named `<namespace>-<pvcname>-<pv-id>/`.

**2. Download a volume's files**
```bash
aws s3 cp "s3://<BUCKET>/nfs-backup/<namespace>-<pvc>-<pv-id>/" ./restore/ --recursive
```

**3. Put them back** — copy into the target PVC. Easiest is a helper pod that
mounts the PVC, then `kubectl cp`:
```bash
kubectl -n <ns> exec <pod-with-the-pvc> -- mkdir -p /data/restored
kubectl cp ./restore/. <ns>/<pod>:/data/restored/
```
(Remember `nfs-backup/` objects live only 3 days — restore within that window,
or rely on Velero for older recovery.)

---

## Restore OpenBao (raft snapshot)

OpenBao's data is encrypted and its files aren't readable by the file sync, so
back it up and restore it with OpenBao's own tooling.

**Take a snapshot** (store the output somewhere safe / push to S3):
```bash
kubectl -n openbao exec openbao-0 -- sh -c 'BAO_TOKEN=<root> bao operator raft snapshot save /tmp/bao.snap'
kubectl -n openbao cp openbao-0:/tmp/bao.snap ./bao.snap
```

**Restore a snapshot**:
```bash
kubectl -n openbao cp ./bao.snap openbao-0:/tmp/bao.snap
kubectl -n openbao exec openbao-0 -- sh -c 'BAO_TOKEN=<root> bao operator raft snapshot restore /tmp/bao.snap'
```
After restore, unseal the pods again (see the OpenBao section in the README).

---

## Tested

On this cluster we verified end-to-end: a Velero backup of a namespace with a
PVC, deletion of the whole namespace, then a restore — the pod came back and the
volume file was **byte-identical**. The NFS→S3 job uploads readable data to the
bucket and completes cleanly (skipping apps' private files by design).
