# CLAUDE.md — uye-runner

Developer reference for AI assistants working in this repository.

---

## What this repo is

A self-hosted GitHub Actions runner that runs inside Docker and uses a
Docker-in-Docker (DinD) sidecar so workflows can build and push container
images. The runner registers at the **organization** level via a GitHub PAT
and deregisters cleanly on shutdown. The whole stack is orchestrated with
Docker Compose and auto-deploys itself via a GitHub Actions workflow whenever
`main` is updated.

---

## Repository layout

```
.
├── Dockerfile                        # runner image (Ubuntu 22.04 + Docker CLI + GH runner binary)
├── entrypoint.sh                     # startup script: register → run → deregister on exit
├── docker-compose.yml                # dind + runner services + named volumes
├── .env.example                      # template for required env vars (copy → .env)
├── .gitignore                        # ignores .env and runner config artifacts
└── .github/
    └── workflows/
        └── deploy.yml                # CI: build image → push to GHCR → SSH redeploy
```

---

## Architecture

```
docker-compose
├── dind  (docker:27-dind, privileged)
│   ├── DOCKER_TLS_CERTDIR=/certs   ← generates TLS certs on first start
│   └── volumes: dind-certs, dind-storage
└── runner  (this image)
    ├── DOCKER_HOST=tcp://dind:2376  ← no local daemon; delegates to dind
    ├── DOCKER_TLS_VERIFY=1
    ├── DOCKER_CERT_PATH=/certs/client
    └── volumes: dind-certs (read-only)
```

The runner container never runs a Docker daemon. It only has the Docker CLI
installed. All `docker` commands issued by workflows are forwarded over TLS to
the dedicated `dind` container. This isolates the Docker socket and avoids
sharing the host daemon.

---

## Environment variables

Loaded from `.env` (via `env_file` in Compose). The three Docker-related vars
are hardcoded in `docker-compose.yml` and must not be overridden in `.env`.

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `GITHUB_TOKEN` | yes | — | PAT with `manage_runners:org` scope |
| `GITHUB_ORG` | yes | — | GitHub org slug (e.g. `acme`) |
| `RUNNER_NAME` | no | container hostname | Display name in GitHub UI |
| `RUNNER_LABELS` | no | `self-hosted,linux,x64` | Comma-separated labels |
| `DOCKER_HOST` | set by Compose | `tcp://dind:2376` | Points CLI at dind |
| `DOCKER_TLS_VERIFY` | set by Compose | `1` | Enforce TLS |
| `DOCKER_CERT_PATH` | set by Compose | `/certs/client` | Client cert location |

`GITHUB_ORG` is also interpolated into the `runner` service's `image:` field
(`ghcr.io/${GITHUB_ORG}/uye-runner:latest`) so Compose knows where to pull
the pre-built image from.

---

## Dockerfile details

- **Base**: `ubuntu:22.04`
- **Build arg**: `RUNNER_VERSION` (default `2.323.0`) — override to pin a
  different release: `docker build --build-arg RUNNER_VERSION=2.324.0 .`
- **Docker CLI**: installed from Docker's official apt repo (`docker-ce-cli`
  only — no daemon, no containerd).
- **Runner binary**: downloaded from
  `github.com/actions/runner/releases` and extracted to
  `/home/runner/actions-runner/`.
- **User**: non-root `runner` user with passwordless sudo (needed for some
  workflow steps that call `apt-get`). Switch back to a stricter sudoers
  entry if that is a concern.
- **Entrypoint**: `entrypoint.sh` copied into the workdir and set as
  `ENTRYPOINT`.

To pin a new runner version, change the `ARG RUNNER_VERSION` default in
`Dockerfile` and rebuild.

---

## entrypoint.sh walkthrough

```
1. Validate GITHUB_TOKEN and GITHUB_ORG are set (fails fast if missing).
2. POST /orgs/{org}/actions/runners/registration-token → short-lived REG_TOKEN.
3. ./config.sh --url … --token … --name … --labels … --unattended --replace
4. trap cleanup SIGTERM SIGINT
   cleanup() { ./config.sh remove --unattended --token $REG_TOKEN }
5. exec ./run.sh   ← PID 1 from here; trap fires on SIGTERM from `docker stop`
```

`--replace` means if a runner with the same name already exists (e.g. after a
crash without clean shutdown), it will be overwritten rather than erroring.

The registration token is short-lived (~1 hour). It is only used at startup
and during the cleanup trap — it is not re-fetched at runtime.

---

## docker-compose.yml details

**dind service**
- `docker:27-dind` — official Docker-in-Docker image
- `privileged: true` — required for the inner Docker daemon
- `DOCKER_TLS_CERTDIR=/certs` — dind auto-generates a CA, server cert, and
  client cert under `/certs` on first start
- `dind-storage` volume persists the inner daemon's image/layer cache across
  restarts (avoids re-pulling base images on every runner restart)

**runner service**
- `image:` + `build:` coexist: locally `docker compose build` builds and tags
  with the image name; in production `docker compose pull runner` fetches the
  pre-built image from GHCR
