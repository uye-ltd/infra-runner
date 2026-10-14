# Deployer Plugin System

The deployer scans `PLUGINS_DIR` (default: `/plugins/`) for `*.plugin` descriptor files on
every poll cycle. Each descriptor is a shell-sourceable key=value file that tells the deployer
which image to watch, how to verify its signature, how to update the service, and what
post-deploy hooks to run.

External projects ship their own descriptor and a Compose overlay — infra-runner requires
no changes when a new plugin is added.

---

## Descriptor format

```bash
# Required fields
PLUGIN_NAME=my-service           # unique identifier; alphanumerics and hyphens only
PLUGIN_IMAGE=ghcr.io/org/my-service:latest
PLUGIN_CERT_IDENTITY=https://github.com/org/my-service/.github/workflows/deploy.yml@refs/heads/main
PLUGIN_COMPOSE_PROJECT=my-project          # docker compose --project-name
PLUGIN_COMPOSE_DIR=/workspace-my-service   # container-side path to the external project
PLUGIN_COMPOSE_SERVICE=my-service          # service name passed to docker compose up

# Optional: env var names (space/comma separated) passed to hook scripts — see below
PLUGIN_HOOK_ENV="MY_API_TOKEN MY_SERVICE_URL"

# Post-deploy hooks (optional, indexed from 0)
# PLUGIN_POST_DEPLOY_N_SCRIPT    path relative to PLUGIN_COMPOSE_DIR
# PLUGIN_POST_DEPLOY_N_RUN       always | on_update  (default: on_update)
# PLUGIN_POST_DEPLOY_N_BLOCKING  true | false       (default: true)
# PLUGIN_POST_DEPLOY_N_TIMEOUT   seconds, 1–3600    (default: PLUGIN_HOOK_TIMEOUT, 300)
#
# run: always    → script runs every poll cycle regardless of whether a new image was deployed
# run: on_update → script runs after the service was recreated on a new verified image, and
#                  again every cycle while a blocking on_update hook keeps failing
# blocking: false → failure is logged as a warning; does NOT set the health endpoint to unhealthy
PLUGIN_POST_DEPLOY_0_SCRIPT=scripts/post-deploy.sh
PLUGIN_POST_DEPLOY_0_RUN=always
PLUGIN_POST_DEPLOY_0_BLOCKING=false
```

**The descriptor is parsed as data — it is never `source`d.** Supported syntax:

- `KEY=VALUE` lines (an `export ` prefix is allowed), blank lines and `#` comments;
- `"double quotes"` → variables are expanded; `'single quotes'` → literal;
- unquoted values: a trailing ` # comment` is stripped;
- `${NAME}` / `$NAME` expand from the deployer's **exported** environment (everything in
  infra-runner's `.env`), e.g. `PLUGIN_CERT_IDENTITY=${MY_CERT_IDENTITY}`. Nothing else is
  evaluated — `$(…)`, backticks and arithmetic stay literal text;
- unknown keys are ignored with a warning.

---

## How the deployer processes a descriptor

Every cycle, for each `*.plugin` file in `PLUGINS_DIR`:

1. `cosign verify PLUGIN_IMAGE` with `PLUGIN_CERT_IDENTITY` → the digest cosign verified.
2. Pull exactly that digest (if not already present) and tag it as `PLUGIN_IMAGE` and
   `<repo>:verified`. An unverified image is never pulled.
3. If the plugin service container (found via compose labels `PLUGIN_COMPOSE_PROJECT` /
   `PLUGIN_COMPOSE_SERVICE`) is not running that image:
   `docker compose --project-name PLUGIN_COMPOSE_PROJECT --project-directory PLUGIN_COMPOSE_DIR up -d --no-deps PLUGIN_COMPOSE_SERVICE`
   — retried every cycle until it succeeds (also after a deployer restart).
4. Confirm the service is running on the verified image. An inspection failure keeps an
   `on_update` hook pending for the next cycle.
5. Post-deploy hooks run per their `run` and `blocking` rules. A pending `on_update` hook
   is retried while the deployer stays up; a deployer restart loses that pending state.

Verification, pull, compose and blocking-hook failures set `/health` to 503.
A malformed descriptor (missing required fields or invalid `PLUGIN_NAME`) and duplicate
`PLUGIN_NAME` also set `/health` to 503. Other plugins continue to reconcile.
Unknown descriptor keys are ignored with a warning.

**Requirements for the plugin's own compose file:** the service's `image:` must be exactly
`PLUGIN_IMAGE`, and it must not set `pull_policy: always` (which would pull the tag from the
registry, bypassing verification). The deployer re-checks the container after `compose up` and
reports 503 if it is still not on the verified image.

---

## Hook script environment

Hooks run as `timeout --kill-after=5s <N> env -i <allowlist> bash <script>`:

