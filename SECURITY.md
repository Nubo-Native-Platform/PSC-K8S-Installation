# Security Policy

## Reporting a vulnerability

If you discover a security issue in this repository, please **do not open a
public issue**. Instead, email **contribution@nubons.com** with:

- a description of the issue and its impact,
- steps to reproduce, and
- any suggested remediation.

We aim to acknowledge reports within 5 working days and will coordinate a fix
and disclosure timeline with you.

## Scope notes for this repo

These scripts install and manage Kubernetes and are typically run with `sudo`
or over SSH as a privileged user. When using them:

- Host and fetch `k8s.sh` over **HTTPS** only; inspect before piping to a shell
  (`curl -sfL <url> | less`).
- Protect `inventory.conf` — it describes your cluster topology and SSH access.
- Longhorn's UI ships without authentication; keep it behind `port-forward` or
  an authenticated ingress.

See the [README](README.md) Security notes section for details.
