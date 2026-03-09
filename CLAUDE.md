# CLAUDE.md — uye-runner

Developer reference for AI assistants working in this repository.

---

## What this repo is

A hardened self-hosted GitHub Actions runner for **public repositories**. Each job runs in a
fresh, isolated container that is destroyed on completion — no state persists between jobs.
A GitOps deployer polls GHCR for new image digests and applies updates automatically;
no SSH push from CI is required.

---

## Repository layout

```
.
├── Dockerfile                        # runner image (Ubuntu 22.04 + Docker CLI + Kaniko + GH runner binary)
├── entrypoint.sh                     # runner startup: accept token → config --ephemeral → run.sh
├── docker-compose.yml                # four services: two socket proxies + controller + deployer
├── .env.example                      # template for required env vars (copy → .env)
├── .gitignore
├── apparmor/
│   └── uye-runner                    # AppArmor profile applied to every runner container
├── controller/
│   ├── Dockerfile                    # controller image (Ubuntu 22.04 + docker-ce-cli + jq + uuidgen)
│   └── entrypoint.sh                 # pool manager: spawn/teardown ephemeral runners
├── deployer/
│   ├── Dockerfile                    # deployer image (Ubuntu 22.04 + docker-ce-cli + compose + cosign + python3)
│   ├── entrypoint.sh                 # GitOps loop: verify sig → pull → docker compose up -d
│   └── health_server.py              # minimal Python HTTP server for GET /health
├── scripts/
│   ├── setup-apparmor.sh             # one-time: install + load AppArmor profile
│   └── setup-egress-policy.sh        # one-time: configure Docker address pool + iptables egress rules
├── seccomp/
│   └── runner-profile.json           # seccomp deny-list: blocks kernel-escape syscalls
└── .github/
    ├── dependabot.yml                # weekly PRs for Docker image + Actions version updates
    └── workflows/
        └── deploy.yml                # CI: build + push + cosign-sign runner/controller/deployer images
```

---

## Architecture

```
docker-compose (172.20.0.0/24 service space)
│
├── controller-proxy  (tecnativa/docker-socket-proxy — 172.20.0.0/26)
│   └── /var/run/docker.sock:ro  ← filters API; EXEC + BUILD disabled
│
├── controller  (uye-runner-controller — 172.20.0.64/26)
│   ├── DOCKER_HOST=tcp://controller-proxy:2375  ← no direct socket mount
│   └── env: GITHUB_TOKEN, GITHUB_ORG, RUNNER_IMAGE, pool/limit settings
│
├── deployer-proxy  (tecnativa/docker-socket-proxy — 172.20.128.0/26)
│   └── /var/run/docker.sock:ro  ← same API filtering
│
└── deployer  (uye-deployer — 172.20.128.64/26)
    ├── DOCKER_HOST=tcp://deployer-proxy:2375  ← no direct socket mount
    ├── ./:/workspace:ro  ← reads docker-compose.yml + .env for docker compose up
    └── :HEALTH_PORT  ← GET /health endpoint

Per job — created by controller, destroyed after job completes:
├── runner-net-{id}     isolated bridge network (10.89.x.x/24, egress-restricted)
└── runner-job-{id}     ephemeral runner (Kaniko binary for image builds)
```

The runner container has no Docker socket and no privileged flag. Image builds use
**Kaniko**, which builds Docker images from a Dockerfile entirely in userspace without
a daemon or a privileged container. `GITHUB_TOKEN` (the PAT) lives only in the
controller — runner containers receive only a short-lived registration token.

---

## Environment variables

Loaded from `.env` (via `env_file` in Compose).

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `GITHUB_TOKEN` | yes | — | Classic PAT: `admin:org`, `manage_runners:org`, `read:packages` |
| `GITHUB_ORG` | yes | — | GitHub org slug (e.g. `acme`) |
| `GITHUB_REPO` | no | `uye-runner` | Repo name; used to construct cosign certificate identity |
| `RUNNER_LABELS` | no | `self-hosted,linux,x64` | Comma-separated runner labels |
| `DESIRED_IDLE` | no | `2` | Warm idle runners to keep ready at all times |
| `RUNNER_MEMORY` | no | `4g` | Memory limit per runner container |
| `RUNNER_CPUS` | no | `2` | CPU limit per runner container |
| `RUNNER_KANIKO_SIZE` | no | `5g` | tmpfs size for `/kaniko` scratch space inside runner |
| `RUNNER_APPARMOR_PROFILE` | no | `uye-runner` | AppArmor profile name; empty to disable |
| `RUNNER_SECCOMP_HOST_PATH` | no | — | Absolute **host** path to `seccomp/runner-profile.json` |
| `COMPOSE_PROJECT_NAME` | yes | `uye-runner` | Must match the server directory name |
| `POLL_INTERVAL` | no | `60` | Deployer digest check interval (seconds) |
| `HEALTH_PORT` | no | `8080` | Deployer health endpoint port |

