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

### Why keep BOTH Velero and restic (they overlap — on purpose)

Velero File System Backup and the restic NFS sync both capture PVC data (all PVCs
live on the NFS export), so they overlap. We keep both deliberately, because each
covers a gap the other has:

- **Velero FSB only backs up volumes that a *running pod has mounted.*** A
  bound-but-unmounted PVC — a scaled-to-zero app, a down StatefulSet replica, a
  Retained/released PV — is **silently skipped by Velero**. restic backs up the
  whole `/srv/nfs/k8s` export, so those are still captured. This is a correctness
  gap, not just redundancy: with Velero-only you'd discover the missing volume
  during a restore, the worst possible time.
- **restic** also gives file-level restore and an independent copy if Velero's
  metadata/repo is ever corrupt.

**Cost is negligible:** restic dedups + keeps only the last 4 snapshots (a copy
plus deltas, not 4× full copies). **For restore you use Velero alone** — it brings
the PVC object + data + wiring back in one command; restic is the fallback for the
gap cases above, not a second mandatory restore step. Velero-only is acceptable
*only* if you can guarantee every important PVC is always mounted and you never
need single-file restore — a fragile promise for a general-purpose platform, so
the default keeps both.

## Retention & cost

Retention is **count-based** ("always keep the newest N"), with a **30-day
age-based backstop**. Count-based is deliberate: an outage can't age your
backups away — you always have the last N until newer ones replace them.

- **Velero**: a pruner CronJob (`velero-backup-pruner`) **always keeps the newest
  15** daily backups (`VELERO_KEEP=15`); the schedule TTL (`VELERO_TTL=720h`, 30d)
  is only a backstop so truly abandoned backups clear after 30 days. The
  `monitoring` namespace is excluded (large/reproducible Prometheus TSDB).
- **NFS→S3**: a **restic** repository (`nfs-restic/`) with **deduplication +
  incremental** upload — keeping the newest 4 snapshots (`NFS_S3_KEEP=4`, via
  `restic forget --keep-last 4 --prune`) costs roughly one copy plus deltas, not
  4× full copies. Backups are encrypted (repo password in the
  `nfs-s3-restic-creds` Secret — **save it**, restore is impossible without it).
  No S3 lifecycle on the repo (age-expiry would corrupt it); restic's count-based
  forget is the only retention. The `archived-*` dirs are excluded.

So at any moment you have the last **15 Velero** and last **4 NFS** backups — and
if backups stop entirely, the last good ones survive up to **30 days** (then the
backstop clears them). The alerts below tell you backups have stopped.
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

### Storage tiers (why we stay on STANDARD)

Tiered transitions (STANDARD → IA → Glacier) only save money for data kept for
**months**. For short retention (7–15 days) they cost **more**, because:
- STANDARD_IA / One Zone-IA have a **30-day minimum-duration charge**, and S3
  won't even transition to them until an object is **30 days old**.
- Glacier / Glacier IR have **90-day** minimums; Deep Archive **180**.
So a 7-day object moved to Glacier is billed for 90 days. **STANDARD + expiry is
the cheapest option here** (and the data is tiny anyway). Use Glacier tiers only
for a *separate* long-term/compliance archive (e.g. a monthly backup kept a year).

### Outages

Because retention is **count-based** (keep newest N), a cluster outage does **not**
age your backups away — the last 15 Velero / last 4 NFS snapshots remain. The
**30-day backstop** only removes them if backups have been stopped that long
(both pruners and the S3 lifecycle only delete beyond the kept count, and the
lifecycle/TTL are set to 30 days). Notes:
- **No new backups are taken while down** — the `VeleroNoRecentSuccessfulBackup` /
  `NFSBackupCronStale` alerts (below) tell you backups have stopped.
- A powered-off server's **live data is intact** on boot; backups only matter if
  the primary data is actually lost.

### Alerting

`./deploy.sh backup-alerts` installs a Velero ServiceMonitor + a PrometheusRule
(`backup-alerts`) with: `VeleroNoRecentSuccessfulBackup` (no success in ~36h),
`VeleroBackupFailing`, `VeleroBackupMetricsMissing`, and `NFSBackupCronStale`.
Wire these to Sysdig/Alertmanager. Note: Velero (and the file sync) **cannot**
back up OpenBao's private files — use the OpenBao raft snapshot below.

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
(File System Backup) via a `restore-wait` init container on each restored pod.

> **Known gotcha (`runAsNonRoot` pods).** Velero's `restore-wait` helper image runs
> as a non-numeric user, so on pods that set `runAsNonRoot: true` (e.g. Argo CD)
> the init container can fail: *"image has non-numeric user (cnb), cannot verify
> user is non-root."* We ship a `fs-restore-action-config` ConfigMap that sets a
> numeric user; if a pod is still stuck in `Init:CreateContainerConfigError` after
> restore, and its blocked volume is only scratch `emptyDir` (no real data), just
> delete the stuck pods — their Deployment/StatefulSet recreates clean pods and the
> app comes up with its restored config/data:
> ```bash
> kubectl -n <ns> delete pods --all
> ```
> Verified: Argo CD recovered fully this way (Secrets + Application CRs intact).

**Verify a restore**
```bash
kubectl get pods -n <namespace>
kubectl exec -n <namespace> <pod> -- ls /your/mount   # confirm data is back
```

---

## Restore from the raw NFS→S3 copy (restic)

Use this to recover individual files/volume directories from the restic repo.
Run a `restic/restic` pod with the repo env from the `nfs-s3-restic-creds` Secret.

**1. List snapshots**
```bash
kubectl -n nfs-provisioner run restic-view -it --rm --restart=Never \
  --image=restic/restic:0.17.3 \
  --env=RESTIC_REPOSITORY=s3:s3.<region>.amazonaws.com/<BUCKET>/nfs-restic \
  --env=AWS_ACCESS_KEY_ID=... --env=AWS_SECRET_ACCESS_KEY=... --env=RESTIC_PASSWORD=... \
  --command -- restic snapshots
```
(In-cluster, pull the values from the Secret instead of typing them.)

**2. Restore files** — restic restores into a target dir; add `--include` to scope:
```bash
restic restore latest --target /restore --include '*/db.txt'
find /restore -name db.txt
```
Each PVC's data is under `/export/<namespace>-<pvcname>-<pv-id>/` in the snapshot.

**3. Put them back** into the target PVC with a helper pod + `kubectl cp`:
```bash
kubectl cp ./restore/. <ns>/<pod-with-the-pvc>:/data/
```

> Verified in a DR drill: restic restored the exact file contents from S3.
> Note it can only restore what it could read at backup time (not OpenBao's
> private files — use the OpenBao raft snapshot for those).

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

## Tested (disaster-recovery drill)

Verified end-to-end on this cluster: deployed a stateful "critical-app"
(StatefulSet, 2 replicas, a PVC each) with known data, backed it up with **both**
Velero and restic, then **destroyed the entire namespace** (pods, PVCs, PVs, data
all gone) and restored:
- **Velero restore** brought back the StatefulSet + both PVCs, and the data was
  **byte-identical** on both replicas.
- **restic restore** pulled the same files back from S3, **byte-identical**.

Also confirmed: neither Velero (node-agent) nor restic can read OpenBao's private
0600 files over the squashed NFS mount — back OpenBao up with its **raft
snapshot** (above).
