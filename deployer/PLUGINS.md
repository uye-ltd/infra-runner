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
PLUGIN_NAME=my-service           # unique identifier; alphanumeric and hyphens only
PLUGIN_IMAGE=ghcr.io/org/my-service:latest
PLUGIN_CERT_IDENTITY=https://github.com/org/my-service/.github/workflows/deploy.yml@refs/heads/main
PLUGIN_COMPOSE_PROJECT=my-project          # docker compose --project-name
PLUGIN_COMPOSE_DIR=/workspace-my-service   # container-side path to the external project
PLUGIN_COMPOSE_SERVICE=my-service          # service name passed to docker compose up

# Post-deploy hooks (optional, indexed from 0)
# PLUGIN_POST_DEPLOY_N_SCRIPT  path relative to PLUGIN_COMPOSE_DIR
# PLUGIN_POST_DEPLOY_N_RUN     always | on_update  (default: on_update)
# PLUGIN_POST_DEPLOY_N_BLOCKING  true | false       (default: true)
#
# run: always   → script runs every poll cycle regardless of whether a new image was deployed
# run: on_update → script runs only when a new image was pulled and deployed
# blocking: false → failure is logged as a warning; does NOT set the health endpoint to unhealthy
PLUGIN_POST_DEPLOY_0_SCRIPT=scripts/post-deploy.sh
PLUGIN_POST_DEPLOY_0_RUN=always
PLUGIN_POST_DEPLOY_0_BLOCKING=false
```

Variables expand from the deployer's environment at source time, so you can reference
env vars that are set in `.env` (e.g. `PLUGIN_CERT_IDENTITY=${MY_CERT_IDENTITY}`).

---

## How the deployer processes a descriptor

For each `*.plugin` file found in `PLUGINS_DIR`:

1. `pull_if_new PLUGIN_IMAGE` — returns non-zero if no new digest; hooks still run if `run: always`
2. `verify_image PLUGIN_IMAGE PLUGIN_CERT_IDENTITY` — cosign keyless verify; sets unhealthy on failure
3. `docker compose --project-name PLUGIN_COMPOSE_PROJECT --project-directory PLUGIN_COMPOSE_DIR up -d --no-deps PLUGIN_COMPOSE_SERVICE`
4. Post-deploy hooks run per their `run` and `blocking` rules

A malformed descriptor (missing required fields or source errors) is skipped with a `warn` log.
The deployer continues to the next descriptor — one bad plugin does not block others.

---

## Hook script environment

Hook scripts inherit the deployer's full environment. All variables from `.env` are available,
including any plugin-specific vars you add (e.g. `VAULT_TOKEN`, `VAULT_ADDR`). Scripts must
be executable or invoked explicitly with `bash` (the deployer calls `bash <script>`).

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
COMPOSE_FILE=docker-compose.yml:../my-project/docker-compose.infra-runner.yml
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
PLUGIN_COMPOSE_DIR=/workspace-vault
PLUGIN_COMPOSE_SERVICE=vault-unseal

PLUGIN_POST_DEPLOY_0_SCRIPT=scripts/apply-policies.sh
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
COMPOSE_FILE=docker-compose.yml:../infra-vault/docker-compose.infra-runner.yml
VAULT_COMPOSE_DIR=/home/ghrunner/infra-vault
VAULT_CERT_IDENTITY=https://github.com/uye-ltd/infra-vault/.github/workflows/deploy.yml@refs/heads/main
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
