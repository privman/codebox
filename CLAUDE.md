# CLAUDE.md

Context for Claude Code when working in this repo.

## What this is

`codebox` is a bash toolkit that provisions and manages a single dev box you connect to from
a laptop, running code-server (browser VS Code) and Claude Code. It is not an application —
it's operational tooling. Two providers: `docker` (a container on the machine you are
sitting at — the default) and `gcp` (a cloud VM behind an IAP tunnel). The docker provider
can put the project folder on a host directory instead of cloning into the box:
`CODEBOX_DOCKER_SHARED_DIR` (codebox creates it, the agent owns it, you get read/write via a
POSIX default ACL — this is the one that works under the uid split) or
`CODEBOX_DOCKER_MOUNT` (adopt an existing directory as-is, single uid only). See `README.md`
for the full model.

## Layout

- `bin/codebox` — provider-agnostic CLI dispatcher. Resolves the provider (`--provider`
  flag, else `CODEBOX_PROVIDER` from the config, else `docker`) and execs the matching
  script in `scripts/<provider>/`.
- `scripts/env-file.sh` — which `codebox.env` applies. Split out of `common.sh` because the
  dispatcher needs it *before* it can pick a provider (the provider can be set in the
  config), and sourcing `common.sh` that early would load a provider's world too soon. One
  copy, two callers, so they can never disagree about which config is in play.
- `scripts/common.sh` — provider-agnostic config loading (`codebox.env`), shared defaults,
  logging and validation. Also per-box resolution: `CODEBOX_BOX_<name>_<KEY>` overrides
  `CODEBOX_<KEY>` when `--box <name>` is given. The file is *sourced*, so it must stay
  valid bash — no section headers. Sourced by each provider's `lib.sh`. Anything only one provider
  understands belongs in that provider's `lib.sh`, not here.
- `scripts/gcp/lib.sh`, `scripts/docker/lib.sh` — provider defaults and helpers.
- `scripts/<provider>/*.sh` — the commands (create/start/stop/connect/ssh/status/bootstrap/
  destroy/suspend/resume). Both providers implement the same verbs.
- `docker/` — the image the docker provider builds: `Dockerfile` (thin: a sudo-capable
  `coder` user, nothing codebox-specific) and `entrypoint.sh` (PID 1; runs code-server once
  bootstrap has installed it).
- `vm/bootstrap.sh` is the privileged half (packages, the uid split, systemd units) and
  `vm/bootstrap-user.sh` the agent's half (everything under the agent's home). With
  `CODEBOX_AGENT_USER` set the second runs as that user; without it, inline as the login
  user. Anything touching `$HOME` belongs in the second.
- `vm/` — files copied to and executed **inside the box**, VM or container (`bootstrap.sh`,
  `idle-shutdown.sh`, `pre-suspend.sh`, `systemd/`, and the GitHub-access helpers
  `gh-app-token.sh`, `git-credential-codebox.sh`, `gh-shim.sh`, installed into
  `~/.local/bin`).
- `vm/bootstrap.sh` runs on both providers. It detects a container (`/.dockerenv` or
  `CODEBOX_CONTAINER`) and skips what needs systemd — the code-server unit, the idle
  auto-suspend timer, the pre-suspend notice — and binds code-server to `0.0.0.0` so
  Docker's published port can reach it. Keep new work in it working on both.
- The VM warns connected clients before suspending by appending to `/run/codebox/notices`;
  `connect` reads it through a `tail -F` carried on the tunnel's own SSH session. Anything
  added to that channel has to stay silent when idle — traffic on port 22 is what the idle
  timer measures, so a chatty channel would stop the box ever suspending.
- `VERSION` / `packaging/` / `Formula/` / `.github/workflows/release.yml` — the release
  process. Bumping `VERSION` on `main` is what publishes a release; see the Releasing
  section of `README.md`. Anything a user needs at runtime must be listed in
  `PAYLOAD_PATHS` in `packaging/build.sh`, or it won't ship in the packages.

## Conventions

- Laptop-side scripts are strict bash (`set -euo pipefail`) and assume the provider's own
  CLI: `gcloud` for gcp, `docker` for docker. Target bash 3.2 — macOS still ships it, and
  Homebrew is a supported install path, so no namerefs or other bash 4-isms.
- All gcloud calls go through `codebox_gcloud` so they're pinned to the configured project.
- On gcp, access is IAP-only: SSH runs over `--tunnel-through-iap`; code-server is
  loopback-bound and reached via an SSH `-L` forward. Don't add rules that expose ports
  publicly. On docker the equivalent invariant is the publish address: ports go to
  `CODEBOX_DOCKER_BIND` (`127.0.0.1`), which is why code-server may bind `0.0.0.0` inside
  the container. Don't publish to `0.0.0.0` by default.

## Public-repo hygiene

This repo is intended to go public. Never commit secrets or PII: no API keys, no code-server
passwords, no personal emails/names/usernames. Real config lives in `codebox.env`, which is
git-ignored — only `codebox.env.example` is tracked.
