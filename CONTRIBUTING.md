# Contributing to Nubo Native Platform (NNP)

Nubo Native Platform (NNP) is on a mission to democratize Cloud & AI by
providing a sovereign, adaptable and comprehensive Cloud Native Platform.
This repository — **PSC - K8S-Installation** — is part of the
**Platform Setup & Configuration (PSC)** area and provides the Kubernetes
installation and lifecycle tooling for the platform.

Contributions are welcome and greatly appreciated. NNP is released under the
**Apache 2.0 License**, and original creations contributed to this repo are
accepted under the same license.

## Before you start

Contributions should fall under one of these categories:

- Against an open **Issue**
- Against the published **Roadmap**
- An **enhancement** you are proposing

Please email **contribution@nubons.com** with your approach and the category
before you start. We respond within 5 working days; once an approach is agreed,
go ahead.

## Contribution steps

1. **Fork & clone** the repository to your local machine.
2. **Set up locally** — see the [README](README.md) for how to run and test the
   scripts. You can validate changes without a live cluster using
   `bash -n <script>` (syntax) and `./deploy.sh check` (SSH/inventory dry run).
3. **Make your change** on a branch. Keep it focused and simple.
4. **Test it** — run against a throwaway cluster (VMs or cloud instances) where
   possible, and note what you tested in the PR.
5. **Open a Pull Request** with a clear description of the change and the
   testing done.

## AI use policy

You are encouraged to use tools that help you write good code, including AI
tools. However, you must always understand and be able to explain the changes
you propose, whether or not an LLM was part of your process.

## Review process

Once a PR is submitted, maintainers run semi-automated sanity checks, then
area-owner reviews are activated. Timely responses to review comments keep
things moving. See [MAINTAINERS.md](MAINTAINERS.md) for who reviews this repo.

## Code of Conduct

All participation is governed by our [Code of Conduct](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions will be licensed under the
Apache 2.0 License.
