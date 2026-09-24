# Disaster Recovery — rebuild from S3 after total cluster loss

**Question this answers:** *"If my Kubernetes cluster is destroyed but S3 is intact,
can I recover everything?"* — **Yes.** Velero backups (and the restic NFS repo and
the OpenBao snapshot) live in S3, independent of the cluster. You build a fresh
cluster, point Velero at the **same bucket**, and restore.

This is application-level DR (rebuild the control plane fresh, then restore your
workloads + data) — the standard, robust model. It does **not** rely on an etcd
snapshot tied to the old nodes.

---

## What survives vs. what's lost

| | State |
|---|---|
| **In S3 (survives):** Velero backups (k8s resources + PV data), restic NFS repo, OpenBao raft snapshot (if you saved one) | recoverable |
| **Lost with the cluster:** etcd, running pods, node-local data, anything never backed up | rebuilt / restored from S3 |

## Keep these OFF the cluster — without them you CANNOT recover

Store these somewhere safe (password manager / separate vault), because they are
your only keys to the S3 data:

1. **S3 bucket name + region + AWS credentials** (S3 read/write).
2. **restic repository password** (from the `nfs-s3-restic-creds` Secret) — the
   NFS repo is encrypted; lost password = unrecoverable NFS backups.
3. **OpenBao unseal keys + root token** (`/root/openbao-init.json`) and a **raft
   snapshot** pushed to S3 — Velero/restic can't read OpenBao's private data.
4. The **inventory** (`prod1-cluster.local.conf`) so you can rebuild the same
   topology.

---

## Full recovery procedure

### 1. Build a fresh, MINIMAL cluster
Rebuild base Kubernetes + storage + Velero only — do **not** reinstall the
platform add-ons (they'll come back from the restore). In your recovery
inventory set the add-ons off, keep storage + velero on:
```ini
KNATIVE=false
KNATIVE_EVENTING=false
ARGOCD=false
OPENBAO=false
PROMETHEUS=false        # optional; it's excluded from backups anyway
STORAGE=nfs             # the default StorageClass MUST exist before restore
NFS_SETUP=true
VELERO=true
VELERO_BUCKET=<same-bucket>
AWS_REGION=<region>
AWS_ACCESS_KEY_ID=<...>
AWS_SECRET_ACCESS_KEY=<...>
```
```bash
./deploy.sh -i prod1-cluster.local.conf
```
Velero installs pointing at the **same bucket**, so it immediately sees the
existing backups. (The default `nfs-client` StorageClass must exist before you
restore PVCs — the storage step provides it.)

### 2. Confirm the backups are visible from S3
```bash
./deploy.sh -i prod1-cluster.local.conf backups
# or on a master:  velero backup get
```
You should see your daily backups (e.g. `daily-all-YYYYMMDD...`).

### 3. Restore
Restore the whole cluster's workloads from the newest backup:
```bash
./deploy.sh -i prod1-cluster.local.conf restore <backup-name>
```
or a single namespace:
```bash
./deploy.sh -i prod1-cluster.local.conf restore <backup-name> <namespace>
```
Velero recreates the resources and its node-agent rehydrates PV data from S3 via
an init container — no manual volume copy. CRDs and cluster-scoped resources that
were in the backup are recreated too.

**Order/known points**
- The **StorageClass must exist first** (step 1 provides `nfs-client`).
- Restore **CRD-based operators before their CRs** if you split restores; a
  single full-backup restore handles ordering itself.
- Namespaces come back with their Secrets/ConfigMaps intact (verified: Argo CD's
  `server.secretkey` restored byte-identical).

### 4. Restore NFS files (if needed) — restic
PV data is already restored by Velero. Use restic only to pull individual files
from the NFS repo (see [BACKUP-RESTORE.md](BACKUP-RESTORE.md#restore-from-the-raw-nfss3-copy-restic)).
Needs the **restic password**.

### 5. Restore OpenBao
OpenBao can't be captured by Velero/restic (private data). Recover it from its
**raft snapshot** and then unseal:
```bash
kubectl -n openbao cp ./bao.snap openbao-0:/tmp/bao.snap
kubectl -n openbao exec openbao-0 -- sh -c 'BAO_TOKEN=<root> bao operator raft snapshot restore /tmp/bao.snap'
# then unseal all pods (see the OpenBao section in the README)
```

### 6. Verify
```bash
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed
# spot-check app data in a restored pod
```

---

## What if you only lost the NFS server (not the whole cluster)?

Rebuild/repoint the NFS server, then:
- **Velero**-managed PVCs: the provisioner recreates the PV directories and
  Velero FSB restore repopulates them.
- **restic** files: restore from the `nfs-restic` repo in S3 (needs the password).

## What if the S3 bucket is lost too?

Then backups are gone — which is why the bucket has **versioning-independent
encryption + block-public-access**, and you should enable **cross-region
replication** or periodic copies for true off-site durability. Backups protect
against cluster loss; protect the bucket separately.

---

## Tested

A namespace-level disaster (destroying `critical-app` — a 2-replica StatefulSet
with PVCs) was fully recovered via Velero (data byte-identical) and via restic.
A real platform namespace (Argo CD) was destroyed and restored from S3 with its
Secrets and Application CRs intact. Full from-scratch cluster rebuild + restore
follows the same Velero-from-S3 path described above.