`RUNNER_IMAGE` and `DOCKER_HOST` are set in the Compose `environment` block (not `.env`)
and must not be overridden there.

`RUNNER_SECCOMP_HOST_PATH` must be a path on the **host** filesystem because Docker daemon
resolves it there. Leave empty to fall back to Docker's default seccomp profile.

---

## Dockerfile details (runner image)

- **Base**: `ubuntu:22.04`
- **Build arg**: `RUNNER_VERSION` (default `2.323.0`)
- **Docker CLI**: `docker-ce-cli` only — no daemon. Used for `docker login` (writes registry
  credentials to `~/.docker/config.json`). `docker build`/`run`/`push` have no daemon to reach.
- **Kaniko**: `COPY --from=gcr.io/kaniko-project/executor:latest /kaniko/executor /usr/local/bin/kaniko`
  — statically linked binary. Workflows call `kaniko` instead of `docker build && docker push`.
- **Runner binary**: downloaded from `github.com/actions/runner/releases`, extracted to
  `/opt/actions-runner/`
- **User**: root — required by Kaniko to extract image layers and execute `RUN` instructions.
  Container-level controls (seccomp, AppArmor, resource limits, no Docker socket, ephemeral)
  are the security boundary.
- **Entrypoint**: `entrypoint.sh`

---

## entrypoint.sh walkthrough (runner image)

```
1. Validate GITHUB_ORG and RUNNER_REGISTRATION_TOKEN are set.
   GITHUB_TOKEN is NOT present — the controller never passes it to runners.
2. ./config.sh --url … --token … --name … --labels … --unattended --ephemeral
3. exec ./run.sh   ← PID 1; exits after exactly one job
```

`--ephemeral` marks the runner as single-use. After `run.sh` picks up one job it
deregisters automatically and exits. No signal trap needed.

---

## controller/entrypoint.sh walkthrough

```
Startup:
  1. Validate env vars.
  2. Clean up orphaned resources from any previous controller run (label: runner-managed=true).
  3. docker pull RUNNER_IMAGE  ← pre-pull so the first spawn doesn't block.

Main loop (every 15s):
  4. cleanup_exited_runners()  ← find exited runner containers, tear down job-{id} resources
  5. count_active_runners()    ← running containers with runner-role=runner label
  6. spawn (DESIRED_IDLE - active) new runners in background

spawn_runner():
  a. uuidgen → job_id (10 lowercase hex chars)
  b. docker network create runner-net-{id}  (bridge, labelled runner-managed=true)
  c. POST /orgs/{org}/actions/runners/registration-token → short-lived token
  d. docker run -d runner image → runner-job-{id}
       --memory --cpus
       [--security-opt seccomp=RUNNER_SECCOMP_HOST_PATH]
       [--security-opt apparmor=RUNNER_APPARMOR_PROFILE]
       -e GITHUB_ORG -e RUNNER_REGISTRATION_TOKEN -e RUNNER_NAME -e RUNNER_LABELS
       --tmpfs /tmp:size=1g
       --tmpfs /root:size=512m      (docker login credentials, runner config)
       --tmpfs /kaniko:size=RUNNER_KANIKO_SIZE  (Kaniko layer scratch space)

cleanup_job(job_id):
  docker rm -f runner-job-{id}
  docker network rm runner-net-{id}
```

Logging: structured JSON to stdout (`ts`, `level`, `svc`, `msg`, plus contextual fields).
All per-job resources carry labels `runner-managed=true` and `runner-job-id={id}`.

---

## deployer/entrypoint.sh walkthrough

```
Startup:
  1. Start health_server.py in background (serves GET /health from /tmp/health)
  2. set_healthy()  ← write {"status":"ok"} to /tmp/health
  3. Log startup info (JSON)

Poll loop (every POLL_INTERVAL seconds):

  1. Self-update:
     pull_if_new(deployer:latest)  ← compare local digest before/after pull
     If new image downloaded:
       verify_image(deployer:latest)  ← cosign verify, keyless, OIDC-anchored
       If verified: docker compose up -d --no-deps deployer; exit 0
         (compose recreates this container; restart: unless-stopped brings it back)
       If NOT verified: set_unhealthy; skip

  2. Controller update:
     pull_if_new(controller:latest)
     If new:
       verify_image(controller:latest)
       If verified: docker compose up -d --no-deps controller
       If compose fails: set_unhealthy
       If NOT verified: set_unhealthy; skip

  3. Runner image:
     verify_image(runner:latest)  ← checks remote registry sig WITHOUT pulling first
     If verified: docker pull runner:latest (quiet)
       (controller uses locally cached image on next spawn — never blocked on a pull)
     If NOT verified: set_unhealthy; local cache untouched

  4. set_healthy()  ← clears any transient error state from this cycle

  5. sleep POLL_INTERVAL
```