- always passed: `PATH`, `HOME`, `DOCKER_HOST` (hooks can use the Docker API through the
  deployer's socket proxy), `PLUGIN_NAME`, `PLUGIN_COMPOSE_DIR`;
- plus the variables named in the descriptor's `PLUGIN_HOOK_ENV` and in `PLUGIN_HOOK_ENV` from
  infra-runner's `.env` (operator-wide). `GITHUB_TOKEN` and `GITHUB_APP_*` are never passed
  directly, even when named in an allowlist.
- **Legacy:** if neither allowlist is set, the hook gets the deployer's full environment
  **except** `GITHUB_TOKEN` and `GITHUB_APP_*`, and the deployer logs a warning once per plugin.
  Declare `PLUGIN_HOOK_ENV` to silence it.

**Trust boundary.** Hook scripts are unsigned code from the on-server checkout of the plugin
repo, running inside the deployer with Docker API access (effectively root on the host). Only
register plugins whose repositories you trust as much as infra-runner itself, protect the
branch the server's `git pull` cron follows, and consider `git verify-commit` in that cron.

---

## How to register a plugin

### 1. Create the descriptor in your project repo

```bash
# .infra-runner.plugin  (at the root of your project repo)
PLUGIN_NAME=my-service
PLUGIN_IMAGE=ghcr.io/${GITHUB_ORG}/my-service:latest
PLUGIN_CERT_IDENTITY=${MY_SERVICE_CERT_IDENTITY}
PLUGIN_COMPOSE_PROJECT=my-project
PLUGIN_COMPOSE_DIR=/workspace-my-service
PLUGIN_COMPOSE_SERVICE=my-service
```

### 2. Create the Compose overlay in your project repo

```yaml
# docker-compose.infra-runner.yml  (at the root of your project repo)
# This file extends infra-runner's deployer service with the mounts your plugin needs.
services:
  deployer:
    volumes:
      - ${MY_PROJECT_DIR}:/workspace-my-service:ro
      - ${MY_PROJECT_DIR}/.infra-runner.plugin:/plugins/my-service.plugin:ro
```

### 3. Activate on the server

In infra-runner's `.env`:

```bash
# List every base file explicitly — once COMPOSE_FILE is set, Compose no longer
# auto-discovers docker-compose.override.yml (drop it if you have none).
COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:../my-project/docker-compose.infra-runner.yml
MY_PROJECT_DIR=/home/ghrunner/my-project
MY_SERVICE_CERT_IDENTITY=https://github.com/org/my-service/.github/workflows/deploy.yml@refs/heads/main
```

Then apply the new mounts:

```bash
docker compose up -d --no-deps deployer
```

---

## Worked example: infra-vault

infra-vault registers itself as a plugin to get GitOps updates for its `vault-unseal` service
and continuous Vault policy sync.

**infra-vault repo — `.infra-runner.plugin`:**

```bash
PLUGIN_NAME=vault-unseal
PLUGIN_IMAGE=ghcr.io/${GITHUB_ORG}/vault-unseal:latest
PLUGIN_CERT_IDENTITY=${VAULT_CERT_IDENTITY}
PLUGIN_COMPOSE_PROJECT=infra-vault
# docker/ subdir: holds docker-compose.yml and (on the server) .env. The deployer runs
# `docker compose --project-directory <this>` with no -f/--env-file, so the compose file
# and docker/.env (VAULT_UNSEAL_KEY) must both live here.
PLUGIN_COMPOSE_DIR=/workspace-vault/docker
PLUGIN_COMPOSE_SERVICE=vault-unseal
PLUGIN_HOOK_ENV="VAULT_TOKEN VAULT_ADDR VAULT_NET VAULT_COMPOSE_DIR"

PLUGIN_POST_DEPLOY_0_SCRIPT=../scripts/apply-policies.sh
PLUGIN_POST_DEPLOY_0_RUN=always
PLUGIN_POST_DEPLOY_0_BLOCKING=false
```

**infra-vault repo — `docker-compose.infra-runner.yml`:**

```yaml
services:
  deployer:
    volumes:
      - ${VAULT_COMPOSE_DIR}:/workspace-vault:ro
      - ${VAULT_COMPOSE_DIR}/.infra-runner.plugin:/plugins/vault-unseal.plugin:ro
```

**infra-runner `.env` additions:**

```bash
# Once COMPOSE_FILE is set, Compose stops auto-discovering docker-compose.override.yml —
# list every file you rely on explicitly.
COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:../infra-vault/docker-compose.infra-runner.yml
VAULT_COMPOSE_DIR=/home/ghrunner/infra-vault
# The vault-unseal image is signed by infra-vault's ci.yml (the build+sign job lives there),
# so the cosign identity is ci.yml — NOT deploy.yml.
VAULT_CERT_IDENTITY=https://github.com/uye-ltd/infra-vault/.github/workflows/ci.yml@refs/heads/main
VAULT_TOKEN=hvs.XXXX
VAULT_ADDR=http://vault:8200
VAULT_NET=vault-net
```

**infra-vault repo — `scripts/apply-policies.sh`** (the post-deploy hook):

```bash
#!/bin/bash
set -euo pipefail
: "${VAULT_TOKEN:?VAULT_TOKEN required}"
: "${VAULT_COMPOSE_DIR:?VAULT_COMPOSE_DIR required}"
VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
VAULT_NET="${VAULT_NET:-vault-net}"

docker run --rm \
  --network "${VAULT_NET}" \
  -e VAULT_ADDR="${VAULT_ADDR}" \
  -e VAULT_TOKEN="${VAULT_TOKEN}" \
  -v "${VAULT_COMPOSE_DIR}/vault/policies:/policies:ro" \
  hashicorp/vault:1.17 \
  sh -c 'set -e; for f in /policies/*.hcl; do
    name=$(basename "$f" .hcl); vault policy write "$name" "$f"; echo "Applied: $name"
  done' \
  || { echo "Vault policy sync failed — Vault may be sealed" >&2; exit 1; }
```

The `-v` bind-mount uses `VAULT_COMPOSE_DIR` as a **host** path. Docker resolves it on the
host, not inside the deployer container, so the deployer does not need to mount the policies
directory itself.
