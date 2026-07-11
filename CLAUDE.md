# CLAUDE.md

Context for Claude Code when working in this repo.

## What this is

`codebox` is a bash toolkit that provisions and manages a single GCP dev VM you connect to
from a laptop, running code-server (browser VS Code) and Claude Code. It is not an
application — it's operational tooling. See `README.md` for the full model.

## Layout

- `bin/codebox` — CLI dispatcher; each subcommand execs a script in `scripts/`.
- `scripts/lib.sh` — config loading (`codebox.env`), defaults, and gcloud helpers.
  Every other script in `scripts/` sources it.
- `scripts/*.sh` — laptop-side commands (create/start/stop/connect/ssh/status/bootstrap/destroy).
- `vm/` — files copied to and executed **on the VM** (`bootstrap.sh`, `idle-shutdown.sh`,
  `systemd/`).

## Conventions

- Laptop-side scripts assume `gcloud` and are strict bash (`set -euo pipefail`).
- All gcloud calls go through `codebox_gcloud` so they're pinned to the configured project.
- Access is IAP-only: SSH runs over `--tunnel-through-iap`; code-server is loopback-bound
  and reached via an SSH `-L` forward. Don't add rules that expose ports publicly.

## Public-repo hygiene

This repo is intended to go public. Never commit secrets or PII: no API keys, no code-server
passwords, no personal emails/names/usernames. Real config lives in `codebox.env`, which is
git-ignored — only `codebox.env.example` is tracked.
