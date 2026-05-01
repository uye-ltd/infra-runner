# infra-runner

Hardened self-hosted GitHub Actions runner for public repositories. Each job runs in a fresh, isolated container that is destroyed on completion. A GitOps deployer polls GHCR for new images, verifies their cosign signatures, and applies updates without SSH.

---

## Architecture

```
docker-compose
├── controller-proxy   Docker API filter (no EXEC, no BUILD)
├── controller         pool manager → controller-proxy → Docker socket
├── deployer-proxy     Docker API filter (no EXEC, no BUILD)
└── deployer           GitOps pull loop → deployer-proxy → Docker socket
                       + ./:/workspace:ro,  :HEALTH_PORT/health

Per job (created and destroyed by the controller):
├── runner-net-{id}    isolated bridge network (10.89.x.x, egress-restricted)
└── runner-job-{id}    ephemeral runner (Kaniko binary for image builds)
```

**Controller** maintains a warm pool of idle runners (`DESIRED_IDLE`, default 2). When a runner picks up a job it exits. The controller tears down all per-job resources and spawns a replacement.

**Runner containers** have no Docker socket and no privileged flag. Image builds use [Kaniko](https://github.com/GoogleContainerTools/kaniko), which builds from a Dockerfile in userspace without a daemon. The controller's credential (GitHub App token or PAT) never enters runner containers — only a short-lived, single-use registration token is injected at spawn time.

---

## Security properties

| Threat | Protection |
|---|---|
| Malicious job leaves persistent state | Container destroyed after every job (`--ephemeral`) |
| Privileged container escape | No privileged flag — Kaniko builds in userspace, no DinD |
| Credential theft | Controller credential (App token or PAT) stays in the controller; runners get only a short-lived registration token |
| Docker socket abuse | Socket proxy allows only required API endpoints; `EXEC` and `BUILD` disabled on both proxies |
| Supply chain / image tampering | cosign keyless signing in CI; deployer verifies signature before every pull; runner binary SHA256-verified at build time; CI actions pinned to commit SHAs |
| Resource abuse (mining, DoS) | `--memory` and `--cpus` limits on every runner container; socket proxies capped at 128 MB / 0.25 CPU |
| Network exfiltration / lateral movement | Egress policy: DNS + HTTPS only; private RFC 1918 ranges blocked |
| Kernel-level container escape | `seccomp/runner-profile.json` blocks `mount`, `kexec_*`, `bpf`, kernel module syscalls |
| File system / capability abuse | AppArmor profile denies `sys_admin`, `sys_module`, `net_raw`, sysfs writes, host credential reads |
| Stranger PRs triggering jobs | GitHub setting: require approval for outside collaborators (see below) |

---

## Prerequisites

- Docker + Docker Compose v2 on the host
- The GitHub org slug you want to attach runners to
- **One** of the following for controller authentication:
  - **GitHub App** (recommended) — a GitHub App installed on the org with
    *Self-hosted runners: Read & write*, *Members: Read*, and *Packages: Read* permissions.
    You will need the App ID, installation ID, and a downloaded private key PEM file.
  - **Classic PAT** (backward compat) — `admin:org`, `manage_runners:org`, `read:packages` scopes.
    Fine-grained tokens do not support `manage_runners:org`.

---

## One-time server setup

Run as root before starting the stack for the first time.

```bash
# Network egress policy — restricts runner containers to DNS + HTTPS only,
# blocks private networks, configures Docker address pool for job networks
sudo bash ~/infra-runner/scripts/setup-egress-policy.sh
sudo systemctl restart docker   # required for address pool change to take effect

# AppArmor profile — MAC layer restricting runner capabilities and file access
sudo bash ~/infra-runner/scripts/setup-apparmor.sh
# Verify: aa-status | grep infra-runner
```

The egress script allocates job networks from `10.89.0.0/16` and adds iptables
`DOCKER-USER` rules restricting that subnet to DNS and HTTPS only.

The AppArmor script installs `apparmor/infra-runner` and loads it. The controller passes
`--security-opt apparmor=infra-runner` to every runner container.

The controller and deployer services each have their own isolated network in
`172.20.0.0/24` and are not subject to the runner egress rules.

---

## First-time server setup

```bash
# 1. Create a dedicated user
sudo useradd -m -s /bin/bash ghrunner
sudo usermod -aG docker ghrunner

# 2. Authenticate with GHCR (as ghrunner)
sudo -iu ghrunner
echo YOUR_PAT_OR_APP_TOKEN | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin

# 3. Clone and configure
git clone https://github.com/YOUR_ORG/infra-runner ~/infra-runner
cd ~/infra-runner
cp .env.example .env
$EDITOR .env   # required: GITHUB_ORG, COMPOSE_PROJECT_NAME
               # auth — pick one:
               #   GitHub App (recommended): GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID,
               #                             GITHUB_APP_PRIVATE_KEY_PATH
               #   Static PAT (fallback):    GITHUB_TOKEN
               # recommended: RUNNER_SECCOMP_HOST_PATH

# 4. Pull and start (pulls all four services from GHCR)
docker compose pull
docker compose up -d

# 5. Verify
docker compose logs -f controller | jq .
# → {"level":"info","svc":"controller","msg":"Runner is live","job_id":"..."}
```

After the initial start the deployer takes over — every push to `main` rebuilds
images, signs them, and the deployer verifies and applies updates automatically.

### Required GitHub setting

**Settings → Actions → General → Fork pull request workflows →
"Require approval for all outside collaborators"**

This prevents PR workflows from unknown contributors from queuing at all.

---

## Environment variables

Copy `.env.example` to `.env`. Exactly one auth path must be configured:

**GitHub App (recommended)**

| Variable | Required | Description |
|---|---|---|
| `GITHUB_APP_ID` | yes (App) | Numeric GitHub App ID |
| `GITHUB_APP_INSTALLATION_ID` | yes (App) | Numeric org installation ID |
| `GITHUB_APP_PRIVATE_KEY_PATH` | yes (App) | Container path to the PEM key (mounted `:ro`) |

**Static PAT (backward compat)** — set `GITHUB_TOKEN` and leave the App vars unset.

**All other variables:**

| Variable | Required | Default | Description |
|---|---|---|---|
| `GITHUB_ORG` | yes | — | GitHub org slug (e.g. `acme`) |
| `GITHUB_REPO` | no | `infra-runner` | Repo name; used to construct the cosign certificate identity |
| `RUNNER_LABELS` | no | `self-hosted,linux,x64` | Comma-separated runner labels |
| `DESIRED_IDLE` | no | `2` | Warm idle runners to keep ready |
| `RUNNER_MEMORY` | no | `4g` | Memory limit per runner container |
| `RUNNER_CPUS` | no | `2` | CPU limit per runner container |
| `RUNNER_KANIKO_SIZE` | no | `5g` | tmpfs size for Kaniko scratch space inside runner |
| `RUNNER_APPARMOR_PROFILE` | no | `infra-runner` | AppArmor profile name; empty to disable |
| `RUNNER_SECCOMP_HOST_PATH` | no | — | Absolute host path to `seccomp/runner-profile.json` |
| `COMPOSE_PROJECT_NAME` | yes | `infra-runner` | Must match the directory name on the server |
| `POLL_INTERVAL` | no | `60` | Seconds between GHCR digest checks |
| `HEALTH_PORT` | no | `8080` | Port for the deployer health endpoint |
| `CONTROLLER_POLL_INTERVAL` | no | `15` | Seconds between controller pool maintenance cycles |

---

## Using the runner in a workflow

There is no Docker daemon in the runner. Use `kaniko` for building and pushing images.
`docker login` (credential storage only) still works for setting up registry auth.

```yaml
jobs:
  build:
    runs-on: self-hosted   # or a custom label from RUNNER_LABELS
    permissions:
      contents: read     # minimum — declare only what this workflow needs
      packages: write    # push to GHCR
    steps:
      - uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        run: |
          kaniko \
            --context=$GITHUB_WORKSPACE \
            --dockerfile=Dockerfile \
            --destination=ghcr.io/${{ github.repository_owner }}/myapp:latest \
            --destination=ghcr.io/${{ github.repository_owner }}/myapp:${{ github.sha }} \
            --cleanup
```

`docker/login-action` writes credentials to `~/.docker/config.json` (on a tmpfs inside
the runner container). Kaniko reads from there automatically. No `--registry-*` flags needed.

`--cleanup` removes extracted image layers after the build, keeping disk usage low.
Kaniko's scratch space is limited to `RUNNER_KANIKO_SIZE` (default `5g`) via tmpfs.
If you enable layer caching (`--cache`), add `--cache-ttl=1h` to prevent unbounded growth.

### Prevent fork PRs from running with secrets

```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build:
    # Run on push to main, or on internal PRs only (not fork PRs)
    if: >
      github.event_name == 'push' ||
      github.event.pull_request.head.repo.full_name == github.repository
```

### Scope `GITHUB_TOKEN` in every workflow

GitHub injects a `GITHUB_TOKEN` automatically with broad default permissions. Declare
only what each workflow needs and set the org-level default to read-only:

**Settings → Actions → General → Workflow permissions → Read repository contents and packages permissions**

---

## GitOps deploy flow

```
push to main
  → CI builds runner / controller / deployer images
  → CI pushes to GHCR with :latest and :sha tags
  → CI signs each image with cosign (keyless, OIDC-anchored to this workflow)
  → deployer detects new digest
      → new deployer image?   → verify sig → self-update → exit
      → new controller image? → verify sig → docker compose up -d controller
      → always               → verify runner sig → pre-pull for fast spawns
```

A signature verification failure immediately sets `GET /health` to `503` and skips
the update — the currently running (verified) image stays in place.

---

## Health monitoring

```
GET http://<server>:HEALTH_PORT/health
```

| Response | Meaning |
|---|---|
| `200 {"status":"ok","ts":"..."}` | Last cycle completed cleanly |
| `503 {"status":"unhealthy","reason":"...","ts":"..."}` | Signature verification failed or `docker compose up` errored |

Point UptimeRobot, Grafana Synthetic Monitoring, or any HTTP monitor at this endpoint.

Both services emit **newline-delimited JSON logs**:

```bash
docker compose logs -f controller | jq .
docker compose logs -f deployer   | jq .
```

---

## Common operations

```bash
# Follow logs
docker compose logs -f controller | jq .
docker compose logs -f deployer   | jq .

# Check health
curl -s http://localhost:8080/health | jq .

# List all live per-job containers
docker ps --filter label=runner-managed=true

# Force respawn all runners (e.g. after changing .env pool settings)
docker compose restart controller

# Full teardown (in-progress jobs are interrupted)
docker compose down

# Local build after code changes
docker compose build
docker compose up -d
```

---

## Updating the runner binary

Bump **both** `RUNNER_VERSION` and `RUNNER_SHA256` in `Dockerfile` and push to `main`.
CI rebuilds all three images, signs them, and the deployer verifies and applies the update.

```dockerfile
ARG RUNNER_VERSION=2.335.0   # ← bump here
ARG RUNNER_SHA256=<sha256>   # ← find in the release notes at github.com/actions/runner/releases
```

The SHA256 for `actions-runner-linux-x64-<version>.tar.gz` is listed inline in each GitHub
release. The build fails at verification if the hash does not match.

---

## GitHub authentication

### Option A — GitHub App (recommended)

GitHub App installation tokens are short-lived (1 hour), auto-refreshed by the controller,
and scoped to a single installation — no manual rotation required.

1. Create a GitHub App in your org (**Settings → Developer settings → GitHub Apps → New GitHub App**).
2. Grant these **organization** permissions:
   - *Self-hosted runners*: Read & write
   - *Members*: Read
   - *Packages*: Read (if your runner image is in a private GHCR package)
3. Install the App on the org and note the **installation ID** (visible in the URL of the
   install page: `github.com/organizations/YOUR_ORG/settings/installations/<id>`).
4. Generate a private key (PEM) from the App settings page and store it on the server.
5. Mount the PEM file into the controller container and set the three env vars:

```yaml
# In docker-compose.yml, under controller:
environment:
  GITHUB_APP_ID: "123456"
  GITHUB_APP_INSTALLATION_ID: "78901234"
  GITHUB_APP_PRIVATE_KEY_PATH: /run/secrets/github_app_key
volumes:
  - /path/on/host/github-app.pem:/run/secrets/github_app_key:ro
```

### Option B — Classic PAT (backward compat)

Use a **classic token** — fine-grained tokens do not support `manage_runners:org`.

Create at: **github.com/settings/tokens → Tokens (classic)**

| Scope | Why |
|---|---|
| `manage_runners:org` | Register/deregister org-level runners |
| `admin:org` | Required alongside `manage_runners:org` |
| `read:packages` | Pull runner image from GHCR (if package is private) |

Set `GITHUB_TOKEN=ghp_...` in `.env`. Leave all `GITHUB_APP_*` vars unset.
