# Letting an isolated namespace reach something

A namespace isolated with [NAMESPACE-ISOLATION.md](NAMESPACE-ISOLATION.md) can only call
services in itself. This guide covers how to open **specific, deliberate** exceptions:

| You need to reach… | Use | Section |
|--------------------|-----|---------|
| Services in another namespace (e.g. a shared database) | `allow` | [1](#1-allow-another-namespace) |
| An external host (API, SaaS, package registry) | `allow-external` | [2](#2-allow-an-external-host) |
| Only ONE service in another namespace, not all of them | edit the `Sidecar` | [3](#3-allow-only-one-service) |
| Secrets stored in OpenBao | External Secrets Operator (no outbound access needed) | [4](#4-secrets-from-openbao) |
| Other namespaces calling **into** the isolated one | nothing — already allowed | [5](#5-the-other-direction-inbound) |

> **Tested on:** Prod1 — Kubernetes 1.37.1, Flannel, Istio 1.31.1. The *blocked-by-default*
> behaviour was verified live. The `allow` / `allow-external` commands below were validated
> only for the YAML they generate (against a stubbed `kubectl`) — **try each one in a
> throwaway namespace before relying on it**, and use the verification steps at the end.

## How the allow list works

The isolated namespace has one `Sidecar/default`. Its `egress.hosts` is the allow list:

```yaml
egress:
- hosts:
  - "./*"              # this namespace (always)
  - "shared-db/*"      # everything in the namespace shared-db
```

The script keeps the list of allowed namespaces in an annotation on that `Sidecar`
(`psc.nubo-native-platform.io/allowed-namespaces`) and regenerates the object every time,
so `allow` / `unallow` never lose earlier entries.

> **Important:** an allow is **namespace-wide** — it applies to **every pod** in the isolated
> namespace and to **every service** in the target namespace. You cannot give a single
> workload access with this. If you need that, give the workload its own namespace.

## 1. Allow another namespace

```bash
# on a master
sudo ./scripts/22-namespace-isolation.sh allow my-ns shared-db
sudo ./scripts/22-namespace-isolation.sh allow my-ns shared-db shared-cache   # several at once

# or from your laptop
./deploy.sh ns-isolation allow my-ns shared-db
```

You can also grant it when you isolate:

```bash
sudo ./scripts/22-namespace-isolation.sh isolate my-ns shared-db,shared-cache
```

Remove it again:

```bash
sudo ./scripts/22-namespace-isolation.sh unallow my-ns shared-db
```

Plain kubectl equivalent (replaces the whole list — include everything you want to keep):

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: my-ns
spec:
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY
  egress:
  - hosts:
    - "./*"
    - "shared-db/*"
EOF
```

Call the target by its full name from the app, e.g. `postgres.shared-db.svc.cluster.local:5432`.

> **Do not allow platform namespaces casually.** `allow my-ns openbao` gives every pod in
> `my-ns` network access to OpenBao — the exact thing isolation prevents. Prefer
> [External Secrets](#4-secrets-from-openbao).

## 2. Allow an external host

Creates a `ServiceEntry` in the isolated namespace for that one host:

```bash
sudo ./scripts/22-namespace-isolation.sh allow-external my-ns api.example.com          # port 443, TLS
sudo ./scripts/22-namespace-isolation.sh allow-external my-ns api.example.com 8443 TLS
sudo ./scripts/22-namespace-isolation.sh allow-external my-ns files.example.com 80 HTTP
```

- Protocol is `TLS` (HTTPS and anything with SNI) or `HTTP`. Other protocols (raw TCP such
  as a database port) are intentionally not generated — write and test a `ServiceEntry`
  by hand for those.
- Wildcards (`*.example.com`) are generated with `resolution: NONE` **(not tested)**; prefer
  exact hostnames.
- This allows the **hostname**, not an IP range. An app that connects by IP address will not
  match.
- If an app calls its own public URL (through the ingress), that is also an external host:
  allow that hostname.

List and remove:

```bash
sudo ./scripts/22-namespace-isolation.sh status my-ns
kubectl -n my-ns get serviceentry -l psc.nubo-native-platform.io/isolation=ext
kubectl -n my-ns delete serviceentry <name>
```

`remove my-ns` also deletes these.

## 3. Allow only ONE service

`my-ns/*` style entries allow a whole namespace. To allow a single service, put its full
host in the `Sidecar` instead of `<ns>/*`:

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: my-ns
spec:
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY
  egress:
  - hosts:
    - "./*"
    - "shared-db/postgres.shared-db.svc.cluster.local"
EOF
```

**(not tested)** — the host format is `<namespace>/<fully-qualified-service-name>`.
Two cautions:

- The script's `allow` / `unallow` **regenerate** the `Sidecar` from its namespace list and
  will **overwrite** hand-written entries like the one above. Once you hand-edit, manage that
  namespace's `Sidecar` by hand (or in Git) and stop using `allow` / `unallow` on it.
- Service-level scoping limits what the *proxy* will route; it is still a soft boundary
  (see Limits in [NAMESPACE-ISOLATION.md](NAMESPACE-ISOLATION.md)).

## 4. Secrets from OpenBao

Isolated namespaces should **not** talk to OpenBao. Let External Secrets Operator do it:

1. Put the secret in OpenBao: `bao kv put secret/myapp/db password=...`
2. Create an `ExternalSecret` **in your namespace** — ESO (running in `external-secrets`) reads
   OpenBao and creates a normal Kubernetes `Secret` in `my-ns`:

```bash
kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: db, namespace: my-ns }
spec:
  refreshInterval: 1h
  secretStoreRef: { name: openbao, kind: ClusterSecretStore }
  target: { name: db-creds, creationPolicy: Owner }
  data:
  - secretKey: password
    remoteRef: { key: myapp/db, property: password }
EOF
```

3. Mount `db-creds` in your pods. No egress rule is needed.

(Install ESO with `./deploy.sh external-secrets`.) Note the `ExternalSecret` is created by
whoever has rights in `my-ns`; the `ClusterSecretStore` decides which OpenBao paths are
readable — scope its policy accordingly.

## 5. The other direction (inbound)

Other namespaces can already call **into** an isolated namespace; nothing to configure. That
includes the ingress controller and Prometheus scraping.

To *restrict* who may call in, you would add an Istio `AuthorizationPolicy`. **(not tested)**
Caveats before doing so: only callers **with a sidecar** have a verifiable namespace
identity, so an unmeshed caller such as `ingress-nginx` would be denied by an
"allow only these namespaces" rule, and Prometheus scraping would need its namespace listed.
Test in a throwaway namespace first.

## Verify an allow

Replace `my-ns` and the target. You need a pod in the isolated namespace (a throwaway
`curlimages/curl` pod is fine; remember the pod must have the sidecar, so create it in the
isolated namespace itself):

```bash
kubectl -n my-ns run client --image=curlimages/curl --command -- sleep 3600
kubectl -n my-ns wait --for=condition=Ready pod/client --timeout=120s

# proxy-level: the sidecar should now know the target (expect > 0)
istioctl proxy-config clusters client.my-ns | grep -c shared-db

# request-level (use a real service/port in the target namespace)
kubectl -n my-ns exec client -c client -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://<service>.shared-db.svc.cluster.local:<port>

# external host
kubectl -n my-ns exec client -c client -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 https://api.example.com
```

After `unallow`, the first command should return `0` again.

`kubectl -n my-ns delete pod client` when done.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Still blocked after `allow` | The pod started before the change? The sidecar picks it up within seconds, but check `status`, and that the app uses the full name `<svc>.<ns>.svc.cluster.local`. |
| `allow` says the namespace "does not exist (yet)" | Entry is kept; it starts working once the namespace exists. Check the spelling. |
| External call fails after `allow-external` | App uses an IP not a hostname; different port; protocol is not TLS/HTTP; or the host redirects to another hostname that also needs allowing. |
| Hand-edited `Sidecar` entries disappeared | `allow` / `unallow` regenerated the object; see section 3. |
| Argo CD reverts the change | The `Sidecar` is managed from Git — change it there. |
| Need a single workload (not the whole namespace) to reach something | Give that workload its own namespace; allows are namespace-wide. |