`verify_image()` calls `cosign verify --certificate-identity <workflow-url> --certificate-oidc-issuer <token.actions.githubusercontent.com>`.
Signature failures are immediately written to `/tmp/health` and logged at `error` level.
Pull failures are logged as warnings; the loop continues.

---

## docker-compose.yml details

**Socket proxies** (`controller-proxy`, `deployer-proxy`)
- Image: `tecnativa/docker-socket-proxy@sha256:1f3a6...`
- Each mounts `/var/run/docker.sock:ro` and exposes port `2375` on an internal network
- Allowed API groups: `CONTAINERS`, `NETWORKS`, `IMAGES`, `POST`, `DELETE`, `INFO`
- Deployer proxy additionally allows: `VOLUMES`
- Disabled on both: `EXEC=0`, `BUILD=0`, `PLUGINS=0`, `SYSTEM=0`, `SWARM=0`, `SECRETS=0`
- `restart: unless-stopped`

**controller service**
- Connects via `DOCKER_HOST=tcp://controller-proxy:2375` — no direct socket mount
- `depends_on: controller-proxy`
- `restart: unless-stopped`

**deployer service**
- Connects via `DOCKER_HOST=tcp://deployer-proxy:2375` — no direct socket mount
- Mounts `./:/workspace:ro` for `docker compose up` (reads compose file + `.env`)
- Exposes `HEALTH_PORT` for the health endpoint
- `depends_on: deployer-proxy`
- `restart: unless-stopped`

**Networks** (all within 172.20.0.0/24, outside the 10.89.0.0/16 runner pool):
- `controller-proxy-net`: 172.20.0.0/26 — controller-proxy ↔ controller only
- `controller-net`: 172.20.0.64/26 — controller egress (internet, GitHub API)
- `deployer-proxy-net`: 172.20.128.0/26 — deployer-proxy ↔ deployer only
- `deployer-net`: 172.20.128.64/26 — deployer egress (internet, GHCR)

**No named volumes** — the controller creates no volumes in the current architecture.

---

## CI workflow (`.github/workflows/deploy.yml`)

Triggered on push to `main`. Runs on GitHub-hosted runners.

```
1. Checkout
2. Install cosign (push events only)
3. docker/login-action → ghcr.io  (built-in GITHUB_TOKEN, packages: write permission)
4. build-push runner image     → ghcr.io/{org}/uye-runner:{latest,sha}
5. build-push controller image → ghcr.io/{org}/uye-runner-controller:{latest,sha}
6. build-push deployer image   → ghcr.io/{org}/uye-deployer:{latest,sha}
7. cosign sign (push events only):
     cosign sign --yes runner@{digest}
     cosign sign --yes controller@{digest}
     cosign sign --yes deployer@{digest}
     (keyless — signature is tied to this workflow's GitHub Actions OIDC identity)
```

On `pull_request` events: images are built but not pushed and not signed (login and
cosign steps are skipped). Fork PRs cannot push to GHCR.

No SSH secrets are needed. Remove `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`
from repo secrets if previously set.

---

## First-time server setup

```bash
# 1. Create dedicated user
sudo useradd -m -s /bin/bash ghrunner
sudo usermod -aG docker ghrunner

# 2. Authenticate with GHCR (as ghrunner)
sudo -iu ghrunner
echo YOUR_PAT | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin

# 3. Run one-time setup scripts (as root)
sudo bash ~/uye-runner/scripts/setup-egress-policy.sh
sudo systemctl restart docker   # activates the Docker address pool change
sudo bash ~/uye-runner/scripts/setup-apparmor.sh
# Verify: aa-status | grep uye-runner

# 4. Clone and configure (as ghrunner)
git clone https://github.com/YOUR_ORG/uye-runner ~/uye-runner
cd ~/uye-runner
cp .env.example .env
$EDITOR .env   # required: GITHUB_TOKEN, GITHUB_ORG, COMPOSE_PROJECT_NAME
               # recommended: RUNNER_SECCOMP_HOST_PATH

# 5. Start
docker compose pull      # pulls controller-proxy, deployer-proxy, controller, deployer
docker compose up -d

# 6. Verify
docker compose logs -f controller | jq .
# → {"level":"info","svc":"controller","msg":"Runner is live","job_id":"..."}
```

### Required GitHub setting

**Settings → Actions → General → Fork pull request workflows →
"Require approval for all outside collaborators"**

