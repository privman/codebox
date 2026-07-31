# codebox

A small, self-contained toolkit for running a **cloud dev box** that you drive from your
laptop with [code-server](https://github.com/coder/code-server) (VS Code in the browser)
and [Claude Code](https://claude.com/claude-code).

> **Providers:** `gcp` (the default) puts the box on a Google Cloud VM reached over an IAP
> tunnel. `docker` puts it in a container on the machine you are sitting at — same editor,
> same tooling, no cloud account, no idle auto-suspend. Pick one with `--provider`; see
> [Running locally in Docker](#running-locally-in-docker).

You provision a VM once, connect to it over an **IAP-tunneled SSH port-forward**, and
edit/build inside the browser. The VM **suspends itself when idle** — freezing memory to
disk so your running processes survive — so you only pay for compute while you're actually
using it, and you pick up exactly where you left off with a single command.

```
laptop  ──IAP TCP tunnel──▶  sshd (:22, IAP range only)  ──local forward──▶  code-server (127.0.0.1:8080)
                                                                              claude, git, python3, ...
```

## Why this shape

- **No public exposure of the editor.** code-server listens only on `127.0.0.1`.
  You reach it by forwarding a local port through an SSH session that itself runs over
  Google's [Identity-Aware Proxy](https://cloud.google.com/iap) TCP tunnel. Nothing but
  SSH is reachable, and SSH is locked to the IAP source range.
- **Cheap when idle, without losing your work.** A systemd timer **suspends** the VM after a
  configurable idle period — RAM is frozen to disk, so dev servers and Claude Code sessions
  are restored intact on resume. A suspended instance bills for its disk plus the saved memory,
  not for CPU/RAM.
- **One command to come back.** `codebox connect` resumes (or starts) the VM if needed and opens the tunnel.
- **A blast radius you can hand to an agent.** The point of putting the box *away from your
  laptop* is that you can let Claude Code run without approving every step: it is a machine
  you can destroy and rebuild, holding a checkout and a repo-scoped token rather than your
  keys, your email and your home directory. See
  [Letting the agent run unattended](#letting-the-agent-run-unattended).

## Prerequisites

For the **docker** provider, all you need is a working Docker install — skip to
[Running locally in Docker](#running-locally-in-docker). The rest of this section is the
**gcp** provider.

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

## Installing

Any of these gets you a `codebox` on your PATH. They all ship the same tree — the CLI,
the provider scripts, and the files that get copied to the VM.

**Homebrew** (macOS or Linux):

```bash
brew tap privman/codebox https://github.com/privman/codebox
brew install codebox
```

**apt** (Debian/Ubuntu):

```bash
curl -fsSL https://privman.github.io/codebox/codebox.gpg \
  | sudo tee /usr/share/keyrings/codebox.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/codebox.gpg] https://privman.github.io/codebox stable main" \
  | sudo tee /etc/apt/sources.list.d/codebox.list
sudo apt-get update && sudo apt-get install codebox
```

**Standalone download** — one self-extracting file, no package manager:

```bash
curl -fsSLO https://github.com/privman/codebox/releases/latest/download/codebox
chmod +x codebox && sudo mv codebox /usr/local/bin/
```

It unpacks itself into `~/.cache/codebox/bundle/` on first run. Checksums for every
release artifact are in `SHA256SUMS` on the [releases page](https://github.com/privman/codebox/releases).

**From a checkout** — what you want if you're changing codebox itself:

```bash
git clone https://github.com/privman/codebox && export PATH="$PWD/codebox/bin:$PATH"
```

A packaged install has no checkout to keep `codebox.env` next to, so put it in the
directory you run `codebox` from, or in `~/.config/codebox/codebox.env` for a machine-wide
default (see [Configuration](#configuration)).

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
$EDITOR codebox.env            # set CODEBOX_PROJECT (and CODEBOX_REPO, zone/size if you like)

# 2. Put the CLI on your PATH (optional but convenient)
export PATH="$PWD/bin:$PATH"

# 3. Provision + install tooling (a few minutes)
codebox create

# 4. Open the editor — starts the VM if it's stopped, then tunnels
codebox connect
#    -> browse to http://localhost:8080  (password is printed for you)
```

Leave the `codebox connect` terminal open; it holds the tunnel. Press `Ctrl-C` to
disconnect. The VM auto-suspends after `CODEBOX_IDLE_TIMEOUT_MIN` minutes of little
traffic and low CPU — leaving this terminal (or a browser tab) open does **not** hold it
up. When the suspend closes the tunnel, `connect` says so and offers to reconnect rather
than dropping you back at the shell:

```
warning: The VM suspended itself after 30 idle minutes, which closed the tunnel.
==> Reconnecting resumes it, and anything that was running is still there.
Reconnect? [Y/n]
```

Answering yes resumes the VM and reopens the tunnel; `n` (or `Ctrl-D`) exits. You get the
same offer if the tunnel drops for any other reason, with the message saying which case it
is. When the suspend is the VM's own idle timer (or a `codebox suspend` from elsewhere),
the VM warns first and `connect` closes the tunnel itself, so the exchange is a clean
handshake rather than a connection dying mid-flight — see
[Auto-suspend on idle](#auto-suspend-on-idle). While the tunnel is up, `connect` also watches the config file it loaded and reopens the
tunnel whenever you save a change — that's how a
[`CODEBOX_ADDITIONAL_PORTS`](#accessing-a-dev-server-running-in-the-box) edit takes effect.

## Running locally in Docker

Same box, same tooling, no cloud account: `--provider docker` builds an image, runs a
container on this machine, and installs code-server, Claude Code and your repo into it with
the *same* `vm/bootstrap.sh` the VM uses. Useful for trying codebox out, for working
offline, or when a box does not need to outlive your laptop.

```bash
# 1. Configure (CODEBOX_PROJECT is not needed for this provider)
cp codebox.env.example codebox.env
$EDITOR codebox.env                       # CODEBOX_REPO, ports, GitHub access if you want them

# 2. Build the image, create the container, install the tooling (a few minutes)
codebox --provider docker create

# 3. Print the editor URL and password
codebox --provider docker connect
#    -> browse to http://localhost:8080

# ... and when you are done
codebox --provider docker stop
```

The provider is per-invocation — there is no config key for it — so pass `--provider docker`
each time, or alias it: `alias dbox='codebox --provider docker'`.

**How it differs from the GCP provider:**

| | `gcp` | `docker` |
| --- | --- | --- |
| Reaching the editor | SSH port-forward over an IAP tunnel | Docker publishes the port to `127.0.0.1` |
| `codebox connect` | blocks, holding the tunnel | prints the URL and exits; the box keeps running |
| Idle auto-suspend | on, after `CODEBOX_IDLE_TIMEOUT_MIN` | **off** — a local container costs nothing to leave up |
| `codebox suspend` | freezes RAM to disk | `docker pause` — freezes the processes in place |
| `codebox stop` | shuts the VM down | stops the container; the filesystem survives |
| `codebox ssh` | SSH over IAP | `docker exec` a login shell |
| Extra ports | re-forwarded when you edit the config | fixed when the container is created (see below) |

**Idle auto-suspend is deliberately disabled here.** It exists to stop a cloud VM billing
you for sitting still; locally there is nothing to save, and the timer needs systemd, which
the container does not run. `codebox bootstrap` skips installing it and pins
`CODEBOX_IDLE_TIMEOUT_MIN=0` for the container regardless of what your config says. Stop the
box yourself with `codebox --provider docker stop`.

**Ports are fixed at create time.** Docker cannot add a published port to an existing
container, so editing `CODEBOX_ADDITIONAL_PORTS` does not reach a box that already exists —
`connect` compares the two and tells you when they have drifted. To apply the change:

```bash
codebox --provider docker destroy && codebox --provider docker create
```

That loses everything inside the container, so commit and push first.

**Docker-only settings:**

| Variable | Default | Meaning |
| --- | --- | --- |
| `CODEBOX_DOCKER_IMAGE` | `codebox:local` | Image tag built by `create` |
| `CODEBOX_DOCKER_USER` | `coder` | Login user inside the box |
| `CODEBOX_DOCKER_BIND` | `127.0.0.1` | Host interface the ports are published on |

`CODEBOX_INSTANCE` names the container, so several boxes can coexist the same way they do
on GCP (see [Running multiple codeboxes](#running-multiple-codeboxes)).

**On exposure:** inside the container code-server binds `0.0.0.0`, because Docker's
published port cannot reach a service listening only on the container's loopback. What
makes it private is the publish address — `CODEBOX_DOCKER_BIND`, `127.0.0.1` by default — so
the editor is reachable from your machine and not from your network. Point that at another
interface and you are publishing a password-protected editor to it; that is your call to
make deliberately. Other containers on the same Docker network can reach it either way,
which is worth knowing if you run untrusted containers.

## Commands

| Command             | Description                                                        |
| ------------------- | ------------------------------------------------------------------ |
| `codebox create`    | Create the VM + IAP firewall rules, then install the tooling       |
| `codebox connect`   | Start the VM if needed and open the editor tunnel to `localhost`; supervises it (offers to reconnect on a drop, restarts on a config edit) |
| `codebox ssh`       | Open an interactive SSH shell (over IAP)                           |
| `codebox start`     | Start a stopped VM (or resume it if suspended)                     |
| `codebox stop`      | Stop the VM — full shutdown; halts compute billing, loses running state |
| `codebox suspend`   | Suspend the VM — freeze RAM; preserves running processes, cheaper than running |
| `codebox resume`    | Resume a suspended VM (restores running processes)                 |
| `codebox status`    | Show the instance status                                           |
| `codebox bootstrap` | Re-run the tooling install on an existing VM                       |
| `codebox destroy`   | Delete the VM (and optionally the firewall rules)                  |

Every command accepts an optional `--provider <name>` flag (default `gcp`). The table above
describes the `gcp` provider; `docker` maps the same verbs onto a local container, with the
differences listed in [Running locally in Docker](#running-locally-in-docker).

## Repository layout

- `bin/codebox` — provider-agnostic CLI; parses `--provider` and dispatches to a provider's scripts.
- `scripts/common.sh` — config loading, defaults and validation shared by every provider.
- `scripts/gcp/` — all GCP-specific logic (gcloud provisioning, IAP tunnel, firewall).
- `scripts/docker/` — the local-container provider.
- `docker/` — the image the container provider builds (`Dockerfile`, `entrypoint.sh`).
- `vm/` — provider-agnostic files installed on the VM (code-server, Claude Code,
  the idle auto-suspend timer).
- `VERSION` — the released version, and what triggers a release (see [Releasing](#releasing)).
- `packaging/` — build the release artifacts (`build.sh`) and the apt repo (`publish-apt.sh`).
- `Formula/codebox.rb` — the Homebrew formula; the release workflow keeps it current.

## Configuration

All settings live in `codebox.env` (git-ignored). Copy `codebox.env.example` and edit.
The first of these that exists wins:

1. `$CODEBOX_ENV`, if you set it — an explicit path, used by
   [running multiple codeboxes](#running-multiple-codeboxes)
2. `./codebox.env` in the directory you run the command from
3. `codebox.env` next to the codebox tree (a git checkout; not applicable to packaged installs)
4. `~/.config/codebox/codebox.env` — machine-wide fallback, handy after `brew`/`apt` install

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
| `CODEBOX_ADDITIONAL_PORTS` | *(empty)* | Comma-separated extra ports to forward on `connect` (same port local + VM) |
| `CODEBOX_IDLE_TIMEOUT_MIN`| `30`             | Idle minutes before auto-suspend (`0` disables)     |
| `CODEBOX_REPO`            | *(empty)*        | Git repo to clone into the VM; its root is the folder code-server opens |
| `CODEBOX_GITHUB_APP_ID`   | *(empty)*        | GitHub App id (option A — see [private repo access](#giving-the-agent-access-to-a-private-repo)) |
| `CODEBOX_GITHUB_APP_INSTALLATION_ID` | *(empty)* | The app's installation id on your repo   |
| `CODEBOX_GITHUB_APP_KEY`  | *(empty)*        | Path **on your laptop** to the app's `.pem`; copied to the VM |
| `CODEBOX_GITHUB_BOT_NAME` | *(looked up)*    | Bot login, e.g. `codebox-agent[bot]`                |
| `CODEBOX_GITHUB_BOT_USER_ID` | *(looked up)* | Bot's **user** id (not the app id)                  |
| `CODEBOX_GITHUB_TOKEN_FILE` | *(empty)*      | Path on your laptop to a file holding a fine-grained PAT (option B) |
| `CODEBOX_GITHUB_WRITE_REPOS` | *(empty)*     | Comma-separated `owner/name` the agent may write to; everything else is read-only |
| `CODEBOX_AGENT_USER`      | *(empty)*        | Run the agent as this unprivileged user, with the App key behind a third account |
| `CODEBOX_CLAUDE_TOKEN_FILE` | *(empty)*      | Path on your laptop to a `claude setup-token` token; the box comes up authenticated |
| `CODEBOX_SSH_KEY_FILE`    | *(empty)*        | Path on your laptop to a passphrase-less ssh key (a read-only deploy key) for ssh remotes |
| `CODEBOX_CLAUDE_MARKETPLACES` | *(empty)*    | Comma-separated plugin marketplaces to add in every box |
| `CODEBOX_CLAUDE_PLUGINS`  | *(empty)*        | Comma-separated `plugin@marketplace` to install in every box |
| `CODEBOX_AGENT_PERMISSION_MODE` | *(empty)* | `bypassPermissions`, `dontAsk`, … written into the box's Claude settings |
| `CODEBOX_AGENT_DENY_TOOLS` | *(empty)*       | Comma-separated tools the agent may never call, enforced in every mode |
| `CODEBOX_AGENT_ALLOW_TOOLS` | *(empty)*      | Comma-separated allowlist; required with `dontAsk` |
| `CODEBOX_GIT_AGENT_NAME`  | *(from the app)* | Author/committer name for Claude Code's commits     |
| `CODEBOX_GIT_AGENT_EMAIL` | *(from the app)* | Author/committer email for Claude Code's commits    |
| `CODEBOX_DOCKER_IMAGE`    | `codebox:local`  | `--provider docker`: image tag built by `create`    |
| `CODEBOX_DOCKER_USER`     | `coder`          | `--provider docker`: login user inside the container |
| `CODEBOX_DOCKER_BIND`     | `127.0.0.1`      | `--provider docker`: host interface ports are published on |

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

## Cloning your project into the box

Set `CODEBOX_REPO` and `codebox create` clones it into the VM's home directory, then makes the
repo root the folder code-server opens — so `codebox connect` drops you straight into the
project. https and ssh URIs are both accepted, and the `.git` suffix is optional:

```bash
# in codebox.env — all four of these clone into ~/repo
CODEBOX_REPO="https://github.com/owner/repo.git"
CODEBOX_REPO="https://github.com/owner/repo"
CODEBOX_REPO="git@github.com:owner/repo.git"
CODEBOX_REPO="ssh://git@github.com/owner/repo"
```

The checkout directory comes from the URI's last path segment (`repo` above). Cloning also
runs on `codebox bootstrap`, and it's idempotent: an existing checkout is never touched, so
re-running bootstrap won't disturb local work. Likewise, the default folder is only seeded
when code-server has no last-opened folder yet — after that, it remembers wherever you were.

**Credentials.** The clone runs non-interactively, so a **public https** repo works out of the
box while anything needing auth fails fast (with a warning; the rest of bootstrap still
completes) rather than hanging on a prompt. For a **private** repo, configure GitHub access as
below — bootstrap installs the credentials before it clones, so it works on the first
`codebox create`.

## Giving the agent access to a private repo

This is what lets Claude Code on the box clone a private repo, push branches, and open PRs —
and be recognisable as an agent while doing it. Point `CODEBOX_REPO` at the **https** URI so a
single credential covers both git and the GitHub API (`gh`), then pick one of two options:

| | **A — GitHub App** | **B — fine-grained PAT** |
| --- | --- | --- |
| Setup time | ~10 min, once | ~2 min |
| Push branches / open PRs | ✅ / ✅ | ✅ / ✅ |
| Author identity on commits | `name[bot]`, with avatar + `bot` badge | separate name, but unlinked — no avatar |
| PRs are opened by | the app's bot | **you** |
| Extra paid org seat | no | no |
| Credential on the VM | app private key; tokens expire hourly | the token itself, until you rotate it |
| Revoking | uninstall the app | delete the token |

Both options give the agent its own **author identity** on commits — bootstrap configures that
either way (see [below](#how-the-agent-gets-its-own-identity)). The difference is whether that
identity is *attested* or merely *asserted*:

- With the **app**, the bot is a real GitHub actor: it is what pushed the branch and what
  opened the PR, and its commits carry the bot's avatar and badge. History and GitHub's own
  record of who did the work agree.
- With a **PAT**, the commits say `codebox-agent`, but that is a string the box types into a
  commit — nothing ties it to an account. Every push and PR is recorded as **yours**, because
  the token is yours. Someone reading the history sees the agent; someone reading the audit
  log or the PR author sees you.

So Option A if you want the agent's work to be distinguishable from yours by something
stronger than a convention. Option B is a fine stepping stone, and you can switch later
without touching the repo.

### Option A — GitHub App (recommended)

On GitHub, under **Settings → Developer settings → GitHub Apps → New GitHub App**:

1. Repository permissions: **Contents: Read and write**, **Pull requests: Read and write**
   (Metadata: Read is added automatically). Add **Actions: Read**, **Checks: Read** and
   **Commit statuses: Read** so the agent can see CI — without them `gh run view` and
   `gh pr checks` come back empty, and it cannot read the failure it is being asked to fix.
   Uncheck **Active** under Webhook — nothing here listens for events. Deliberately leave
   **Workflows** unset: without it the agent cannot modify `.github/workflows`, which is a
   guardrail worth keeping, and reading CI does not require it.
2. **Generate a private key** — a `.pem` downloads. Note the **App ID** on the same page.
3. **Install App** onto the one repository. The URL of the resulting settings page ends in
   `/installations/<id>` — that number is the **installation ID**.

Then in `codebox.env`:

```bash
CODEBOX_REPO="https://github.com/owner/repo"
CODEBOX_GITHUB_APP_ID="123456"
CODEBOX_GITHUB_APP_INSTALLATION_ID="78901234"
CODEBOX_GITHUB_APP_KEY="$HOME/.secrets/codebox-agent.private-key.pem"   # path on your laptop
```

`codebox create` (or `codebox bootstrap` on an existing box) copies the key to
`~/.config/codebox/gh-app.pem` on the VM at mode `600` and wires up:

- **`~/.local/bin/codebox-gh-token`** — mints an installation token from the key (valid one
  hour, cached for 45 minutes) and prints it. Nothing longer-lived is ever stored.
- **`~/.local/bin/git-credential-codebox`** — a
  [git credential helper](https://git-scm.com/docs/gitcredentials), registered for
  `https://github.com` only, that hands git a freshly minted token. `git push` just works.
- **`~/.local/bin/gh`** — a shim that runs the real `gh` with `GH_TOKEN` set the same way, so
  `gh pr create` opens the PR as the app's bot with no stored login.
- **`~/.claude/settings.json`** — the agent's git identity (below).

The keys stay on the VM's disk across suspend/stop, but not `codebox destroy` — keep the
`.pem` in your password manager so you can re-seed a fresh box.

**Guardrail worth adding.** The app has `contents:write`, which permits pushing to `main`. Add
a repository **ruleset** requiring a pull request for `main`, and "push into branches freely"
becomes bounded by the server rather than by the agent's good behaviour.

**Changing an installed app's permissions** — say you add the CI read permissions later —
does not take effect on its own. GitHub holds the change until the installation accepts it
(a banner on the app's install page, plus an email to the owner), and until then freshly
minted tokens still carry the old grants, which looks exactly like the new permission not
working. Accept it, then clear the cache below.

**If something 401s**, or a permission you just granted appears to do nothing, the cached
token may be stale: `rm ~/.cache/codebox/token-*` forces fresh ones. There is one cache file
per scope, so removing the lot is the reliable move.

### Scoping what the agent can write

By default the agent's tokens are as broad as the App's installation. `CODEBOX_GITHUB_WRITE_REPOS`
narrows them per call, so a single App installed across an org can give the agent push access to
one project and read-only access to everything else:

```bash
# in codebox.env
CODEBOX_GITHUB_WRITE_REPOS="privman/tasklick"
```

Install the App on **All repositories** with the write permissions you want (Contents: R/W,
Pull requests: R/W, Metadata: Read). codebox then mints two kinds of token:

- **a listed repo** — `repositories: [that repo]` and no `permissions` override, so the token
  keeps the App's full grants but reaches only that repository;
- **anything else** — `permissions: {contents: read, metadata: read}` across every installed
  repository.

GitHub enforces both: `repositories` and `permissions` on a token request can only reduce what
the installation already grants, never extend it. Measured against a live App, a write-scoped
token creates a blob in its own repo (201), is refused on another (403 for a read-only token,
404 — invisible — for a write-scoped one).

This needs `credential.useHttpPath`, which bootstrap turns on for github.com: without it git
sends only the hostname and the helper cannot tell which repository it is being asked about.
It therefore applies to **https remotes only** — an ssh remote never consults the credential
helper. `gh` is covered too: the shim reads `-R/--repo`, falling back to the checkout you are
standing in.

> **This is self-restriction until you add the privilege split.** The `.pem` lives in the box,
> so anything running there can call the API directly and mint a full token. See
> [Keeping the key away from the agent](#keeping-the-key-away-from-the-agent).

### Syncing skills from a private marketplace

Everything else in codebox reaches GitHub over https with a short-lived, repo-scoped App
token. A private [plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces)
is the one thing that cannot, because of how its background refresh works:

> By default, the background refresh disables git credential helpers for its `git pull`, so
> the pull can't authenticate to private repositories over HTTPS even when a helper is
> configured. SSH remotes aren't affected.

A failed pull falls back to re-cloning the whole marketplace, which the docs note "may fail
intermittently" on large repos. So a private marketplace wants an **ssh** remote, and
`CODEBOX_SSH_KEY_FILE` gives the box a key for it:

```bash
# 1. On your laptop, a key used for nothing else
ssh-keygen -t ed25519 -N "" -C "codebox marketplace" -f ~/.secrets/codebox-marketplace

# 2. Add the .pub as a READ-ONLY deploy key on the marketplace repo
#    (repo -> Settings -> Deploy keys -> Add, leave "Allow write access" unchecked)

# 3. In codebox.env
CODEBOX_SSH_KEY_FILE="$HOME/.secrets/codebox-marketplace"
```

Then declare it in `codebox.env` so every box installs it during bootstrap, rather than
being set up by hand:

```bash
CODEBOX_CLAUDE_MARKETPLACES="git@github.com:you/your-skills.git"
CODEBOX_CLAUDE_PLUGINS="your-plugin@your-skills"
```

Both are comma-separated, marketplaces are added before plugins, and both steps are
idempotent — re-running `codebox bootstrap` reports what is already there and changes
nothing. They are additive: removing an entry from the config does not remove it from an
existing box, since the box may also hold things you added inside it. A source that cannot
be reached is a warning, not a failed bootstrap — a box missing a skill is still a box.

You can equally add one by hand inside the box:

```bash
claude plugin marketplace add git@github.com:you/your-skills.git
claude plugin install your-plugin@your-skills
```

Bootstrap installs the key as `~/.ssh/id_codebox` (mode 0600, in the agent's home under the
[uid split](#keeping-the-key-away-from-the-agent)), writes an `~/.ssh/config` entry using
`IdentitiesOnly`, and pins github.com's host keys from `api.github.com/meta` over TLS —
rather than `ssh-keyscan`, which trusts whatever answers on port 22. Without pinned host
keys a non-interactive pull fails on an unknown host, which is precisely the case this is
for.

**Use a read-only deploy key, not your own ssh key.** A deploy key is scoped to one
repository and, left read-only, cannot write to it — so it cannot be used to get around
`CODEBOX_GITHUB_WRITE_REPOS`. Your personal key would do both, and unlike the App key it
lives in the agent's home where the agent can read it.

### Keeping the key away from the agent

The scoping above is enforced by GitHub, but *asking* for a narrow token is voluntary: the
App key sits in the box, so anything running there can call the API itself and mint a broad
one. `CODEBOX_AGENT_USER` closes that by giving the box three unix accounts instead of one:

```bash
# in codebox.env
CODEBOX_AGENT_USER="agent"
```

| account | runs | holds |
| --- | --- | --- |
| your login user | nothing — you, over `codebox ssh` | sudo |
| `agent` | code-server, Claude Code, every editor terminal | no sudo, one sudoers rule |
| `codebox-git` | the token minter, on demand | the App key, mode 0600 |

The agent's only privilege is a single sudoers rule — one fixed command, no wildcards:

```
agent ALL=(codebox-git) NOPASSWD: /usr/local/bin/codebox-gh-token
```

It can ask for a token; it cannot read the key, cannot run anything else as `codebox-git`,
and cannot edit the policy that decides the scope (`/etc/codebox/gh-app.env`, root-owned).
The repository it names is untrusted input and doesn't need to be checked: GitHub only ever
narrows, so naming a repo outside the allowlist returns a read-only token for that repo.

Measured inside a real box with `CODEBOX_AGENT_USER=agent`:

| as the agent user | result |
| --- | --- |
| `cat /var/lib/codebox-git/gh-app.pem` | permission denied |
| `sudo -n cat …` / `sudo -n -u codebox-git cat …` | `a password is required` |
| append to `/etc/codebox/gh-app.env` | permission denied |
| `codebox-gh-token --repo <allowlisted>` → write | 201 |
| `codebox-gh-token --repo <other>` → write | 403 (read still 200) |
| `git push --dry-run` | authenticates through the whole chain |

**What you give up.** code-server runs as the agent, so the browser terminal has no sudo —
admin work goes through `codebox ssh`, which lands you as the login user. Don't `su` back to
a privileged account *inside* the editor: that terminal is a child of code-server and shares
the agent's uid, so anything running as the agent can read the pty or ptrace the shell, and
you would be handing over the password you just typed.

Enable it on an existing box by setting the variable and re-running `codebox bootstrap`. The
key moves out of your home directory and the agent's home becomes a fresh one, so the clone
and any uncommitted work in the old home stay where they are — push first.

### Option B — fine-grained PAT (quick)

Under **Settings → Developer settings → Personal access tokens → Fine-grained tokens**, create
one scoped to just that repository with **Contents: Read and write** and **Pull requests: Read
and write**. Save it to a file on your laptop rather than pasting it into `codebox.env` —
that file is plaintext, and a path keeps the secret out of it:

```bash
umask 077; printf '%s\n' "github_pat_..." > ~/.secrets/codebox-gh-token
```

```bash
# in codebox.env
CODEBOX_REPO="https://github.com/owner/repo"
CODEBOX_GITHUB_TOKEN_FILE="$HOME/.secrets/codebox-gh-token"
```

Bootstrap copies it to the VM and runs `gh auth login --with-token` plus `gh auth setup-git`,
so the one token covers pushes and PR creation. Fine-grained tokens expire — to rotate, update
the file and re-run `codebox bootstrap`.

Setting both options at once is rejected rather than silently resolved: they configure git and
`gh` differently, and guessing would be a nasty surprise.

### How the agent gets its own identity

Two different mechanisms, easily conflated:

**In git history**, attribution comes from the commit's author email. For a GitHub App the
form is `<bot-user-id>+<slug>[bot]@users.noreply.github.com` — and that number is the **bot
user's** id, *not* the app id. Get it wrong and the commit shows as an unlinked name with no
avatar. Bootstrap looks both values up from the API for you; override them with
`CODEBOX_GITHUB_BOT_NAME` / `CODEBOX_GITHUB_BOT_USER_ID` if the box can't reach
`api.github.com`. With a PAT there is no bot account to point at, so the identity defaults to
a plain `codebox-agent <codebox-agent@users.noreply.github.com>` — distinct in the log, but
linked to nothing.

**Scoping that to Claude only** matters because you and Claude share one unix user on the VM —
a global `user.email` would relabel your own commits too. So the identity goes in
`~/.claude/settings.json` under `env`, which Claude Code applies to the subprocesses it spawns:

```json
{
  "env": {
    "GIT_AUTHOR_NAME": "codebox-agent[bot]",
    "GIT_AUTHOR_EMAIL": "12345678+codebox-agent[bot]@users.noreply.github.com",
    "GIT_COMMITTER_NAME": "codebox-agent[bot]",
    "GIT_COMMITTER_EMAIL": "12345678+codebox-agent[bot]@users.noreply.github.com"
  },
  "attribution": { "commit": "🤖 committed by codebox-agent[bot] on codebox" }
}
```

Commits you make yourself in a VM terminal keep whatever `~/.gitconfig` says. `attribution` is
only seeded if you haven't set one. Override the whole identity with `CODEBOX_GIT_AGENT_NAME` /
`CODEBOX_GIT_AGENT_EMAIL`.

### What not to use

- **Deploy keys** — they can clone and push, but carry no API access, so the agent cannot open
  a PR.
- **Classic PATs** — they reach every repo you can. A leak on a long-lived dev VM is expensive.
- **Your own `gh auth login`** on the box — convenient, and it puts full account access on a
  machine you suspend and forget about.

## Accessing a dev server running in the box

Run a dev server inside the VM (say on port 8000) and forward its port to your laptop so it's
reachable at the same `localhost:8000`. Because the port matches, the app's own links —
absolute (`http://localhost:8000/...`) or root-relative (`/...`) — resolve natively, with no
proxy or URL rewriting.

List the port(s) in `codebox.env` and `codebox connect` forwards them alongside the editor:

```bash
# in codebox.env
CODEBOX_ADDITIONAL_PORTS="8000,5173"
```

```bash
codebox connect      # forwards the editor + localhost:8000 and localhost:5173
```

You can edit this while connected: `codebox connect` notices the save and reopens the tunnel
with the new list, so a port you forgot to add costs a file save rather than a reconnect.

Each extra port uses the same number locally and on the VM. For a one-off port you'd rather
not keep in the config, open a separate forward instead:

```bash
codebox ssh -- -N -L 8000:localhost:8000
```

## What gets installed on the VM

- **Claude Code** (via the native installer into `~/.local/bin`; a self-contained binary
  that auto-updates and needs no language runtime)
- **code-server**, bound to `127.0.0.1:<CODEBOX_REMOTE_PORT>` with a generated password,
  running as a systemd service. Seeded with `window.autoDetectColorScheme: true` so the
  editor follows your OS light/dark preference, and a `window.title` that puts the project
  name before the file name so browser tabs stay identifiable (override either in settings —
  bootstrap never overwrites a value you've already set).
- **git, GitHub CLI (`gh`), ripgrep, jq, tmux, build-essential**
- **GitHub access for the agent**, if configured — see
  [Giving the agent access to a private repo](#giving-the-agent-access-to-a-private-repo)
- **your project**, if `CODEBOX_REPO` is set — cloned into the home directory and opened as
  code-server's default folder (see [Cloning your project into the box](#cloning-your-project-into-the-box))
- **codebox idle auto-suspend** systemd timer, plus `/usr/local/bin/codebox-pre-suspend`,
  which warns connected clients before a suspend (installed even when the timer is off,
  since `codebox suspend` uses it too)

No language runtime is installed by default. Debian 12 already ships Python 3, which covers
Python projects; install anything else you need per project (or extend `vm/bootstrap.sh`).

### Signing in to Claude Code

No credentials are baked into this repo or the image, so a box has to be given one. Two ways:

**Set `CODEBOX_CLAUDE_TOKEN_FILE`** (recommended, and required if the agent is to run
unattended). Mint a token once on your laptop and point at the file:

```bash
claude setup-token                       # browser flow; prints a one-year token
$EDITOR ~/.secrets/claude-token          # paste it, one line
chmod 600 ~/.secrets/claude-token

# in codebox.env
CODEBOX_CLAUDE_TOKEN_FILE="$HOME/.secrets/claude-token"
```

Every box then comes up authenticated with no login step, and the credential it holds bills
to your subscription but can *only* make model requests — it cannot reach your claude.ai
connectors. That is deliberate: see
[Letting the agent run unattended](#letting-the-agent-run-unattended).

**Or log in by hand.** Leave the setting empty, then in an editor terminal (or
`codebox ssh`) run `claude` once and follow the prompt. Fine for a box you drive yourself;
the credential stored this way is your full login rather than a model-requests-only token,
and every new box needs the step repeated.

To check either one, from inside the box:

```bash
claude -p 'reply with OK'
```

## Auto-suspend on idle

A systemd timer runs every 5 minutes and **suspends** the VM once **all** of these hold
for `CODEBOX_IDLE_TIMEOUT_MIN` minutes:

- SSH and code-server connections are moving less than `TRAFFIC_KB_PER_MIN` (default `50`),
- 1-minute load average below `LOAD_THRESHOLD` (default `0.4`) — this protects a long
  build or a running Claude Code task even if your tunnel dropped.

Note what is **not** a signal: whether a connection exists. An open tunnel is precisely
what you leave behind when you walk away from the laptop, and a code-server tab parked in
a browser holds a websocket open indefinitely — measured at ~11 KB/min of pure heartbeat
with nobody touching it. Treating either as "in use" meant the box never suspended while a
terminal or tab was left open, which is the exact case auto-suspend exists to catch. So the
check looks at the traffic *rate*: heartbeat chatter reads as idle, while a keystroke, a
save or a page load clears the threshold immediately. Both values live in
`/etc/codebox-idle.conf` on the VM if you want to tune them.

Suspend freezes RAM to disk, so on the next `codebox connect` the VM **resumes** with your
processes still running — dev servers, Claude Code sessions, shells — right where you left them.
Since idleness is judged on traffic, a `codebox connect` you left open is exactly the case
this catches — so the VM warns its clients before it goes:

1. The timer decides to suspend and appends a line to `/run/codebox/notices`.
2. Every connected `codebox connect` sees it. The tunnel's own SSH session is tailing that
   file, so the warning arrives on the connection you already have — no extra port, no
   listener on your laptop, and nothing on the wire until there is something to say (which
   matters, because a chatty channel would register as traffic and keep the box awake).
3. Each client closes its tunnel from its end and offers to reconnect.
4. The VM waits up to `SUSPEND_GRACE_SEC` (default 5) for those connections to go, then
   suspends.

The result is that `ssh` exits cleanly instead of discovering mid-write that its connection
has been frozen, which is where the wall of errors used to come from. The wait is strictly
bounded: a client that is wedged or already gone cannot delay the suspend. `codebox suspend`
runs the same hook (`/usr/local/bin/codebox-pre-suspend`) over ssh before calling the API,
so a manual suspend is just as polite; a suspend from the GCP console bypasses it, and the
client falls back to reporting the drop after the fact.
The VM triggers this on itself via the Compute API (using its metadata service-account token),
which is why the instance is created with the `compute` scope; the service account needs
`compute.instances.suspend` (the default Compute Engine SA has it). If the suspend call ever
fails it just stays up and retries next cycle — there is intentionally no fallback to a full
stop. Set `CODEBOX_IDLE_TIMEOUT_MIN=0` to disable auto-suspend entirely.

## Teardown

```bash
codebox destroy                       # delete the VM; prompts about the firewall rules
```

If you created a throwaway project for this (see above), you can remove everything —
instance, disk, firewall, and all — by deleting the project:

```bash
gcloud projects delete "$PROJECT_ID"
```

## Releasing

`VERSION` drives everything. Push a commit to `main` that bumps it and
[`.github/workflows/release.yml`](.github/workflows/release.yml) does the rest:

```bash
echo "0.2.0" > VERSION
git commit -am "Release 0.2.0" && git push
```

The workflow compares `VERSION` against the previous commit and stops immediately unless it
went up (a push that leaves it alone costs one quick job and publishes nothing). When it did
go up, the workflow tags `v<version>`, builds the artifacts, and publishes:

- a **GitHub release** holding the standalone `codebox` bundle, the `codebox-<version>.tar.gz`
  source tarball, the `.deb`, and `SHA256SUMS`
- **`Formula/codebox.rb`**, rewritten to point at the new tarball and its checksum, committed
  back to `main` (that commit doesn't touch `VERSION`, so it can't trigger another release)
- the **apt repository** on the `gh-pages` branch — the new `.deb` is added to the pool and
  the index is re-signed. Older versions stay in the pool.

A version that goes *backwards* or isn't `MAJOR.MINOR.PATCH` fails the run rather than
publishing something odd. If a release dies halfway, re-run the workflow by hand
(**Actions → Release → Run workflow**): every step tolerates having already run, so it
picks up where it stopped. That manual run is also how you cut the first release, since
`VERSION` is already at its starting value.

### One-time setup

The GitHub release and the Homebrew formula need nothing beyond the default
`GITHUB_TOKEN`. The apt repository needs a signing key — without it the workflow still
releases and just logs a warning that it skipped apt.

```bash
# 1. Make a signing key (any name/email you're happy to publish).
gpg --quick-generate-key "codebox releases <codebox@users.noreply.github.com>" rsa4096 sign never
gpg --armor --export-secret-keys codebox@users.noreply.github.com   # paste into the secret below
```

2. Add repo secrets (**Settings → Secrets and variables → Actions**):
   `APT_GPG_PRIVATE_KEY` (the armored private key) and, if the key has one,
   `APT_GPG_PASSPHRASE`.
3. Enable Pages (**Settings → Pages**) with source *Deploy from a branch*, branch
   `gh-pages`, folder `/`. The branch appears the first time the workflow publishes.

Keep the private key out of the repo — it belongs only in the Actions secret and wherever
you keep your own backups.

### Checking a release before you tag one

Both publishing scripts run locally:

```bash
packaging/build.sh 0.2.0      # writes dist/: bundle, tarball, .deb, SHA256SUMS
dist/codebox version          # the bundle self-test the build already ran

# Build the apt tree into dist/apt without pushing anything (needs a key in $GPG_KEY):
GPG_KEY="$(gpg --armor --export-secret-keys <key-id>)" packaging/publish-apt.sh 0.2.0
```

## Letting the agent run unattended

Approving every command defeats the purpose of a box like this. The intent is that you can
run the agent with permission prompts off, because the box — not the prompt — is what
contains it: a disposable VM or container, reachable only through an IAP tunnel or
loopback, holding a checkout and a
[repo-scoped GitHub token](#scoping-what-the-agent-can-write) instead of your credentials.
Destroying it and running `codebox create` again costs a few minutes.

```bash
claude --dangerously-skip-permissions
```

Set `CODEBOX_CLAUDE_TOKEN_FILE` to a token from `claude setup-token` and the box arrives
authenticated, with no `claude` login step. That token bills to your subscription and can
*only* make model requests — it cannot pull in your claude.ai connectors, so the connectors
whose OAuth scopes you cannot narrow simply aren't in the box. Locally configured MCP
servers, whose credentials you do control, still work. That is the strongest form of the
"scope the credential" advice below: absent beats denied.

**Skipping prompts does not mean skipping policy.** Claude Code evaluates `deny` rules
regardless of mode — the docs are explicit that in `bypassPermissions` mode *"explicit deny
rules still apply"* — so you can attach connectors and still make individual tools
uncallable. This is what makes it safe to give the box an email connector for reading
without also handing over the ability to delete a mailbox:

codebox can write this for you, so the policy lives in `codebox.env` and applies to every
box you create rather than being hand-edited inside each one:

```bash
# in codebox.env — quote these, deny patterns contain parens
CODEBOX_AGENT_PERMISSION_MODE="bypassPermissions"
CODEBOX_AGENT_DENY_TOOLS="mcp__claude_ai_Gmail__delete_email, Bash(rm -rf /*)"
```

which lands as:

```jsonc
// ~/.claude/settings.json in the box
{
  "permissions": {
    "defaultMode": "bypassPermissions",
    "deny": [
      "mcp__claude_ai_Gmail__delete_email",
      "mcp__claude_ai_Gmail__trash_email",
      "Bash(gcloud compute instances delete:*)"
    ]
  }
}
```

A **bare tool name** in `deny` (no argument pattern) removes the tool from Claude's context
entirely — it is not refused at call time, it is never offered. A scoped rule like
`Bash(rm -rf /*)` leaves the tool available and blocks matching calls.

**If you would rather fail closed, use `dontAsk` instead of `bypassPermissions`.** It
"auto-denies tools unless pre-approved via `permissions.allow`" and never prompts, so it is
a prompt-free allowlist: a tool that appears later — a connector adding a `delete_all`
endpoint in an update — is denied by default rather than allowed by default. The cost is
that you have to enumerate what the agent may use, including the ordinary coding tools.

Two more layers worth knowing about, in rough order of strength:

1. **Scope the credential, not the caller.** A connector authorised with read-only scopes
   cannot delete anything however the agent is configured — the same reasoning as
   [scoping what the agent can write](#scoping-what-the-agent-can-write) on GitHub. Prefer
   this whenever the service offers it; it is the only layer that survives a
   misconfiguration of the ones below.
2. **`PreToolUse` hooks** for rules a static list can't express (deny `git push` to `main`,
   allow it elsewhere). A hook that exits 2 blocks the call before permission rules are
   evaluated, and a hook returning `"allow"` cannot override a `deny` rule — so hooks add
   restrictions without being able to remove them.

What none of this covers: an agent with a shell can write a script that does what a denied
tool would have done. `Read`/`Edit` deny rules "don't apply to arbitrary subprocesses",
and neither does anything else in this list. If that matters for a given box, the answer is
the box's own boundaries — a container with no credentials mounted, or Claude Code's
[sandboxing](https://code.claude.com/docs/en/sandboxing) for OS-level filesystem and
network limits — not a longer deny list.

## Security model / going public

This repo is built to be safe to open-source:

- **No secrets committed.** `codebox.env` (which holds your project id) is git-ignored;
  only `codebox.env.example` is tracked. The code-server password is generated on the VM
  and never leaves it. Claude Code credentials are entered interactively on the VM.
- **GitHub secrets live outside the repo.** `codebox.env` stores only a *path* to the app
  key or token file, never the secret itself, and `*.pem`/`*.key` are git-ignored as a
  backstop. On the VM they sit in `~/.config/codebox/` at mode `600`. With a GitHub App,
  what's on disk is the app key alone — the tokens derived from it expire within the hour
  and are scoped to the repos the app is installed on.
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
