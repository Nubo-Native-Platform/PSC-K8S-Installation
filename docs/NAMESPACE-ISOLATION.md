# Namespace isolation (Istio)

How to make a namespace **unable to reach other namespaces** (for example `openbao`),
while other namespaces can still call **into** it. Works on **Flannel** — the block is
enforced by the Istio sidecar, so no NetworkPolicy-capable CNI is needed.

To let an isolated namespace reach something specific afterwards, see
[NAMESPACE-ACCESS.md](NAMESPACE-ACCESS.md).

> **Tested on:** Prod1 — Kubernetes 1.37.1, Flannel v0.28.9 (VXLAN), Istio 1.31.1 in
> sidecar mode (installed by `./deploy.sh knative`). Sections marked **(not tested)**
> were not run on a live cluster — verify them in a throwaway namespace first.

## What you get

| Direction | Result |
|-----------|--------|
| pod → same namespace | allowed |
| pod → another namespace (e.g. `openbao`) | **blocked** |
| pod → internet / external host | **blocked** (unless you allow it) |
| another namespace → this namespace | **blocked** (`AuthorizationPolicy`); open with `allow-from` |
| new pod **without** the `istio-proxy` sidecar, or with `hostNetwork` | **rejected** at creation |

It is built from four objects, all scoped to the one namespace — nothing mesh-wide,
no change to Istio, the CNI, or any other namespace:

1. namespace label `istio-injection=enabled` — pods get the `istio-proxy` sidecar
2. `Sidecar/default` with `outboundTrafficPolicy: REGISTRY_ONLY` and `egress: ["./*"]`
   — the sidecar only knows services in its own namespace, so calls elsewhere fail
3. `AuthorizationPolicy/isolation-ingress` — only the namespace itself may call into it (callers need a sidecar; unmeshed callers such as ingress-nginx or Prometheus are blocked until allowed, see NAMESPACE-ACCESS.md)
4. `ValidatingAdmissionPolicy` + binding — stops anyone skipping the sidecar
   (`sidecar.istio.io/inject: "false"`) or using `hostNetwork`

## Isolating a NEW namespace

Run on a master (or from your laptop with `deploy.sh`). `my-ns` is created if it does not exist.

```bash
# on a master
sudo ./scripts/22-namespace-isolation.sh isolate my-ns

# or from your laptop (SSHes to the first master)
./deploy.sh ns-isolation isolate my-ns
```

Preview without changing anything:

```bash
DRY_RUN=true sudo -E ./scripts/22-namespace-isolation.sh isolate my-ns
```

Check it:

```bash
sudo ./scripts/22-namespace-isolation.sh status my-ns
```

