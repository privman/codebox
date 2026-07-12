# codebox

A small, self-contained toolkit for running a **cloud dev box** that you drive from your
laptop with [code-server](https://github.com/coder/code-server) (VS Code in the browser)
and [Claude Code](https://claude.com/claude-code).

> **Providers:** Google Cloud (GCP) is the only supported provider **at the moment**.
> The CLI takes a `--provider` flag (default `gcp`) so additional providers can be added
> later; passing anything other than `gcp` errors out as unimplemented for now.

You provision a VM once, connect to it over an **IAP-tunneled SSH port-forward**, and
edit/build inside the browser. The VM **stops itself when idle** so you only pay for
compute while you're actually using it, and you resume it with a single command.

```
laptop  ──IAP TCP tunnel──▶  sshd (:22, IAP range only)  ──local forward──▶  code-server (127.0.0.1:8080)
                                                                              claude, git, python3, ...
```

## Why this shape

- **No public exposure of the editor.** code-server listens only on `127.0.0.1`.
  You reach it by forwarding a local port through an SSH session that itself runs over
  Google's [Identity-Aware Proxy](https://cloud.google.com/iap) TCP tunnel. Nothing but
  SSH is reachable, and SSH is locked to the IAP source range.
- **Cheap when idle.** A systemd timer shuts the guest OS down after a configurable
  idle period. A stopped GCP instance bills only for its disk, not CPU/RAM.
- **One command to come back.** `codebox connect` starts the VM if needed and opens the tunnel.

## Prerequisites

On your **laptop**:

- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`)
- An authenticated gcloud session: `gcloud auth login`
- A GCP project with billing enabled

In the **project** (enable once):

```bash
gcloud services enable compute.googleapis.com iap.googleapis.com
```

Your GCP user needs, at minimum:

- `roles/compute.instanceAdmin.v1` — create/start/stop/delete the VM
- `roles/iap.tunnelResourceAccessor` — open IAP tunnels
- `roles/compute.osLogin` (only if OS Login is enabled on the project)

## Setting up a GCP project from scratch

If you'd rather run codebox in its own project (easy to reuse an existing billing account
and to delete cleanly afterwards), do this once. As the project's creator you're Owner, so
you already have the IAM roles listed above.

```bash
# 0. Pick a globally-unique project id and a zone.
export PROJECT_ID="codebox-<something-unique>"
export ZONE="us-central1-a"

# 1. Make sure you're authenticated.
gcloud auth list                 # or: gcloud auth login

# 2. Find the billing account id to reuse (looks like 0X0X0X-0X0X0X-0X0X0X).
gcloud billing accounts list
export BILLING_ACCOUNT="0X0X0X-0X0X0X-0X0X0X"

# 3. Create the project and link billing.
gcloud projects create "$PROJECT_ID" --name="codebox"
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"

# 4. Enable the required APIs (also provisions the default network + service account).
gcloud services enable compute.googleapis.com iap.googleapis.com --project="$PROJECT_ID"
```

Give step 4 ~30 seconds to settle, then set `CODEBOX_PROJECT` (and `CODEBOX_ZONE`) in
`codebox.env` and continue with Quick start below.

Notes:
- The **first** `gcloud compute ssh` (during `codebox create`) offers to generate an SSH
  keypair — accept it and use an **empty passphrase** so the automated steps don't stall.
- If `codebox create` errors immediately after enabling the APIs (network/service account
  still provisioning), just re-run `codebox bootstrap` — it's idempotent.

## Quick start

```bash
# 1. Configure
cp codebox.env.example codebox.env
$EDITOR codebox.env            # set CODEBOX_PROJECT (and zone/size if you like)

# 2. Put the CLI on your PATH (optional but convenient)
export PATH="$PWD/bin:$PATH"

# 3. Provision + install tooling (a few minutes)
codebox create

# 4. Open the editor — starts the VM if it's stopped, then tunnels
codebox connect
#    -> browse to http://localhost:8080  (password is printed for you)
```

Leave the `codebox connect` terminal open; it holds the tunnel. Press `Ctrl-C` to
disconnect. The VM will auto-stop after `CODEBOX_IDLE_TIMEOUT_MIN` minutes of no SSH
connection and low CPU.

## Commands

| Command             | Description                                                        |
| ------------------- | ------------------------------------------------------------------ |
| `codebox create`    | Create the VM + IAP firewall rules, then install the tooling       |
| `codebox connect`   | Start the VM if needed and open the editor tunnel to `localhost`   |
| `codebox ssh`       | Open an interactive SSH shell (over IAP)                           |
| `codebox start`     | Start a stopped VM                                                  |
| `codebox stop`      | Stop the VM (halts compute billing)                                |
| `codebox status`    | Show the instance status                                           |
| `codebox bootstrap` | Re-run the tooling install on an existing VM                       |
| `codebox destroy`   | Delete the VM (and optionally the firewall rules)                  |

Every command accepts an optional `--provider <name>` flag (default `gcp`). Only `gcp` is
implemented right now; other values are rejected as unimplemented.

## Repository layout

- `bin/codebox` — provider-agnostic CLI; parses `--provider` and dispatches to a provider's scripts.
- `scripts/gcp/` — all GCP-specific logic (gcloud provisioning, IAP tunnel, firewall).
  A future provider would live alongside as `scripts/<provider>/`.
- `vm/` — provider-agnostic files installed on the VM (code-server, Claude Code,
  the idle-shutdown timer).

## Configuration

All settings live in `codebox.env` (git-ignored). Copy `codebox.env.example` and edit.

| Variable                  | Default          | Meaning                                             |
| ------------------------- | ---------------- | --------------------------------------------------- |
| `CODEBOX_PROJECT`         | *(required)*     | GCP project id                                      |
| `CODEBOX_ZONE`            | `us-central1-a`  | Compute zone                                        |
| `CODEBOX_INSTANCE`        | `codebox`        | Instance name                                       |
| `CODEBOX_MACHINE_TYPE`    | `e2-standard-4`  | Machine type (4 vCPU / 16 GB)                       |
| `CODEBOX_DISK_SIZE`       | `50`             | Boot disk size in GB                                |
| `CODEBOX_IMAGE_FAMILY`    | `debian-12`      | OS image family                                     |
| `CODEBOX_IMAGE_PROJECT`   | `debian-cloud`   | OS image project                                    |
| `CODEBOX_LOCAL_PORT`      | `8080`           | Port on your laptop for the editor                  |
| `CODEBOX_REMOTE_PORT`     | `8080`           | Port code-server binds to on the VM (localhost)     |
| `CODEBOX_IDLE_TIMEOUT_MIN`| `30`             | Idle minutes before auto-stop (`0` disables)        |

## Running multiple codeboxes

You can run several independent VMs for the same project from the same directory — each box
is just a separate config file. `codebox` resolves its config in this order (first match
wins): `$CODEBOX_ENV`, then `./codebox.env`, then `<repo>/codebox.env`. So point
`CODEBOX_ENV` at a per-instance file:

```bash
cp codebox.env codebox-b.env
$EDITOR codebox-b.env          # give it a unique CODEBOX_INSTANCE (and CODEBOX_LOCAL_PORT)

CODEBOX_ENV=codebox-b.env codebox create
CODEBOX_ENV=codebox-b.env codebox connect
```

Two values must differ per box:

- **`CODEBOX_INSTANCE`** — a unique VM name, or the second `codebox create` collides with the first.
- **`CODEBOX_LOCAL_PORT`** — only needed if you want both editor tunnels open *at the same
  time* (two `connect`s would otherwise both try to bind `localhost:8080`). The **remote**
  port can stay the same — the VMs are different machines.

Everything else just works: the IAP firewall rules are shared and created idempotently, and
each VM generates its own code-server password. Per-instance config files match the
`codebox*.env` entry in `.gitignore`, so they won't be committed (only `codebox.env.example`
is tracked).

## What gets installed on the VM

- **Claude Code** (via the native installer into `~/.local/bin`; a self-contained binary
  that auto-updates and needs no language runtime)
- **code-server**, bound to `127.0.0.1:<CODEBOX_REMOTE_PORT>` with a generated password,
  running as a systemd service. Seeded with `window.autoDetectColorScheme: true` so the
  editor follows your OS light/dark preference (you can override it in settings).
- **git, ripgrep, jq, tmux, build-essential**
- **codebox idle-shutdown** systemd timer

No language runtime is installed by default. Debian 12 already ships Python 3, which covers
Python projects; install anything else you need per project (or extend `vm/bootstrap.sh`).

### Signing in to Claude Code

Claude Code is installed but **not** authenticated — no credentials are baked into this
repo or the image. In an editor terminal (or `codebox ssh`), run `claude` once and follow
the login prompt. Your credentials stay on the VM's disk.

## Auto-stop on idle

A systemd timer runs every 5 minutes and shuts the machine down once **all** of these hold
for `CODEBOX_IDLE_TIMEOUT_MIN` minutes:

- no established SSH connection (i.e. no `codebox connect`/`ssh` tunnel open),
- no established connection on the code-server port,
- 1-minute load average below `LOAD_THRESHOLD` (default `0.4`) — this protects a long
  build or a running Claude Code task even if your tunnel dropped.

A stopped instance keeps its disk and everything on it; `codebox connect` brings it right back.

## Teardown

```bash
codebox destroy                       # delete the VM; prompts about the firewall rules
```

If you created a throwaway project for this (see above), you can remove everything —
instance, disk, firewall, and all — by deleting the project:

```bash
gcloud projects delete "$PROJECT_ID"
```

## Security model / going public

This repo is built to be safe to open-source:

- **No secrets committed.** `codebox.env` (which holds your project id) is git-ignored;
  only `codebox.env.example` is tracked. The code-server password is generated on the VM
  and never leaves it. Claude Code credentials are entered interactively on the VM.
- **SSH is IAP-only.** `create` adds an allow rule for the IAP range
  (`35.235.240.0/20`) plus a higher-priority deny rule for SSH from anywhere else, scoped
  to the instance's network tag — so even though the VM keeps an ephemeral external IP
  (used only for package-download egress), port 22 is not reachable off IAP.
- **The editor is never exposed.** code-server binds to loopback; it is reachable only
  through the SSH port-forward.

If you prefer **no external IP at all**, remove the external IP and add a Cloud NAT for
egress — see the comment in `scripts/create.sh`.

Before flipping the repo to public, double-check `git log` and the tree for anything you
added locally (e.g. a stray `codebox.env`).