- `depends_on: dind` — Compose starts dind first, but does **not** wait for
  the daemon to be ready. `entrypoint.sh` doesn't need the daemon at startup
  (config.sh doesn't use Docker), so this is fine in practice.
- `restart: unless-stopped` on both services — auto-restarts on crash but
  respects a deliberate `docker compose stop`

**Volumes**
- `dind-certs` — shared between dind (rw) and runner (ro); contains TLS
  material generated by dind
- `dind-storage` — private to dind; persists Docker layer cache

---

## Auto-deploy workflow (`.github/workflows/deploy.yml`)

Triggered on every push to `main`. Runs on a GitHub-hosted runner.

```
1. Checkout
2. docker/login-action → ghcr.io  (uses built-in GITHUB_TOKEN, no extra secret)
3. docker/build-push-action → pushes :latest and :{sha} tags to GHCR
4. appleboy/ssh-action → SSH into the server:
     cd ~/uye-runner
     docker compose pull runner   ← fetches new :latest from GHCR
     docker compose up -d runner  ← recreates the runner container
```

Required GitHub Actions secrets (set in repo Settings → Secrets → Actions):

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | Server IP or hostname |
| `DEPLOY_USER` | SSH username (e.g. `ubuntu`) |
| `DEPLOY_SSH_KEY` | Ed25519 or RSA private key PEM |

The workflow does **not** restart the `dind` service, so the Docker layer
cache and TLS certs survive every runner redeploy.

---

## First-time server setup

The runner runs under a dedicated `ghrunner` user that has no password and
belongs to the `docker` group.

```bash
# 1. Create the dedicated user (run as your main sudo-capable user)
sudo useradd -m -s /bin/bash ghrunner
sudo usermod -aG docker ghrunner

# 2. Generate the deploy SSH key pair (as ghrunner)
sudo -iu ghrunner
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -C deploy -f ~/.ssh/uye_runner_deploy
# No passphrase — GitHub Actions must use the key non-interactively

# 3. Authorize the key for SSH login
cat ~/.ssh/uye_runner_deploy.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# 4. Copy the private key into the DEPLOY_SSH_KEY GitHub secret
cat ~/.ssh/uye_runner_deploy

# 5. Authenticate with GHCR (creds persist in ~/.docker/config.json)
echo YOUR_PAT | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin

# 6. Clone the repo and configure
git clone https://github.com/YOUR_ORG/uye-runner ~/uye-runner
cd ~/uye-runner
cp .env.example .env
$EDITOR .env   # set GITHUB_TOKEN and GITHUB_ORG

# 7. Initial start
docker compose up -d
docker compose logs -f runner
```

Set `DEPLOY_USER` secret to `ghrunner`.

After this, every push to `main` will rebuild the image and redeploy the
runner automatically.

---

## Day-to-day operations

```bash
# View runner logs
docker compose logs -f runner

# View dind logs (useful when docker build fails inside a workflow)
docker compose logs -f dind

# Force restart the runner only (dind keeps running)
docker compose restart runner

# Full teardown (runner deregisters from GitHub via the SIGTERM trap)
docker compose down

# Full teardown including volumes (wipes Docker layer cache and TLS certs)
docker compose down -v

# Rebuild locally after Dockerfile changes
docker compose build runner
docker compose up -d runner

# Pin a different runner version
docker compose build --build-arg RUNNER_VERSION=2.324.0 runner
```

---

## Updating the runner binary

Change the default in `Dockerfile`:

```dockerfile
ARG RUNNER_VERSION=2.324.0   # ← bump here
```

Commit and push to `main` — the CI workflow rebuilds and redeploys.

Or build locally:

```bash
docker compose build --build-arg RUNNER_VERSION=2.324.0 runner
docker compose up -d runner
```

---

## GitHub PAT scopes required

**Must use a classic token.** Fine-grained personal access tokens do not
support `manage_runners:org` and cannot be used here.

Create at: https://github.com/settings/tokens → **Tokens (classic)** →
Generate new token (classic).

| Scope | Why |
|---|---|
| `manage_runners:org` | Register / deregister org-level runners |
| `read:packages` | Pull the runner image from GHCR (if the package is private) |

The `GITHUB_TOKEN` used in the deploy workflow (built-in) only needs
`packages: write` (granted automatically via the `permissions` block in the
workflow). It is a different token from the PAT in `.env`.

---

## Security notes

- The `dind` container is privileged. Keep it isolated — do not expose port
  2376 beyond the Compose network.
- The `runner` user has passwordless sudo inside the container. Tighten this
  if your workflows don't require it.
- The `.env` file contains a PAT — it is gitignored. Never commit it.
- TLS between runner and dind is enforced (`DOCKER_TLS_VERIFY=1`), so plain
  TCP connections to the daemon are rejected.
- `--replace` in `config.sh` silently overwrites an existing runner
  registration. If you run multiple runners on the same host, give each a
  unique `RUNNER_NAME`.