> Re-running `isolate` on a namespace **replaces** its allow list with whatever you pass
> (none, if you pass nothing). To change the list later use `allow` / `unallow`.
>
> A new namespace is **not** isolated automatically — nothing in the cluster does it for
> you. Run the command above (or put the objects in Git, see [Keeping it in Git](#keeping-it-in-git)).

### Without the script (plain kubectl)

```bash
NS=my-ns
kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace $NS istio-injection=enabled --overwrite

kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: $NS
spec:
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY
  egress:
  - hosts:
    - "./*"
EOF
```

The admission policy is optional but recommended; the script renders it for you:

```bash
DRY_RUN=true sudo -E ./scripts/22-namespace-isolation.sh isolate my-ns   # prints the exact YAML
```

## Verify it works

Use a **throwaway** namespace as the "other side" so you never touch a real one.
Replace `my-ns` with the namespace you isolated.

```bash
kubectl create namespace iso-probe
kubectl -n iso-probe run web --image=nginx --port=80 && kubectl -n iso-probe expose pod web --port=80
kubectl -n my-ns run web --image=nginx --port=80     && kubectl -n my-ns expose pod web --port=80
kubectl -n my-ns run client --image=curlimages/curl --command -- sleep 3600
kubectl -n iso-probe run client --image=curlimages/curl --command -- sleep 3600
kubectl -n my-ns wait --for=condition=Ready pod/web pod/client --timeout=120s
kubectl -n iso-probe wait --for=condition=Ready pod/web pod/client --timeout=120s
kubectl -n my-ns get pods        # READY should be 2/2
```

```bash
# a) inside my-ns            -> expect 200
kubectl -n my-ns exec client -c client -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://web.my-ns.svc.cluster.local
# b) my-ns -> other namespace -> expect 000 (blocked, curl exit 56)
kubectl -n my-ns exec client -c client -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://web.iso-probe.svc.cluster.local
# c) other namespace -> my-ns -> expect 200
kubectl -n iso-probe exec client -c client -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://web.my-ns.svc.cluster.local
```

Check at the proxy level too (needs `istioctl`): the isolated pod should not know the other namespace.

```bash
istioctl proxy-config clusters client.my-ns | grep -c iso-probe   # expect 0
istioctl proxy-config clusters client.my-ns | grep -c my-ns       # expect > 0
```

Check the admission rule:

```bash
kubectl -n my-ns run nomesh --image=nginx --annotations=sidecar.istio.io/inject=false   # expect: REJECTED
kubectl -n my-ns run meshed --image=nginx && kubectl -n my-ns get pod meshed           # expect: 2/2 Running
```

Clean up:

```bash
kubectl delete namespace iso-probe
kubectl -n my-ns delete pod web client meshed nomesh --ignore-not-found
kubectl -n my-ns delete svc web --ignore-not-found
```

> **Deleting a namespace can hang** if an aggregated API (for example Kubescape's
> `spdx.softwarecomposition.kubescape.io`) is unhealthy. If `kubectl delete namespace`
> sits in `Terminating`, check `kubectl get ns <ns> -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.message}{"\n"}{end}'`.

## Deploying apps into an isolated namespace

Your normal process (`kubectl apply`, Helm, Argo CD) is unchanged and needs no Istio
annotations — the namespace label injects the sidecar. What differs:

| Item | What to expect |
|------|----------------|
| Pods | Show `2/2` (app + `istio-proxy`). Budget a little extra CPU/memory per pod for the sidecar. |
| Logs | Two containers now: `kubectl logs <pod> -c <your-container>`. |
| Outbound calls | **Anything outside the namespace is blocked** until allowed ([NAMESPACE-ACCESS.md](NAMESPACE-ACCESS.md)). This is the usual cause of "it worked before". |
| Rejected pods | `sidecar.istio.io/inject: "false"` or `hostNetwork: true` is denied by the admission rule. |
| Inbound | Unchanged — other namespaces, ingress-nginx and Prometheus can still reach it (mesh is PERMISSIVE). |
| DNS, image pulls, volumes | Not affected (they do not go through the sidecar). |

**Before the first deploy, list what the app calls outside its namespace** (databases,
other services, external APIs, the Kubernetes API). Each one needs an explicit allow.

### Secrets: don't connect to OpenBao directly

An isolated namespace cannot reach `openbao`. Use **External Secrets Operator**
(`./deploy.sh external-secrets`): it runs in its own namespace, reads OpenBao, and creates a
normal `Secret` **inside** your namespace. Your pods just mount that Secret and need no
outbound access. Do not use the OpenBao agent-injector pattern here — it needs a direct
connection.

## Isolating an EXISTING namespace with running workloads

The script refuses by default if the namespace already has pods, because this can break
apps. Do it in this order:

1. **List what is there and how many replicas:**
   ```bash
   NS=myns
   kubectl get deploy,sts,ds,cronjob -n $NS
   kubectl get deploy,sts -n $NS -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas
   ```
   Single-replica workloads restart with downtime — schedule them.
2. **Observe first, don't block yet.** Label the namespace for injection but do **not**
   apply the `Sidecar`; restart one workload at a time and watch real traffic (Kiali
   graph; calls to unknown destinations show as `PassthroughCluster`):
   ```bash
   kubectl label namespace $NS istio-injection=enabled --overwrite
   kubectl rollout restart deploy/<name> -n $NS && kubectl rollout status deploy/<name> -n $NS
   ```
3. **Build the allow list from what you saw**, then enforce:
   ```bash
   ISOLATION_ALLOW_EXISTING=true sudo -E ./scripts/22-namespace-isolation.sh isolate $NS ns-a,ns-b
   sudo ./scripts/22-namespace-isolation.sh allow-external $NS api.example.com
   ```
4. Re-check `status`, and watch the app for timeouts for a while.

Never isolate the platform namespaces (`kube-system`, `kube-flannel`, `istio-system`,
`knative-*`, `argocd`, `openbao`, `velero`, `monitoring`, `ingress-nginx`, `cert-manager`,
`external-secrets`, `kubescape`, `headlamp`, `nfs-provisioner`, `longhorn-system`,
`default`). The script refuses them unless `ISOLATION_FORCE=true`.

## Keeping it in Git

If you deploy with Argo CD, keep the namespace, its label, the `Sidecar` and (optionally) the
admission policy together in one Git folder so a sync never removes them and a new namespace
is a copy of that folder. Generate the YAML once with `DRY_RUN=true` and commit it.

> If you later use `allow` / `unallow` on a namespace managed from Git, update the
> `Sidecar` in Git too, otherwise the next sync reverts the change.

## Limits — what this does NOT stop

Isolation is enforced by the sidecar, so it is a **soft boundary**:

- A pod that gets the `NET_ADMIN` capability (or runs privileged) can rewrite its own
  iptables rules and bypass the proxy. The admission rule only blocks the easy bypasses.
- Non-HTTP traffic that skips the proxy is not blocked at the network level.
- Flannel does **not** enforce `NetworkPolicy`, so there is no network-level fallback.
- Inbound is enforced by the destination sidecar, so a caller without a sidecar has no identity and is simply denied. This **(not tested live)** blocks the ingress controller and Prometheus too unless their namespace is meshed or you accept that.

For a **hard** boundary you need a policy-capable CNI. On Flannel the least disruptive route
is Calico policy on top of Flannel ("Canal"). That is a cluster-wide CNI change: rehearse it
on a throwaway cluster first, because the Canal manifest ships its own Flannel (an older
version than the repo installs) and must not run next to the existing `kube-flannel`
DaemonSet. Any existing `NetworkPolicy` objects (on Prod1: the Argo CD and Kiali ones) start
being enforced the moment a policy engine is installed — review them first.

## Remove isolation

Touches only that namespace; the namespace and workloads are not deleted:

```bash
sudo ./scripts/22-namespace-isolation.sh remove my-ns
```

Equivalent by hand:

```bash
kubectl delete validatingadmissionpolicybinding my-ns-require-sidecar --ignore-not-found
kubectl delete validatingadmissionpolicy my-ns-require-sidecar --ignore-not-found
kubectl -n my-ns delete serviceentry -l psc.nubo-native-platform.io/isolation=ext --ignore-not-found
kubectl -n my-ns delete sidecar default --ignore-not-found
kubectl label namespace my-ns istio-injection-
```

Running pods keep their sidecar until restarted; only the egress blocking is removed.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| App times out or resets connections to another namespace | Expected — allow it: [NAMESPACE-ACCESS.md](NAMESPACE-ACCESS.md). |
| Pod stays `1/1` (no sidecar) | Namespace label missing, or pod created before the label — `kubectl rollout restart`. |
| `pods in <ns> must run the istio-proxy sidecar` | Injection is off for that pod, or the label is missing. Fix the label; don't disable the admission rule. |
| Job/CronJob pod rejected | It had injection disabled; allow injection (Istio 1.31 uses a native sidecar so Jobs complete normally — test one before relying on it). |
| New namespace not isolated | Nothing automates it — run the `isolate` command. |
| `kubectl delete namespace` hangs in `Terminating` | An aggregated API is down (see note above). |
| Pods that call the Kubernetes API fail **(not tested)** | The `kubernetes` service lives in `default`, which an isolated namespace cannot see. Prefer not to call the API from app pods; if you must, add a `ServiceEntry` for the API server address and test it. |