This prevents PR workflows from unknown contributors from queuing at all.

---

## Day-to-day operations

```bash
# Follow logs (JSON — pipe through jq for readability)
docker compose logs -f controller | jq .
docker compose logs -f deployer   | jq .

# Check health endpoint
curl -s http://localhost:8080/health | jq .

# List all live per-job containers
docker ps --filter label=runner-managed=true

# Respawn runners (e.g. after changing RUNNER_LABELS or limits in .env)
docker compose restart controller

# Full teardown — in-progress jobs are interrupted
docker compose down

# Local build + start (after code changes in this repo)
docker compose build
docker compose up -d
```

---

## Updating the runner binary

Bump `ARG RUNNER_VERSION` in `Dockerfile`, push to `main`. CI rebuilds all three images;
the deployer verifies and applies the update within `POLL_INTERVAL` seconds.

```dockerfile
ARG RUNNER_VERSION=2.324.0   # ← bump here
```

Latest releases: https://github.com/actions/runner/releases

---

## GitHub PAT scopes required

**Must use a classic token.** Fine-grained PATs do not support `manage_runners:org`.

Create at: **github.com/settings/tokens → Tokens (classic)**

| Scope | Why |
|---|---|
| `manage_runners:org` | Register/deregister org-level runners |
| `admin:org` | Required alongside `manage_runners:org` |
| `read:packages` | Pull runner image from GHCR (if package is private) |

The `GITHUB_TOKEN` used in the CI workflow (built-in) only needs `packages: write`
(granted automatically). It is a different token from the PAT in `.env`.

---

## Security notes

- **No privileged containers in the job path.** Kaniko builds images in userspace without
  `--privileged`. The DinD host-escape vector is eliminated entirely.
- **`GITHUB_TOKEN` (PAT) never enters runner containers.** Only the controller holds it.
  Runners receive only a short-lived registration token that expires after one use.
- **`--ephemeral` ensures single-use.** Even if a job attempts to persist a backdoor in
  the container filesystem, the container is destroyed before any subsequent job runs.
- **Docker socket proxies** (`tecnativa/docker-socket-proxy@sha256:1f3a6...`) sit between each service
  and `/var/run/docker.sock`. Controller and deployer connect via `DOCKER_HOST=tcp://proxy:2375`.
  `EXEC` and `BUILD` are disabled on both proxies — these are the primary escape vectors.
  The proxy containers themselves still mount the raw socket (unavoidable); they are minimal,
  versioned, and tracked by Dependabot.
- **Seccomp** blocks kernel-level syscalls (`mount`, `kexec_*`, `bpf`, kernel modules)
  that are the basis of most container escape techniques.
- **AppArmor profile** (`apparmor/uye-runner`) is applied to every runner container via
  `--security-opt apparmor=uye-runner`. It denies dangerous capabilities (`sys_module`,
  `sys_admin`, `net_raw`), raw/packet sockets, writes to kernel tunables and sysfs, and
  access to host credential files. Load with `scripts/setup-apparmor.sh` before first start.
  Set `RUNNER_APPARMOR_PROFILE=` (empty) in `.env` to disable.
- **Resource limits** prevent crypto mining or denial-of-service against the host.
- **Network egress is restricted.** `scripts/setup-egress-policy.sh` allocates job networks
  from `10.89.0.0/16` and adds iptables `DOCKER-USER` rules allowing only DNS (53) and
  HTTPS (443) from that subnet. Private RFC 1918 ranges are explicitly blocked.
- **Image signatures.** CI signs all three images (runner, controller, deployer) with cosign
  keyless signing tied to the workflow's GitHub Actions OIDC identity. The deployer verifies
  every image signature before pulling or applying. A verification failure immediately sets
  the health endpoint to `503` and skips the update.
- **Workflow `GITHUB_TOKEN` scope must be minimised in downstream workflows.** Declare a
  `permissions:` block in every workflow, and set the org-level default to read-only at
  **Settings → Actions → General → Workflow permissions**.
- **Structured JSON logging.** Both controller and deployer emit newline-delimited JSON
  (`ts`, `level`, `svc`, `msg`, plus contextual fields). Pipe through `jq` or ingest with
  any log aggregator that reads Docker container logs.
- **Health endpoint.** `GET :<HEALTH_PORT>/health` returns `200 {"status":"ok"}` during
  normal operation and `503 {"status":"unhealthy","reason":"..."}` after a signature
  verification failure or compose error. Poll with UptimeRobot, Grafana, etc.
- **The `.env` file contains a PAT — it is gitignored. Never commit it.**
- **Remaining open threats:** proxy containers have full socket access (mitigated by being
  minimal and versioned); `$GITHUB_WORKSPACE` disk is unconstrained.
