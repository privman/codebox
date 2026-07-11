# codebox

A small, self-contained toolkit for running a **cloud dev box on Google Cloud** that
you drive from your laptop with [code-server](https://github.com/coder/code-server)
(VS Code in the browser) and [Claude Code](https://claude.com/claude-code).

You provision a VM once, connect to it over an **IAP-tunneled SSH port-forward**, and
edit/build inside the browser. The VM **stops itself when idle** so you only pay for
compute while you're actually using it, and you resume it with a single command.

```
laptop  ──IAP TCP tunnel──▶  sshd (:22, IAP range only)  ──local forward──▶  code-server (127.0.0.1:8080)
                                                                              claude, node, git, ...
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
| `CODEBOX_NODE_VERSION`    | `20`             | Node.js major version                               |
| `CODEBOX_LOCAL_PORT`      | `8080`           | Port on your laptop for the editor                  |
| `CODEBOX_REMOTE_PORT`     | `8080`           | Port code-server binds to on the VM (localhost)     |
| `CODEBOX_IDLE_TIMEOUT_MIN`| `30`             | Idle minutes before auto-stop (`0` disables)        |

## What gets installed on the VM

- **Node.js** (via NodeSource) + `corepack` (pnpm/yarn)
- **Claude Code** (`@anthropic-ai/claude-code`, installed globally)
- **code-server**, bound to `127.0.0.1:<CODEBOX_REMOTE_PORT>` with a generated password,
  running as a systemd service
- **git, ripgrep, jq, tmux, build-essential**
- **codebox idle-shutdown** systemd timer

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
