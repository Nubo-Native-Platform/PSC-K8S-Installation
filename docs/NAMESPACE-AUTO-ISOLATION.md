# Auto-isolate new namespaces (Kyverno + Istio)

Every namespace created **after** you enable this is isolated automatically, the same way
`scripts/22-namespace-isolation.sh isolate` does it (see [NAMESPACE-ISOLATION.md](NAMESPACE-ISOLATION.md)).
Namespaces that **already exist are not touched** and keep talking to each other.

> **Status: not tested on a live cluster.** The generated YAML parses, but the Kyverno
> policies have not been run end to end. Try it on a throwaway namespace first (below).

## Enable / disable

```bash
bash deploy.sh auto-isolation install      # or on a master: sudo ./scripts/23-auto-isolation.sh install
bash deploy.sh auto-isolation status
bash deploy.sh auto-isolation remove       # stop auto-isolating; already isolated namespaces stay isolated
```

`install` installs Kyverno (own `kyverno` namespace) if missing, grants it permission to create
`Sidecar` and admission-policy objects, and creates two `ClusterPolicy` objects.

## What happens to a new namespace

| Step | Result |
|------|--------|
| `kubectl create namespace foo` (or Helm / Argo CD) | label `istio-injection=enabled` added; `Sidecar/default` (`REGISTRY_ONLY`), `AuthorizationPolicy/isolation-ingress` and the `foo-require-sidecar` admission policy + binding generated |
| pods in `foo` | get the sidecar, can only call services in `foo` |
| other namespaces → `foo` | **blocked** (generated `AuthorizationPolicy`); open with `allow-from` |
| `foo` needs another namespace / external host | `22-namespace-isolation.sh allow foo <ns>` / `allow-external` ([NAMESPACE-ACCESS.md](NAMESPACE-ACCESS.md)) |

The generated objects are created once and not kept in sync, so `allow` / `unallow` / edits stick.

## Skipping a namespace

- Create it with the label `psc.nubo-native-platform.io/isolation=off`:
  (manifest example in [Test it](#test-it)).
- Platform namespaces are always skipped: `kube-*`, `default`, `istio-system`, `argocd`, `openbao`,
  `monitoring`, `ingress-nginx`, `cert-manager`, `kyverno`, ... Add more with
  `AUTO_ISOLATION_EXCLUDE=name1,name2` when running `install`.

## Test it

```bash
# 1) isolated automatically
kubectl create namespace rabi-1663
kubectl get ns rabi-1663 --show-labels                       # istio-injection=enabled
kubectl -n rabi-1663 get sidecar default                     # exists
kubectl get validatingadmissionpolicybinding rabi-1663-require-sidecar

# 2) opted out (label must be present AT creation)
kubectl apply -f - <<'EOF2'
apiVersion: v1
kind: Namespace
metadata:
  name: rabi-1664
  labels:
    psc.nubo-native-platform.io/isolation: "off"
EOF2
kubectl -n rabi-1664 get sidecar                             # none
```

Then run the traffic checks from [NAMESPACE-ISOLATION.md](NAMESPACE-ISOLATION.md#verify-it-works).
Clean up with `kubectl delete namespace rabi-1663 rabi-1664`.

## Limits and gotchas

- The generate runs a moment **after** the namespace is created; a pod created in that gap may
  start without the sidecar. Create workloads after `kubectl get sidecar default -n <ns>` succeeds.
- Callers without a sidecar are denied inbound, including ingress-nginx and Prometheus; test before putting an app behind ingress.
- New namespaces cannot reach the Kubernetes API (`default`), OpenBao, or any other namespace until allowed.
- If Kyverno is down, new namespaces are created **without** isolation (webhook fails open).
- Same soft-boundary limits as manual isolation (Flannel does not enforce NetworkPolicy).
