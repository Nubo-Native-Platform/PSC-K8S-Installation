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
| 🅰️ | **Orchestrated** — `deploy.sh` + `inventory.conf` | your laptop | describe the whole cluster in one file; it SSHes to every node for you (Ansible-style) |
| 🅱️ | **One-liner** — `k8s.sh` | each node | `curl \| sudo bash`; great for public hosting |

Both use the **same engine** (`k8s.sh`), so you can mix them.

---

## Table of contents
- [What this can do](#what-this-can-do)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [🅰️ Orchestrated setup (recommended)](#-orchestrated-setup-recommended)
- [🅱️ One-liner setup](#-one-liner-setup)
- [Choosing the Kubernetes version](#choosing-the-kubernetes-version)
- [Single vs multi-master (HA)](#single-vs-multi-master-ha)
- [Adding worker nodes later](#adding-worker-nodes-later)
- [Storage (Longhorn)](#storage-longhorn)
- [Upgrading](#upgrading)
- [Tear down / reset](#tear-down--reset)
- [Configuration reference](#configuration-reference)
- [File map](#file-map)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)
- [FAQ](#faq)

---

## What this can do

- ✅ **Install the latest Kubernetes** — or any version you pick.
- ✅ **Choose the version** — set a minor track (e.g. `1.31`) and optionally pin
  an exact patch (e.g. `1.31.2`).
- ✅ **Upgrade** an existing cluster to a newer version, control-plane-first,
  draining workers automatically (one command for the whole cluster).
- ✅ **Single-master or multi-master (HA)** — automatically decided by how many
  masters you list.
- ✅ **Easily join worker nodes** — the installer prints a ready-to-paste join
  command; or the orchestrator joins them all for you.
- ✅ **Pre-installs everything Kubernetes needs** — container runtime
  (containerd, correctly configured), kernel modules, sysctl networking, swap
  off, CNI network plugin (Flannel or Calico), and iSCSI/NFS clients.
- ✅ **Storage class out of the box** — installs **Longhorn** distributed
  storage and sets it as the default `StorageClass`.
- ✅ **Tear down** a cluster cleanly (`kubeadm reset` on every node).
- ✅ **One inventory file** holds node roles (master1, master2, worker1 …) and
  SSH details, so you never SSH manually.

### What it does **not** do (by design, to stay simple)
- ❌ Provision the servers/VMs themselves (bring your own Linux hosts).
- ❌ Set up an external load balancer or VIP for you — for HA you point it at a
  VIP/LB you provide (keepalived, HAProxy, cloud LB, etc.).
- ❌ Skip Kubernetes' rules: upgrades go **one minor at a time**.

---

## How it works

Everything is driven by one engine script, **`k8s.sh`**, which exposes small
subcommands:

| Subcommand | What it does |
|------------|--------------|
| `init` | prepares the node, runs `kubeadm init`, installs the CNI, prints join commands |
| `join` | prepares the node and joins it to the cluster (worker or extra master) |
| `token` | prints a fresh join command (run on a master) |
| `storage` | installs Longhorn + sets the default StorageClass |
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
- Ubuntu 22.04 / 24.04, or RHEL / Rocky / AlmaLinux 9 (apt or dnf).
- 2 CPU / 2 GB RAM minimum per node (more for real workloads).
- A user with `sudo`, `curl` available, and network access to each other.
- Unique hostname per node; time in sync (NTP).

**For the orchestrated setup, also on your laptop:**
- `bash`, `ssh`, `scp` (Linux, macOS, WSL, or Git Bash — **not** native
  PowerShell).
- SSH access (key recommended) to every node with password-less `sudo`.

---

## 🅰️ Orchestrated setup (recommended)

Run the entire cluster build from one machine. **You never SSH manually.**

### 1. Describe the cluster — [`inventory.conf`](inventory.conf)
```ini
[settings]
K8S_MINOR=1.31                 # Kubernetes minor track
K8S_PATCH=                     # empty = latest patch, or pin e.g. 1.31.2
CNI=flannel                    # flannel | calico
CONTROL_PLANE_ENDPOINT=        # only for HA: VIP/LB, e.g. 10.0.0.10:6443
POD_CIDR=10.244.0.0/16
LONGHORN=true                  # install Longhorn storage at the end

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

`deploy.sh` will: prep every node → `kubeadm init` the first master → install
the CNI → collect join tokens → join the other masters and all workers →
install Longhorn → print `kubectl get nodes`.

### 3. Other actions
```bash
./deploy.sh -i staging.conf     # use a different inventory file
./deploy.sh storage             # (re)install Longhorn only
./deploy.sh upgrade 1.31.2      # rolling upgrade the whole cluster
./deploy.sh reset               # tear the cluster down
```

---

## 🅱️ One-liner setup

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
  K8S_MINOR=1.31 CNI=calico HA_MODE=multi \
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
| Latest patch on a minor | `K8S_MINOR=1.31`, `K8S_PATCH=` (empty) |
| Exact pinned version | `K8S_MINOR=1.31`, `K8S_PATCH=1.31.2` |
| A different minor | change `K8S_MINOR` (e.g. `1.30`) |

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
  cloud L4 LB). This is the standard kubeadm HA requirement.

In the one-liner setup, choose it explicitly with `HA_MODE=single|multi`.

> HA needs an **odd** number of masters (1, 3, 5) so etcd can keep quorum.

---

## Adding worker nodes later

**Orchestrated:** add the node under `[workers]` in `inventory.conf`, then:
```bash
./deploy.sh              # existing nodes are already joined; new ones get joined
```

**Manual / one-liner:** join tokens expire after ~24h, so mint a fresh one on a
master:
```bash
sudo bash k8s.sh token           # prints  JOIN="kubeadm join ..."
```
Then on the new worker:
```bash
curl -sfL https://YOUR_HOST/k8s.sh | sudo JOIN="kubeadm join ..." bash -s -- join
```

---

## Storage (Longhorn)

Longhorn gives you dynamic, replicated block storage with a web UI — no cloud
disks needed.

- Installed automatically when `LONGHORN=true` (orchestrated) or via
  `k8s.sh storage`.
- Set as the **default StorageClass**, so a plain PVC just works.
- iSCSI + NFS clients are pre-installed on every node during prep (Longhorn
  needs them).

Open the UI:
```bash
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# then browse http://localhost:8080
```

Quick test that storage works:
```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: test-pvc }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
EOF
kubectl get pvc test-pvc      # should become Bound
```

---

## Upgrading

Kubernetes only supports moving **one minor at a time** (1.30 → 1.31, not
1.29 → 1.31 in one hop — run it twice). Control plane goes first.

**Orchestrated (does the whole cluster, drains each worker):**
```bash
./deploy.sh upgrade 1.31.2
```

**Manual (per node):**
```bash
sudo bash k8s.sh upgrade 1.31.2 first-master   # on the first master
sudo bash k8s.sh upgrade 1.31.2 master         # on each other master
sudo bash k8s.sh upgrade 1.31.2 worker         # on each worker
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
| `K8S_MINOR` | `1.31` | Kubernetes minor track to install |
| `K8S_PATCH` | *(empty)* | exact patch to pin; empty = latest on the minor |
| `CNI` | `flannel` | network plugin: `flannel` or `calico` |
| `HA_MODE` | auto/`single` | `single` or `multi` (orchestrated auto-detects) |
| `CONTROL_PLANE_ENDPOINT` | *(empty)* | VIP/LB `host:6443` — **required for HA** |
| `POD_CIDR` | `10.244.0.0/16` | pod network range (Calico prefers `192.168.0.0/16`) |
| `SERVICE_CIDR` | `10.96.0.0/12` | service network range |
| `APISERVER_ADVERTISE_ADDRESS` | auto | which node IP the API server advertises |
| `LONGHORN` / `LONGHORN_VERSION` | `true` / `v1.7.2` | install storage + version |
| `SSH_USER` / `SSH_KEY` / `SSH_PORT` | `ubuntu` / `~/.ssh/id_rsa` / `22` | SSH access (orchestrated only) |

---

## File map

| File | Purpose |
|------|---------|
| `deploy.sh` | 🅰️ orchestrator — builds/upgrades/resets the whole cluster over SSH |
| `inventory.conf` | 🅰️ node roles + SSH details + settings |
| `k8s.sh` | 🅱️ one-file engine (`init`/`join`/`token`/`storage`/`upgrade`) |
| `scripts/01-prereqs.sh` | modular: node prep (containerd, kube tools, sysctl, iscsi) |
| `scripts/02-init-master.sh` | modular: init first control plane + CNI |
| `scripts/03-join-node.sh` | modular: join a worker or extra master |
| `scripts/04-storage-longhorn.sh` | modular: install Longhorn |
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

- 🤝 [Contributing guide](CONTRIBUTING.md) — how to propose and submit changes
- 📜 [Code of Conduct](CODE_OF_CONDUCT.md) — CNCF Community Code of Conduct
- 🔐 [Security policy](SECURITY.md) — how to report vulnerabilities
- 👥 [Maintainers](MAINTAINERS.md)

Contact: **contribution@nubons.com**

## License

Licensed under the **Apache License 2.0** — see [LICENSE](LICENSE).
