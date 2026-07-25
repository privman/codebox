# CLAUDE.md

Context for Claude Code when working in this repo.

## What this is

`codebox` is a bash toolkit that provisions and manages a single cloud dev VM you connect to
from a laptop, running code-server (browser VS Code) and Claude Code. It is not an
application — it's operational tooling. GCP is the only provider implemented today; the CLI
is structured so more can be added. See `README.md` for the full model.

## Layout

- `bin/codebox` — provider-agnostic CLI dispatcher. Parses a `--provider` flag (default
  `gcp`, currently the only allowed value) and execs the matching script in
  `scripts/<provider>/`.
- `scripts/gcp/lib.sh` — config loading (`codebox.env`), defaults, and gcloud helpers.
  Every other script in `scripts/gcp/` sources it.
- `scripts/gcp/*.sh` — GCP-specific commands (create/start/stop/connect/ssh/status/bootstrap/destroy).
- `vm/` — provider-agnostic files copied to and executed **on the VM** (`bootstrap.sh`,
  `idle-shutdown.sh`, `systemd/`, and the GitHub-access helpers `gh-app-token.sh`,
  `git-credential-codebox.sh`, `gh-shim.sh`, installed into `~/.local/bin`).

## Conventions

- Laptop-side scripts assume `gcloud` and are strict bash (`set -euo pipefail`).
- All gcloud calls go through `codebox_gcloud` so they're pinned to the configured project.
- Access is IAP-only: SSH runs over `--tunnel-through-iap`; code-server is loopback-bound
  and reached via an SSH `-L` forward. Don't add rules that expose ports publicly.

## Public-repo hygiene

This repo is intended to go public. Never commit secrets or PII: no API keys, no code-server
passwords, no personal emails/names/usernames. Real config lives in `codebox.env`, which is
git-ignored — only `codebox.env.example` is tracked.
