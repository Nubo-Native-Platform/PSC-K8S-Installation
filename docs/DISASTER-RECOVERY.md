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

## The recovery model: rebuild the platform from code, restore your data from S3

This is the single most important idea, and it was **proven in a full total-loss
drill** (see [Tested](#tested)):

- **Platform / infrastructure = rebuilt from code** (this repo): Kubernetes itself,
  the CNI, storage class, and the *operators* — Istio, Knative, Prometheus,
  metrics-server, VPA, and the Argo CD / OpenBao **installs**. These are stateless
  and reproducible; `deploy.sh` recreates them identically from pinned versions.
- **Your data = restored from S3**: every **application namespace** (Deployments,
  StatefulSets, ConfigMaps, Secrets, and **PVC data**), plus Argo CD's config and
  OpenBao's secrets.

**Why not restore the platform operators from Velero too?** Because it's fragile:
operators carry cluster-scoped CRDs, webhooks and admission configs that conflict
on restore. Worse, **Velero only auto-includes a CRD in a backup if a live custom
resource of that type exists** — e.g. if you had no `Application` objects, the
`applications.argoproj.io` CRD is *not in the backup*, and restoring Argo CD from
S3 leaves its server crash-looping. Reinstalling the operator from code brings the
correct CRDs; then you restore your CRs/data on top. (Verified: this is exactly
what failed and how it was fixed in the drill.)

---

## Full recovery procedure

### 1. Rebuild the full cluster from code
Run the normal one-shot build against your recovery inventory. This recreates the
base cluster + storage + Velero **and** the platform operators (Istio, Knative,
Prometheus, Argo CD, OpenBao) fresh:
```ini
STORAGE=nfs             # the default StorageClass MUST exist before restore
NFS_SETUP=true
VELERO=true
VELERO_BUCKET=<same-bucket>   # SAME bucket as before — Velero then sees old backups
VELERO_PREFIX=velero
AWS_REGION=<region>
AWS_ACCESS_KEY_ID=<...>
AWS_SECRET_ACCESS_KEY=<...>
```
```bash
./deploy.sh -i prod1-cluster.local.conf check     # verify SSH+sudo on fresh VMs
./deploy.sh -i prod1-cluster.local.conf           # build everything
```
If a node aborts on a dpkg lock (`unattended-upgrades` on a fresh VM), it now
waits for the lock automatically; just re-run. Velero comes up pointing at the
**same bucket + `velero/` prefix**, so it immediately lists the existing backups.

### 2. Confirm the backups are visible from S3
```bash
./deploy.sh -i prod1-cluster.local.conf backups
# or on a master:  velero backup get
```
You should see your daily backups (e.g. `daily-all-YYYYMMDD...`) — proof the fresh
cluster can read the old S3 data.

### 3. Restore your application namespaces from S3
One command brings back **all** your app namespaces + PVC data, skipping the
platform/system namespaces you just rebuilt from code (avoids operator/CRD
conflicts):
```bash
velero restore create full-dr --from-backup <backup-name> \
  --exclude-namespaces kube-system,kube-public,kube-node-lease,kube-flannel,velero,nfs-provisioner,istio-system,knative-serving,knative-eventing,monitoring \
  --wait
```
or restore one namespace (helper wrapper):
```bash
./deploy.sh -i prod1-cluster.local.conf restore <backup-name> <namespace>
```
Velero recreates the resources and its node-agent rehydrates PV data from S3 via a
`restore-wait` init container — no manual volume copy.

**Known points**
- The **StorageClass must exist first** (step 1 provides `nfs-client`).
- **`--include-namespaces <ns>` restores only namespaced objects — it SKIPS
  cluster-scoped resources** (CRDs, ClusterRoles). For operators you rebuild from
  code that's fine; if you ever need a CRD from a backup, add
  `--include-cluster-resources=true`.
- **`runAsNonRoot` pods** (e.g. Argo CD): Velero's `restore-wait` helper can get
  stuck in `Init:CreateContainerConfigError`. We ship a `fs-restore-action-config`
  ConfigMap for it; if a pod is still stuck and its blocked volume is only scratch
  `emptyDir`, delete the stuck pods so their controller recreates them clean —
  their restored config/data is already in place. If the Velero restore controller
  itself wedges on those, clear the stuck restore's finalizers and restart the
  `velero` deployment.
- Namespaces come back with Secrets/ConfigMaps intact (verified: Argo CD's
  `server.secretkey` restored byte-identical).

### 4. Restore NFS files (if needed) — restic
PV data is already restored by Velero. Use restic only to pull individual files
from the NFS repo (see [BACKUP-RESTORE.md](BACKUP-RESTORE.md#restore-from-the-raw-nfss3-copy-restic)).
Needs the **restic password**.

### 5. Restore OpenBao
OpenBao can't be captured by Velero/restic (private data). `deploy.sh` reinstalled
a **fresh** OpenBao in step 1; now restore your old state into it from the raft
snapshot in S3, then unseal with your **OLD** keys.
```bash
# download the snapshot from S3, copy it into the pod, restore with the CURRENT
# (fresh-install) root token — restore replaces all data incl. the old seal config:
kubectl -n openbao cp ./bao.snap openbao-0:/tmp/bao.snap
kubectl -n openbao exec openbao-0 -- sh -c 'BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=<fresh-root> bao operator raft snapshot restore -force /tmp/bao.snap'
# OpenBao now SEALS (it adopted the old seal). Unseal every pod with the OLD unseal
# keys you kept off-cluster, then log in with the OLD root token:
kubectl -n openbao exec openbao-<n> -- bao operator unseal <OLD_UNSEAL_KEY>   # x3 keys, each pod
```
**Gotchas proven in the drill:**
- **Take/copy snapshots via `/tmp` (tmpfs) inside the pod, never the NFS-backed
  data volume** — writing a snapshot to the NFS home dir spiked memory and
  OOM-killed the OpenBao pods, losing quorum.
- After restore the pods are **sealed** and only the **OLD** unseal keys work
  (that's why they must be off-cluster — see above).

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
