# PSC - K8S-Installation

> Part of **[Nubo Native Platform (NNP)](https://github.com/orgs/Nubo-Native-Platform/repositories)** ·
> Area: **Platform Setup & Configuration (PSC)** · License: **Apache-2.0**

Kubernetes installation and lifecycle tooling for the Nubo Native Platform.
A simple, self-contained toolkit to **install, grow, upgrade, and tear down**
production-style Kubernetes clusters on your own Linux servers — built on
**kubeadm + containerd**. 

It gives you two ways to work:

| | Setup | You run it from | Best for |
|---|-------|-----------------|----------|
| A | **Orchestrated** — `deploy.sh` + `inventory.conf` | your laptop | describe the whole cluster in one file; it SSHes to every node for you (Ansible-style) |
| B | **One-liner** — `k8s.sh` | each node | `curl \| sudo bash`; great for public hosting |

Both use the **same engine** (`k8s.sh`), so you can mix them.

---

## Table of contents
- [What this can do](#what-this-can-do)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Orchestrated setup (recommended)](#orchestrated-setup-recommended)
- [One-liner setup](#one-liner-setup)
- [Choosing the Kubernetes version](#choosing-the-kubernetes-version)
- [Single vs multi-master (HA)](#single-vs-multi-master-ha)
- [Adding worker nodes later](#adding-worker-nodes-later)
- [Storage (Longhorn or NFS)](#storage-longhorn-or-nfs)
- [Load balancer for HA (control-plane endpoint)](#load-balancer-for-ha-control-plane-endpoint)
- [Upgrading](#upgrading)
- [Tear down / reset](#tear-down--reset)
- [Configuration reference](#configuration-reference)
- [File map](#file-map)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)
- [FAQ](#faq)

---

## What this can do

- **Install the latest Kubernetes** — `K8S_MINOR=latest` auto-detects the
  newest stable release from upstream at install time (no need to edit anything).
- **Choose the version** — or pin a minor track (e.g. `1.36`) and optionally
  an exact patch (e.g. `1.37.0`) for reproducible builds.
- **Upgrade** an existing cluster to a newer version, control-plane-first,
  draining workers automatically (one command for the whole cluster).
- **Single-master or multi-master (HA)** — automatically decided by how many
  masters you list.
- **Easily join worker nodes** — the installer prints a ready-to-paste join
  command; or the orchestrator joins them all for you.
- **Pre-installs everything Kubernetes needs** — container runtime
  (containerd, correctly configured), kernel modules, sysctl networking, swap
  off, raised inotify limits (so logs show and pods stay Ready under load), CNI
  network plugin (Flannel or Calico), and iSCSI/NFS clients.
- **Storage class out of the box** — choose **Longhorn** (distributed
  replicated block storage on the nodes) or **NFS** (dynamic PVCs from an
  external NFS server) and it's set as the default `StorageClass`.
- **Tear down** a cluster cleanly (`kubeadm reset` on every node).
- **One inventory file** holds node roles (master1, master2, worker1 …) and
  SSH details, so you never SSH manually.

### What it does **not** do (by design, to stay simple)
- Provision the servers/VMs themselves (bring your own Linux hosts).
- Set up an external load balancer or VIP for you — for HA you point it at a
  VIP/LB you provide (keepalived, HAProxy, cloud LB, etc.).
- Skip Kubernetes' rules: upgrades go **one minor at a time**.

---

## How it works

Everything is driven by one engine script, **`k8s.sh`**, which exposes small
subcommands:

| Subcommand | What it does |
|------------|--------------|
| `init` | prepares the node, runs `kubeadm init`, installs the CNI, prints join commands |
| `join` | prepares the node and joins it to the cluster (worker or extra master) |
| `token` | prints a fresh join command (run on a master) |
| `storage` | installs storage (Longhorn or NFS) + sets the default StorageClass |
| `upgrade <ver> <role>` | upgrades this node (`first-master` / `master` / `worker`) |

The orchestrator **`deploy.sh`** simply reads `inventory.conf` and runs those
subcommands on the right nodes over SSH, in the right order.

```
                 inventory.conf  (roles + SSH)
                        │
      your laptop ──►  deploy.sh
                        │  scp k8s.sh + ssh
        ┌───────────────┼───────────────┬───────────────┐
        ▼               ▼               ▼               ▼
     master1         master2         worker1         worker2
   k8s.sh init     k8s.sh join     k8s.sh join     k8s.sh join
```

---

## Requirements

**Nodes (each server):**
- A Linux distro using `apt` or `dnf` (see the OS support box below).
- 2 CPU / 2 GB RAM minimum per node (more for real workloads).
- A user with `sudo`, `curl` available, and network access to each other.
- Unique hostname per node; time in sync (NTP).

### OS support

| OS | Package manager | Status |
|----|-----------------|--------|
| **Ubuntu 26.04 LTS** | apt | **Tested** — full HA + NFS build validated on a live 3-master + 5-worker cluster |
| Ubuntu 22.04 / 24.04 LTS | apt | Not tested — expected to work (same apt path) |
| Debian 12 / 13 | apt | Not tested — expected to work (same apt path) |
| RHEL / Rocky / AlmaLinux 9 | dnf | Not tested — expected to work (dnf path present) |

> **Only Ubuntu 26.04 has been verified end-to-end.** The other rows use the
> same apt/dnf logic and should work, but haven't been run here — treat them as
> best-effort until validated. Reports/PRs confirming other distros are welcome.

**For the orchestrated setup, also on your laptop:**
- `bash`, `ssh`, `scp` (Linux, macOS, WSL, or Git Bash — **not** native
  PowerShell).
- SSH access to every node with password-less `sudo`. Either set up keys
  yourself (`ssh-copy-id`), or let `deploy.sh` bootstrap it from passwords in the
  inventory (see [SSH bootstrap](#ssh-bootstrap-fully-automated) below) — that
  needs `sshpass` (Linux/mac/WSL) or PuTTY `plink` (Windows).

### SSH bootstrap (fully automated)

To make the whole thing a single command with nothing set up by hand, put a
password as the optional **3rd column** on each node line, and
`LB_PASSWORD`/`NFS_PASSWORD` in `[settings]`:
```ini
[masters]
master1  10.0.0.11  s3cret-pw
[workers]
worker1  10.0.0.21  s3cret-pw
```
`deploy.sh` installs your SSH public key and passwordless sudo on every host
first (`BOOTSTRAP=auto` runs it whenever any password is present), then provisions
and builds. Run just this phase with `./deploy.sh bootstrap`.

> **Never commit passwords.** Keep them in a private inventory — `*.local.conf`
> and `secrets.conf` are git-ignored. Copy the example, add passwords to the copy,
> and deploy with `-i your.local.conf`. Prefer key-based auth for anything
> long-lived; the password column is only used for this one-time bootstrap.

---

## Orchestrated setup (recommended)

Run the entire cluster build from one machine. **You never SSH manually.**

### 1. Describe the cluster — [`inventory.conf`](inventory.conf)
```ini
[settings]
K8S_MINOR=latest               # "latest" = newest stable (auto-detected), or pin e.g. 1.37
K8S_PATCH=                     # empty = latest patch, or pin e.g. 1.37.0
CNI=flannel                    # flannel | calico
CONTROL_PLANE_ENDPOINT=        # only for HA: VIP/LB, e.g. 10.0.0.10:6443

POD_CIDR=10.244.0.0/16

STORAGE=longhorn               # longhorn | nfs | none
# NFS_SERVER=10.0.0.30         # required when STORAGE=nfs
# NFS_PATH=/srv/nfs/k8s
# NFS_SC_NAME=nfs-client

SSH_USER=ubuntu                # login user (needs sudo)
SSH_KEY=~/.ssh/id_rsa          # private key (blank = agent/password)
SSH_PORT=22

[masters]
master1  10.0.0.11
# master2  10.0.0.12           # add a 2nd/3rd master => HA auto-enabled
# master3  10.0.0.13

[workers]
worker1  10.0.0.21
worker2  10.0.0.22
```

### 2. Deploy
```bash
./deploy.sh check          # test SSH + sudo on every node (do this first)
./deploy.sh                # build the ENTIRE cluster + storage
```

**One-shot, including the LB and NFS server.** For HA you need a control-plane
load balancer, and for NFS storage you need an NFS server. Rather than preparing
those by hand, declare them in the inventory and `deploy.sh` sets them up first,
then builds the cluster — all from the single `./deploy.sh` command:
```ini
LB_HOST=192.168.18.51      # auto-install HAProxy here; endpoint = LB_HOST:6443
LB_SSH_USER=debian         # if the LB host uses a different SSH user
STORAGE=nfs
NFS_SERVER=192.168.18.69
NFS_SETUP=true             # auto-install the NFS server on NFS_SERVER
NFS_CIDR=192.168.18.0/24
```
(You can also run just the infra step with `./deploy.sh provision`.) See the
ready-made [`prod1-cluster.conf`](prod1-cluster.conf) for a full 3-master +
5-worker + NFS example.

`deploy.sh` will: prep every node → `kubeadm init` the first master → install
the CNI → collect join tokens → join the other masters and all workers →
install storage (Longhorn or NFS) → print `kubectl get nodes` → **fetch the
admin kubeconfig to `./kubeconfig`** on your machine (unless
`FETCH_KUBECONFIG=false`).

Use it right away:
```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes
```
Re-fetch it any time with `./deploy.sh kubeconfig`. (It contains cluster-admin
credentials and is git-ignored — keep it safe.)

### 3. Other actions
```bash
./deploy.sh -i staging.conf     # use a different inventory file
./deploy.sh bootstrap           # install SSH keys + passwordless sudo (from passwords)
./deploy.sh provision           # set up the LB and/or NFS server only
./deploy.sh add-worker w6 IP    # join ONE new worker to the existing cluster
./deploy.sh remove-worker NODE  # drain + remove a worker from the cluster
./deploy.sh storage             # (re)install storage only
./deploy.sh kubeconfig          # fetch admin kubeconfig to ./kubeconfig
./deploy.sh upgrade 1.37.0      # rolling upgrade the whole cluster
./deploy.sh reset               # tear the cluster down
```

---

## One-liner setup

For per-node installs or when you host `k8s.sh` at a public URL. Edit the
`SELF_URL=` line near the bottom of `k8s.sh` to your hosting URL first.

```bash
# 1) First master — installs control plane + CNI, prints the worker join line
curl -sfL https://YOUR_HOST/k8s.sh | sudo bash -s -- init

# 2) Each worker — paste the JOIN=... the master printed
curl -sfL https://YOUR_HOST/k8s.sh | sudo JOIN="kubeadm join ..." bash -s -- join

# 3) Storage — once, on a master
curl -sfL https://YOUR_HOST/k8s.sh | sudo bash -s -- storage
```

Configure with env vars (no files to edit):
```bash
curl -sfL https://YOUR_HOST/k8s.sh | sudo \
  K8S_MINOR=latest CNI=calico HA_MODE=multi \
  CONTROL_PLANE_ENDPOINT=10.0.0.10:6443 \
  bash -s -- init
```

There is also a **numbered modular version** in [`scripts/`](scripts/) (one
file per step with a shared `config/cluster.env`) if you prefer editable,
separate scripts over a single file.

---

## Choosing the Kubernetes version

| Goal | Set |
|------|-----|
| **Absolute latest stable** (auto) | `K8S_MINOR=latest`, `K8S_PATCH=` (empty) |
| Latest patch on a chosen minor | `K8S_MINOR=1.36`, `K8S_PATCH=` (empty) |
| Exact pinned version | `K8S_MINOR=1.37`, `K8S_PATCH=1.37.0` |
| A different minor | change `K8S_MINOR` (e.g. `1.35`) |

With `K8S_MINOR=latest`, the installer reads
`https://dl.k8s.io/release/stable.txt` at install time and installs whatever the
newest stable minor is (e.g. `v1.37.0` → the `1.37` track). The orchestrator
resolves it **once** on your machine so every node gets the same version. Pin a
minor for reproducible builds or air-gapped mirrors.

List what's installable:
```bash
./scripts/list-versions.sh          # patches on the configured minor
./scripts/list-versions.sh 1.30     # any minor track
```

---

## Single vs multi-master (HA)

**It is automatic in the orchestrated setup** — decided by how many masters you
list in `inventory.conf`:

- **1 master** → single control plane (simplest; fine for dev/small prod).
- **2+ masters** → HA (stacked etcd). You must set `CONTROL_PLANE_ENDPOINT` to
  a **VIP or load balancer** that fronts all masters (keepalived, HAProxy, or a
  cloud L4 LB). This is the standard kubeadm HA requirement. If you don't have
  one, [`scripts/lb-haproxy-setup.sh`](scripts/lb-haproxy-setup.sh) stands up
  HAProxy on a spare host in one command (see the next section).

In the one-liner setup, choose it explicitly with `HA_MODE=single|multi`.

> HA needs an **odd** number of masters (1, 3, 5) so etcd can keep quorum.

**Masters run control-plane components only.** kubeadm taints every control-plane
node with `node-role.kubernetes.io/control-plane:NoSchedule`, so the scheduler
keeps your application pods off the masters — they land on the workers. Only
required system pods that tolerate the taint (etcd, API server, controller
manager, scheduler, kube-proxy, and the CNI DaemonSet) run on masters. Don't add
a blanket toleration for that taint to app workloads if you want to preserve
this separation.
> **3 masters is the typical HA size** and is what the bundled
> [`prod1-cluster.conf`](prod1-cluster.conf) example uses (3 masters + 5 workers).

---

## Load balancer for HA (control-plane endpoint)

With 2+ masters, kubeadm requires a single, stable address that fronts all
control-plane nodes' `:6443`. Every node and every `kubectl` talks to this one
endpoint, and it must keep working if a master goes down.

**Quick option (lab/test) — HAProxy on a dedicated proxy host** (not a master,
and not the NFS/file server — keep roles separate):
```bash
# on the proxy host (must NOT be one of the masters):
sudo ./scripts/lb-haproxy-setup.sh 192.168.18.61 192.168.18.62 192.168.18.63
# it prints the endpoint, e.g. 192.168.18.51:6443
```
Then set that in your inventory before deploying:
```ini
CONTROL_PLANE_ENDPOINT=192.168.18.51:6443
```
> Backends show **DOWN** until the first master finishes `kubeadm init` — that's
> expected. A single HAProxy host is itself a single point of failure.

**Production option — keepalived VIP + HAProxy on 2+ hosts.** Run HAProxy on
multiple hosts and share a floating **virtual IP** with keepalived, then point
`CONTROL_PLANE_ENDPOINT` at the VIP. This removes the LB as a single point of
failure. (Cloud users: use a managed L4 load balancer instead.)

---

## Adding worker nodes later

You can grow the cluster any time. Do **not** re-run the full `./deploy.sh` to add
a node — that re-runs `kubeadm init` on the first master. Use the targeted
`add-worker` action, which only touches the new node.

**Orchestrated (recommended):** from your machine, one command per new node:
```bash
./deploy.sh add-worker worker6 10.0.0.26            # key-based access already set up
./deploy.sh add-worker worker6 10.0.0.26 's3cret'   # or bootstrap it with a password
```
It mints a fresh join token on the first master, preps the new node (containerd,
kube tools, NFS client), and joins it as a worker. Optionally also add the node
under `[workers]` in your inventory to keep the file accurate for future
upgrades. Extra nodes automatically get NFS storage (they mount the same NFS
StorageClass) — no storage step needed.

**Manual / one-liner:** join tokens expire after ~24h, so mint a fresh one on a
master:
```bash
sudo bash k8s.sh token           # prints  JOIN="kubeadm join ..."
```
Then on the new worker:
```bash
curl -sfL https://YOUR_HOST/k8s.sh | sudo JOIN="kubeadm join ..." bash -s -- join
```

> Adding an extra **control-plane** node (master) is also possible but needs the
> upload-certs certificate key and your LB to include it; that's an advanced,
> less-common operation — open an issue if you need a scripted path for it.

### Removing a worker

To retire a node safely (evict its pods first, then remove it):
```bash
./deploy.sh remove-worker <node-name>          # drain + delete from the cluster
./deploy.sh remove-worker <node-name> 10.0.0.26 # also 'kubeadm reset' the machine
```
`<node-name>` is the Kubernetes node name shown by `kubectl get nodes` (the
host's hostname, e.g. `prod1-k8s-worker6`). It cordons and drains the node
(`--ignore-daemonsets --delete-emptydir-data`), deletes it from the API, and —
if you pass the IP — resets kubeadm on the machine so it's clean for reuse. You
are asked to confirm by typing the node name.

> Any PVCs whose pods were on that node re-attach elsewhere automatically because
> the data lives on the NFS server, not the node.

---

## Storage (Longhorn or NFS)

Pick **one** backend with `STORAGE=longhorn | nfs | none`. Whichever you choose
is installed at the end of the build and set as the **default StorageClass**, so
a plain PVC just works. iSCSI + NFS clients are pre-installed on every node
during prep, so both backends are ready to go.

> Only one runs at a time. This project's test cluster uses **NFS**; Longhorn is
> documented and fully supported too — just set `STORAGE=longhorn`.

### Option A — Longhorn (distributed block storage)

Longhorn gives you dynamic, replicated block storage with a web UI — no cloud
disks and no separate storage server needed (data lives on the nodes).

- `STORAGE=longhorn` (orchestrated) or `sudo bash k8s.sh storage` with
  `STORAGE=longhorn` (default).
- Version via `LONGHORN_VERSION` (default `v1.10.0`).

Open the UI:
```bash
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# then browse http://localhost:8080
```

### Option B — NFS (external NFS server)

Best when you already have (or want) a central file server. PVCs are dynamically
provisioned as subdirectories on one NFS export by the CNCF/SIG-Storage
[`nfs-subdir-external-provisioner`](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner).
No per-node disks are consumed — all data lives on the NFS server. (Note: NFS is
`ReadWriteMany`-capable but is a single point of failure unless the server
itself is made HA.)

**1) Prepare the NFS server** (run on the file server, e.g. `192.168.18.69`):
```bash
sudo NFS_CIDR=192.168.18.0/24 ./scripts/nfs-server-setup.sh
# installs nfs-kernel-server, creates /srv/nfs/k8s, exports it to the network,
# and opens the firewall.
```

**2) Point the cluster at it.** Orchestrated — in your inventory:
```ini
STORAGE=nfs
NFS_SERVER=192.168.18.69
NFS_PATH=/srv/nfs/k8s
NFS_SC_NAME=nfs-client
```
then `./deploy.sh` (or `./deploy.sh storage` to (re)install storage only).

One-liner / per-node engine — on a master:
```bash
sudo STORAGE=nfs NFS_SERVER=192.168.18.69 NFS_PATH=/srv/nfs/k8s \
  bash k8s.sh storage
```
Modular scripts — on a master:
```bash
sudo NFS_SERVER=192.168.18.69 NFS_PATH=/srv/nfs/k8s ./scripts/04b-storage-nfs.sh
```

### Quick test (either backend)

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: test-pvc }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
EOF
kubectl get pvc test-pvc      # should become Bound (uses the default StorageClass)
```

---

## Upgrading

Kubernetes only supports moving **one minor at a time** (1.36 → 1.37, not
1.35 → 1.37 in one hop — run it twice). Control plane goes first.

**Orchestrated (does the whole cluster, drains each worker):**
```bash
./deploy.sh upgrade 1.37.0
```

**Manual (per node):**
```bash
sudo bash k8s.sh upgrade 1.37.0 first-master   # on the first master
sudo bash k8s.sh upgrade 1.37.0 master         # on each other master
sudo bash k8s.sh upgrade 1.37.0 worker         # on each worker
```
Afterwards, update `K8S_MINOR`/`K8S_PATCH` in your config so new nodes match.

---

## Tear down / reset

Destroys Kubernetes on every node (does not delete the servers):
```bash
./deploy.sh reset          # asks you to type DESTROY to confirm
```
Manual per node: `sudo kubeadm reset -f`.

---

## Configuration reference

Used by both `inventory.conf` (`[settings]`) and the one-liner (env vars):

| Key | Default | Meaning |
|-----|---------|---------|
| `K8S_MINOR` | `latest` | `latest` = auto-detect newest stable; or pin a minor (e.g. `1.37`) |
| `K8S_PATCH` | *(empty)* | exact patch to pin; empty = latest on the minor |
| `CNI` | `flannel` | network plugin: `flannel` or `calico` |
| `HA_MODE` | auto/`single` | `single` or `multi` (orchestrated auto-detects) |
| `CONTROL_PLANE_ENDPOINT` | *(empty)* | VIP/LB `host:6443` — **required for HA** |
| `POD_CIDR` | `10.244.0.0/16` | pod network range (Calico prefers `192.168.0.0/16`) |
| `SERVICE_CIDR` | `10.96.0.0/12` | service network range |
| `MAX_PODS` | `110` | kubelet max pods per node (keep ≤250 with a `/24` podCIDR) |
| `INOTIFY_MAX_USER_INSTANCES` | `8192` | inotify instances/node (kernel default 128 is too low) |
| `INOTIFY_MAX_USER_WATCHES` | `1048576` | inotify watches/node |
| `APISERVER_ADVERTISE_ADDRESS` | auto | which node IP the API server advertises |
| `STORAGE` | `longhorn` | storage backend: `longhorn`, `nfs`, or `none` |
| `LONGHORN_VERSION` | `v1.10.0` | Longhorn version (when `STORAGE=longhorn`) |
| `NFS_SERVER` | *(empty)* | NFS server IP/host — **required when `STORAGE=nfs`** |
| `NFS_PATH` | `/srv/nfs/k8s` | exported directory on the NFS server |
| `NFS_SC_NAME` | `nfs-client` | StorageClass name to create (NFS) |
| `NFS_SETUP` | `false` | `true` = `deploy.sh` sets up the NFS server on `NFS_SERVER` automatically |
| `NFS_CIDR` | auto | network allowed to mount the NFS export (e.g. `192.168.18.0/24`) |
| `NFS_SSH_USER` | `SSH_USER` | SSH user for the NFS host (if different) |
| `LB_HOST` | *(empty)* | host to auto-provision HAProxy on for HA; endpoint becomes `LB_HOST:6443` |
| `LB_SSH_USER` | `SSH_USER` | SSH user for the LB host (e.g. `debian` on a Debian proxy) |
| `BOOTSTRAP` | `auto` | `auto`=bootstrap SSH keys+sudo if any password is set; `true`/`false` to force |
| `LB_PASSWORD` / `NFS_PASSWORD` | *(empty)* | bootstrap passwords for the LB / NFS hosts (keep in a private inventory) |
| `FETCH_KUBECONFIG` | `true` | after install, copy the admin kubeconfig to `./kubeconfig` (`false` = don't) |
| `SSH_USER` / `SSH_KEY` / `SSH_PORT` | `ubuntu` / `~/.ssh/id_rsa` / `22` | SSH access (orchestrated only) |

> **Back-compat:** the old `LONGHORN=true/false` key still works — if `STORAGE`
> is not set, `LONGHORN=true` maps to `STORAGE=longhorn` and `false` to `none`.

---

## File map

| File | Purpose |
|------|---------|
| `deploy.sh` | A orchestrator — builds/upgrades/resets the whole cluster over SSH |
| `inventory.conf` | A node roles + SSH details + settings (generic example) |
| `prod1-cluster.conf` | A ready-to-run example: 3 masters + 5 workers + NFS |
| `k8s.sh` | B one-file engine (`init`/`join`/`token`/`storage`/`upgrade`) |
| `scripts/01-prereqs.sh` | modular: node prep (containerd, kube tools, sysctl, iscsi/nfs) |
| `scripts/02-init-master.sh` | modular: init first control plane + CNI |
| `scripts/03-join-node.sh` | modular: join a worker or extra master |
| `scripts/04-storage-longhorn.sh` | modular: install Longhorn |
| `scripts/04b-storage-nfs.sh` | modular: install NFS provisioner + StorageClass |
| `scripts/nfs-server-setup.sh` | set up the external NFS server (run on the file server) |
| `scripts/lb-haproxy-setup.sh` | stand up an HAProxy control-plane LB for HA |
| `scripts/05-upgrade.sh` | modular: per-node upgrade |
| `scripts/list-versions.sh` | list installable Kubernetes versions |
| `scripts/lib.sh` / `config/cluster.env` | shared helpers / config for the modular scripts |

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `deploy.sh check` FAILs | verify `SSH_USER`, `SSH_KEY`, and that the user has `sudo` on the node |
| Nodes stay `NotReady` | CNI still starting — `kubectl -n kube-system get pods`; wait or check CNI logs |
| Calico pods crashloop | `POD_CIDR` must be `192.168.0.0/16` for Calico's default config |
| Worker join fails “token expired” | run `sudo bash k8s.sh token` on a master for a fresh command |
| `swap` / preflight errors | prep disables swap; re-run `k8s.sh` prep, or check `/etc/fstab` |
| Longhorn PVC stuck `Pending` | ensure `open-iscsi`/`iscsid` is running on every node (prep installs it) |
| `kubectl logs` empty / pods stuck not-Ready with "too many open files" | inotify exhaustion — prep raises `fs.inotify.max_user_instances` to 8192 (kernel default 128 is too low). On an already-running node: `sudo sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288` |
| `kubectl` from laptop | `scp master:/etc/kubernetes/admin.conf ~/.kube/config` then edit the server IP |

Useful checks:
```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl -n longhorn-system get pods
journalctl -u kubelet -f
```

---

## Security notes

- `curl | sudo bash` runs remote code as **root**. Host `k8s.sh` over **HTTPS**,
  and tell users to inspect first: `curl -sfL https://YOUR_HOST/k8s.sh | less`.
  For stronger trust, pin a release tag and publish a **SHA256** checksum.
- The orchestrator needs SSH + sudo to every node — use **key-based** auth and
  restrict who can read `inventory.conf` (it contains your topology).
- Longhorn's UI has no auth by default — keep it behind `port-forward` or add an
  ingress with authentication before exposing it.

---

## FAQ

**Does it install the newest Kubernetes?**  Yes — leave `K8S_PATCH` empty and it
takes the latest patch on the `K8S_MINOR` track. Set `K8S_MINOR` to the newest
minor for the absolute latest.

**Can I go from single-master to multi-master later?**  Yes — put a VIP/LB in
front, set `CONTROL_PLANE_ENDPOINT`, add masters to the inventory, and join
them. (Best planned up front; converting a live single-master cluster needs
care.)

**Flannel or Calico?**  Flannel is the simplest (default). Choose Calico if you
need NetworkPolicies/advanced networking — remember to use its `POD_CIDR`.

**Windows?**  The nodes are Linux. Run `deploy.sh` from WSL/Git Bash/macOS/Linux
(it needs `ssh`/`scp`), not native PowerShell.

**Is this production-grade?**  It uses upstream kubeadm the standard way, so the
cluster is legitimate. For real production also plan: an HA load balancer, etcd
backups, monitoring, and an ingress controller (easy to add on top).

---

## Community & contributing

This repository is maintained as part of the Nubo Native Platform.

- [Contributing guide](CONTRIBUTING.md) — how to propose and submit changes
- [Code of Conduct](CODE_OF_CONDUCT.md) — CNCF Community Code of Conduct
- [Security policy](SECURITY.md) — how to report vulnerabilities
- [Maintainers](MAINTAINERS.md)

Contact: **contribution@nubons.com**

## License

Licensed under the **Apache License 2.0** — see [LICENSE](LICENSE).
