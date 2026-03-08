# uye-runner

Self-hosted GitHub Actions runner in Docker, with a Docker-in-Docker sidecar for building and pushing container images. Registers at the organization level, deregisters cleanly on shutdown, and redeploys itself automatically on every push to `main`.

---

## Architecture

```
docker-compose
├── dind   docker:27-dind (privileged)   isolated Docker daemon + TLS
└── runner  this image                   GH Actions runner binary
            DOCKER_HOST=tcp://dind:2376  delegates all docker commands to dind
```

The runner container has the Docker CLI but no daemon. Every `docker build` / `docker push` in a workflow is forwarded over TLS to the `dind` sidecar. This keeps the host Docker socket out of reach.

---

## Prerequisites

- Docker + Docker Compose v2 on the host
- A GitHub **classic** PAT with `manage_runners:org` and `read:packages` scopes
  (fine-grained tokens do not support `manage_runners:org`)
- The GitHub org slug you want to attach the runner to

---

## Quick start

```bash
# 1. Clone
git clone https://github.com/YOUR_ORG/uye-runner ~/uye-runner
cd ~/uye-runner

# 2. Configure
cp .env.example .env
$EDITOR .env   # set GITHUB_TOKEN and GITHUB_ORG

# 3. Start
docker compose up --build -d

# 4. Verify
docker compose logs -f runner
# → "Runner registered. Starting..."
```

Then go to `https://github.com/organizations/YOUR_ORG/settings/actions/runners` — the runner should appear as **Idle**.

---

## Environment variables

Copy `.env.example` to `.env` and fill in:

| Variable | Required | Description |
|---|---|---|
| `GITHUB_TOKEN` | yes | Classic PAT with `manage_runners:org` + `read:packages` scopes |
| `GITHUB_ORG` | yes | GitHub org slug (e.g. `acme`) |
| `RUNNER_NAME` | no | Display name — defaults to container hostname |
| `RUNNER_LABELS` | no | Comma-separated labels, default `self-hosted,linux,x64` |

The Docker connection variables (`DOCKER_HOST`, `DOCKER_TLS_VERIFY`, `DOCKER_CERT_PATH`) are set automatically by Compose and should not be added to `.env`.

---

## Auto-deploy

Every push to `main` triggers `.github/workflows/deploy.yml`, which:

1. Builds the runner image and pushes it to GHCR (`ghcr.io/{org}/uye-runner`)
2. SSHes into the server and runs `docker compose pull runner && docker compose up -d runner`

The `dind` service is never restarted during redeploy, so the Docker layer cache and TLS certs persist.

### Required GitHub Actions secrets

Add these in **Settings → Secrets → Actions**:

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | Server IP or hostname |
| `DEPLOY_USER` | `ghrunner` (dedicated deploy user) |
| `DEPLOY_SSH_KEY` | Private key PEM generated on the server (see server setup below) |

### Server setup

Run once on the server to create a dedicated user and configure SSH:

```bash
# As your main user
sudo useradd -m -s /bin/bash ghrunner
sudo usermod -aG docker ghrunner

# As ghrunner
sudo -iu ghrunner
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -C deploy -f ~/.ssh/uye_runner_deploy  # no passphrase
cat ~/.ssh/uye_runner_deploy.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Paste the private key into the DEPLOY_SSH_KEY GitHub secret
cat ~/.ssh/uye_runner_deploy

# Authenticate with GHCR (persists in ~/.docker/config.json)
echo YOUR_PAT | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
```

---

## Using the runner in a workflow

```yaml
jobs:
  build:
    runs-on: self-hosted   # or a custom label set in RUNNER_LABELS
    steps:
      - uses: actions/checkout@v4
      - run: docker build -t myimage .
      - run: docker push myimage
```

---

## Common operations

```bash
# Tail logs
docker compose logs -f runner
docker compose logs -f dind        # for docker build failures

# Restart runner only (dind keeps running)
docker compose restart runner

# Graceful shutdown — runner deregisters from GitHub
docker compose down

# Rebuild locally after Dockerfile changes
docker compose build runner && docker compose up -d runner
```

---

## Updating the runner binary

Bump `RUNNER_VERSION` in `Dockerfile`, then push to `main` — CI handles the rest. Or rebuild locally:

```bash
docker compose build --build-arg RUNNER_VERSION=2.324.0 runner
docker compose up -d runner
```

Latest releases: https://github.com/actions/runner/releases
