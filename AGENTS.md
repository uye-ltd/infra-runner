# AGENTS.md — infra-runner

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
├── Dockerfile                        # runner image (ubuntu:24.04 + Docker CLI + Buildah + fuse-overlayfs + Kaniko compat + GH runner binary)
├── entrypoint.sh                     # runner startup: accept token → config --ephemeral → run.sh
├── docker-compose.yml                # four services: two socket proxies + controller + deployer
├── .env.example                      # template for required env vars (copy → .env)
├── .gitignore
├── apparmor/
│   └── infra-runner                    # AppArmor profile applied to every runner container
├── controller/
│   ├── Dockerfile                    # controller image (ubuntu:24.04 + docker-ce-cli + jq + openssl + uuidgen)
│   └── entrypoint.sh                 # pool manager: spawn/teardown ephemeral runners
├── deployer/
│   ├── Dockerfile                    # deployer image (ubuntu:24.04 + docker-ce-cli + compose + cosign + python3)
│   ├── entrypoint.sh                 # GitOps loop: verify sig → pull → docker compose up -d
│   ├── health_server.py              # minimal Python HTTP server for GET /health
│   └── PLUGINS.md                    # plugin descriptor format reference + worked example
├── scripts/
│   ├── bootstrap-images.sh           # first start / recovery: cosign-verify, pull by digest, tag :verified
│   ├── ghcr-login.sh                 # GHCR login with classic PAT for private packages
│   ├── ghcr-auth.sh                  # deployer Docker auth config writer
│   ├── github-app-token.sh           # GitHub App JWT helper (sourced by controller): RS256 JWT → installation token
│   ├── logging.sh                    # shared structured JSON log() function (sourced by controller + deployer)
│   ├── promote-images.sh             # verify all :sha candidates, then promote signed digests to :latest
│   ├── setup-apparmor.sh             # one-time: install + load AppArmor profile
│   └── setup-egress-policy.sh        # one-time, idempotent: iptables chains INFRA-RUNNER-FWD/-IN for the runner range
├── seccomp/
│   └── runner-profile.json           # seccomp: default-ALLOW + small deny-list (replaces Docker's default profile)
├── tests/
│   ├── run.sh                        # runs the suite in a container (same locally and in CI)
│   ├── Dockerfile                    # test env: ubuntu + bats + jq + python3
│   ├── controller.bats               # controller reconcile logic vs stubbed docker / GitHub API
│   ├── deployer.bats                 # deployer reconcile + plugin logic vs stubbed docker / cosign
│   ├── bootstrap-images.bats        # first-start digest verification vs stubbed Docker / cosign
│   ├── promote-images.bats           # release promotion gate vs stubbed cosign / Docker
│   ├── ghcr-login.bats               # host GHCR login auth path vs stubbed Docker
│   ├── ghcr-auth.bats                # deployer Docker auth config writer
│   ├── test_health_server.py         # health server (stdlib unittest)
│   └── stubs/{controller,deployer,ghcr,promotion}/  # fake docker, cosign, curl, uuidgen
├── .hadolint.yaml
└── .github/
    ├── dependabot.yml                # weekly PRs: Dockerfiles, docker-compose.yml, Actions
    └── workflows/
        ├── ci.yml                    # lint (shellcheck, hadolint, actionlint, zizmor, compose config) + tests
        ├── deploy.yml                # PR: build + trivy; main: build, push, cosign-sign by digest
        └── runner-version.yml        # weekly: fail if actions/runner is newer than ARG RUNNER_VERSION
```

---

## Architecture

```
docker-compose (fixed service subnets in 172.20.0.0/16)
│
├── controller-proxy  (tecnativa/docker-socket-proxy — 172.20.0.0/26)
│   └── /var/run/docker.sock:ro  ← filters API; EXEC + BUILD disabled
│
├── controller  (infra-runner-controller — 172.20.0.64/26)
│   ├── DOCKER_HOST=tcp://controller-proxy:2375  ← no direct socket mount
│   └── env: GITHUB_APP_* (or GITHUB_TOKEN fallback), GITHUB_ORG, RUNNER_IMAGE, pool/limit settings
│
├── deployer-proxy  (tecnativa/docker-socket-proxy — 172.20.128.0/26)
│   └── /var/run/docker.sock:ro  ← same API filtering
│
└── deployer  (uye-deployer — 172.20.128.64/26)
    ├── DOCKER_HOST=tcp://deployer-proxy:2375  ← no direct socket mount
    ├── ./:/workspace:ro  ← reads docker-compose.yml + .env for docker compose up
    ├── /plugins/*.plugin:ro  ← plugin descriptors (bind-mounted by plugin overlays)
    └── :HEALTH_PORT  ← GET /health endpoint

Per job — created by controller, destroyed after job completes:
├── runner-net-{id}     isolated bridge network (10.89.x.x/24, egress-restricted)
└── runner-job-{id}     ephemeral runner (Buildah + fuse-overlayfs for image builds)
```

The runner container has no Docker socket and no privileged flag. Image builds use
**Buildah** with **fuse-overlayfs** storage, which builds OCI images entirely in userspace
without a daemon or a privileged container. The `kaniko` binary is also present for
backward compatibility with existing workflows. The controller's GitHub credential (App
installation token or PAT) never enters runner containers — runners receive only a
a single-use JIT runner config (see *Security notes*).

---

## Environment variables

Set in `.env`. The deployer loads the whole file (`env_file`, plugin hooks need arbitrary vars);
the controller receives only the variables listed in its compose `environment:` block — add new
controller settings there.

**Authentication** — exactly one of the following two paths must be configured:

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `GITHUB_APP_ID` | App path | — | Numeric GitHub App ID |
| `GITHUB_APP_INSTALLATION_ID` | App path | — | Numeric installation ID (org-level install) |
| `GITHUB_APP_PRIVATE_KEY_PATH` | App path | — | Container path to the PEM key (mounted `:ro`) |
| `GITHUB_TOKEN` | PAT path | — | Classic PAT fallback: `admin:org`, `manage_runners:org`, `read:packages` |
| `GHCR_USERNAME` | PAT path | — | GitHub account that owns the PAT; used for GHCR authentication |

If `GITHUB_TOKEN` is set it is used as-is, `GHCR_USERNAME` is required by the deployer,
and the `GITHUB_APP_*` vars are ignored. If it is unset all three `GITHUB_APP_*` vars are
required. The controller mints a short-lived installation access token at startup and
refreshes it every 55 minutes.

**All other variables:**

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `GITHUB_ORG` | yes | — | GitHub org slug (e.g. `acme`) |
| `GITHUB_REPO` | no | `infra-runner` | Repo name; used to construct cosign certificate identity |
| `RUNNER_LABELS` | no | `self-hosted,linux,x64` | Comma-separated runner labels |
| `DESIRED_IDLE` | no | `2` | Idle runners to keep ready (busy runners are not counted; idle/busy comes from the GitHub API). 0–256 and at most `MAX_RUNNERS` |
| `MAX_RUNNERS` | no | `DESIRED_IDLE` | Hard cap on runner containers, idle + busy. Raise above `DESIRED_IDLE` to keep runners warm while jobs execute. 0–256 because the runner `/16` has 256 `/24` networks |
| `RUNNER_PIDS_LIMIT` | no | `4096` | `--pids-limit` per runner container (fork-bomb guard) |
| `RUNNER_REGISTRATION_MODE` | no | `jit` | `jit` (single-use JIT config) or `token` (legacy registration token, reusable for 1 h) |
| `RUNNER_GROUP_ID` | no | `1` | Runner group for JIT registration (`1` = Default) |
| `SHUTDOWN_CLEANUP` | no | `idle` | On controller stop: `idle` (remove idle runners, let busy ones finish), `all`, or `none` |
| `RUNNER_MEMORY` | no | `4g` | Memory limit per runner container |
| `RUNNER_CPUS` | no | `2` | CPU limit per runner container |
| `RUNNER_KANIKO_SIZE` | no | `5g` | tmpfs size for `/kaniko` inside runner — used as Buildah's `graphRoot` (image layer storage) and Kaniko scratch space |
| `RUNNER_APPARMOR_PROFILE` | no | `infra-runner` | AppArmor profile name; empty to disable |
| `RUNNER_SECCOMP_HOST_PATH` | no | — | Path to `seccomp/runner-profile.json` **inside the controller**. The docker CLI reads the file client-side and sends its contents to the daemon; compose mounts the repo's profile at `/home/ghrunner/infra-runner/seccomp/runner-profile.json`, which is why the usual value looks like a host path |
| `RUNNER_SUBNET_PREFIX` | no | `10.89` | Job networks get explicit /24s from `<prefix>.0.0/16`; keep in sync with `RUNNER_SUBNET` of `setup-egress-policy.sh` |
| `GITHUB_APP_PRIVATE_KEY_HOST_PATH` | no | `/home/ghrunner/.ssh/github-app.pem` | Host path of the App key, mounted into the controller |
| `HEALTH_BIND` | no | `0.0.0.0` | Host address `HEALTH_PORT` is published on (`127.0.0.1` = local only) |
| `COMPOSE_PROJECT_NAME` | yes | `infra-runner` | Compose project name; the deployer uses it for compose calls, container lookup (labels) and the helper's network name. Keep it stable |
| `POLL_INTERVAL` | no | `60` | Deployer digest check interval (5–3600 seconds) |
| `HEALTH_PORT` | no | `8080` | Deployer health endpoint port (1–65535) |
| `CONTROLLER_POLL_INTERVAL` | no | `15` | Controller pool maintenance cycle interval (seconds) |
| `SELF_UPDATE_TIMEOUT` | no | `120` | Max seconds to wait for the deployer self-update helper (3–3600) |
| `PLUGIN_HOOK_TIMEOUT` | no | `300` | Default timeout (s) for plugin post-deploy hooks (1–3600) |
| `PLUGIN_HOOK_ENV` | no | — | Space/comma-separated env var names passed to all plugin hooks (in addition to the descriptor's own `PLUGIN_HOOK_ENV`) |
| `HEALTH_MAX_AGE` | no | `3×POLL_INTERVAL + SELF_UPDATE_TIMEOUT + PLUGIN_HOOK_TIMEOUT` | `/health` returns 503 `stale` when no cycle finished within this many seconds (1–86400) |
| `PRUNE_INTERVAL` | no | `3600` | Min seconds between dangling-image prunes (60–86400) |

**Plugin system** (all optional; each plugin activates via its own Compose overlay):

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `PLUGINS_DIR` | no | `/plugins/` | Container path scanned for `*.plugin` descriptor files each cycle |
| `COMPOSE_FILE` | per-plugin | `docker-compose.yml` | Append plugin overlays, e.g. `docker-compose.yml:../infra-vault/docker-compose.infra-runner.yml` |

Plugin-specific env vars (e.g. `VAULT_TOKEN`, `VAULT_ADDR`) are declared in `.env` and
passed to post-deploy hook scripts via the deployer's inherited environment.

**Vault plugin variables** (required when the vault-unseal plugin descriptor is active):

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `VAULT_COMPOSE_DIR` | yes (vault) | — | Absolute host path to infra-vault checkout |
| `VAULT_TOKEN` | yes (vault) | — | Vault operator token for policy sync (stays on server) |
| `VAULT_ADDR` | no | `http://vault:8200` | Vault address reachable on vault-net |
| `VAULT_NET` | no | `vault-net` | Docker network Vault is on |

`RUNNER_IMAGE`, `DOCKER_HOST`, `HOOK_STATE_DIR` and `HOOK_STATE_REQUIRED` are set in the Compose `environment`
block (not `.env`) and must not be overridden there.

`RUNNER_SECCOMP_HOST_PATH` is read by the docker CLI **inside the controller** (it uploads the
profile's contents), so it must point at the compose-mounted copy. Leave empty to fall back to
Docker's default seccomp profile.

---

## Dockerfile details (runner image)

- **Base**: `ubuntu:24.04`
- **Build args**: `RUNNER_VERSION` (default `2.334.0`) and `RUNNER_SHA256` (SHA256 of the tarball).
  Both must be updated together when bumping the runner — see *Updating the runner binary* below.
- **Docker CLI**: `docker-ce-cli` only — no daemon. Used for `docker login` (writes registry
  credentials to `~/.docker/config.json`). `docker build`/`run`/`push` have no daemon to reach.
- **Buildah + fuse-overlayfs**: primary daemonless image builder. Installed via `apt-get`.
  `/etc/containers/storage.conf` sets `driver=overlay`, `graphroot=/kaniko`,
  `runroot=/tmp/buildah-run` and `mount_program=/usr/bin/fuse-overlayfs`. Workflows call `buildah build` and `buildah push`.
- **Kaniko**: `COPY --from=ghcr.io/kaniko-build/dist/chainguard-forks-kaniko/executor:v1.25.14@sha256:…`
  — kept for backward compat with existing workflows. Built from the Chainguard community fork
  of the original (Google archived on 2025-06-03); published by the `kaniko-build` org.
  Tag + digest pinned.
- **Base images**: all three Dockerfiles use `ubuntu:24.04@sha256:…` (Dependabot bumps tag + digest).
- **cosign / Vault CLIs**: downloaded by version and verified against a SHA256 pinned in the
  Dockerfile (`COSIGN_SHA256`, `VAULT_SHA256`) — not against a checksum file from the same source.
- **Runner binary**: downloaded from `github.com/actions/runner/releases`, SHA256-verified
  before extraction, then extracted to `/opt/actions-runner/`.
- **User**: root — required by Buildah and Kaniko to extract image layers and execute `RUN`
  instructions. Container-level controls (seccomp, AppArmor, resource limits, no Docker socket,
  ephemeral) are the security boundary. The controller adds `CHOWN`, `DAC_OVERRIDE`, `FOWNER`,
  `SETUID`, `SETGID` (layer extraction, e.g. `/etc/shadow` root:shadow 640) **and `SYS_PTRACE`,
  `SYS_ADMIN`** (Buildah's user-namespace setup with the full-range `/etc/subuid` mapping) at
  spawn time. See README → *Threat model* for what `SYS_ADMIN` implies.
- **Entrypoint**: `entrypoint.sh`

---

## entrypoint.sh walkthrough (runner image)

```
JIT mode (default):  RUNNER_JITCONFIG set
  1. copy it to a local, `unset RUNNER_JITCONFIG`
  2. exec ./run.sh --jitconfig <config>   ← already registered + ephemeral; no config.sh
Token mode (RUNNER_REGISTRATION_MODE=token):
  1. validate GITHUB_ORG + RUNNER_REGISTRATION_TOKEN, `unset RUNNER_REGISTRATION_TOKEN`
  2. ./config.sh --url … --token … --name … --labels … --unattended --ephemeral
  3. exec ./run.sh   ← PID 1; exits after exactly one job
```

The secret is removed from the environment before `run.sh`, so job steps never inherit it.
GITHUB_TOKEN is never present — the controller does not pass it to runners. The JIT config
stays visible in `run.sh`'s argv, which is acceptable: it is single-use and consumed before any
job step runs. Ephemeral runners deregister automatically after one job; no signal trap needed.

---

## controller/entrypoint.sh walkthrough

```
Startup:
  1. Validate env vars.
     Auth path A (preferred): GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID + GITHUB_APP_PRIVATE_KEY_PATH
       → source scripts/github-app-token.sh
       → acquire_github_token(): RS256 JWT → POST /app/installations/{id}/access_tokens
         → validate nonempty string token → GITHUB_TOKEN
     Auth path B (fallback): GITHUB_TOKEN set directly → used as-is, App flow skipped
  2. No GHCR login or image pull: the deployer maintains the local :verified runner image,
     and `docker run --pull never` uses that image even with private packages.
  3. ADOPT running runners from a previous controller run; remove only exited/dead/created
     runner containers and per-job networks whose container is gone.
     (Never `rm -f` running runners at startup — a controller restart/update must not abort jobs.)
  4. No image pull: the runner image is pulled only by the deployer after cosign verification.
     `docker run --pull never` — if the image is absent the controller logs and waits.

Main loop (every CONTROLLER_POLL_INTERVAL seconds, default 15) — reconcile():
  The loop never exits on an error: a failed step logs a warning and the cycle is retried.
  5. maybe_refresh_github_token()  ← App path: refresh at 55 min; on failure keep the old token, retry next cycle
  6. cleanup_dead_runners()        ← exited/dead/created runners → cleanup_job (+ deregister from GitHub)
     cleanup_orphan_networks() waits 120 s after network creation, then deregisters any
     GitHub runner whose exact name matches the orphaned network before removing it.
     Removal/API failures make the cycle unsuccessful and are retried; network labels
     preserve the runner name for retry. Older networks without a timestamp are cleaned
     immediately.
  7. load_org_runners()            ← GET /orgs/{org}/actions/runners → busy flag per runner-job-* name
                                      (API down/malformed page → cycle fails; running jobs remain untouched)
  8. Only a GitHub runner explicitly marked not busy counts as idle; the registration
     ID must also match when the container has a JIT ID label. Absent or mismatched
     registrations still count toward total. Then needed =
     min(DESIRED_IDLE - idle, MAX_RUNNERS - total); spawn in parallel and wait.
     Spawn failure → exponential backoff (poll interval × 2^n, max 300 s).
  9. touch /tmp/heartbeat on a successful cycle (compose healthcheck: stale > 5 min = unhealthy)
  sleep is interruptible (`sleep & wait`) so SIGTERM is handled immediately.

spawn_runner():
  a. uuidgen → job_id (10 lowercase hex chars)
  b. docker network create runner-net-{id}  (bridge, labelled runner-managed=true)
  c. jit mode:   POST /orgs/{org}/actions/runners/generate-jitconfig
                   {name: runner-job-{id}, runner_group_id, labels, work_folder}
                   → validate matching name, positive integer runner.id and non-empty
                     encoded_jit_config; store the ID as label runner-gh-id
     token mode: POST /orgs/{org}/actions/runners/registration-token
                 → require a nonempty string token before starting a container
  d. docker run -d --pull never runner image → runner-job-{id}
       --network runner-net-{id}  --memory --cpus --pids-limit
       --cap-add CHOWN DAC_OVERRIDE FOWNER SETUID SETGID SYS_PTRACE SYS_ADMIN
       [--security-opt seccomp=RUNNER_SECCOMP_HOST_PATH]
       [--security-opt apparmor=RUNNER_APPARMOR_PROFILE]
       --label runner-managed=true  runner-job-id={id}  runner-gh-id={gh id}  runner-role=runner
       -e RUNNER_JITCONFIG   (token mode: -e RUNNER_REGISTRATION_TOKEN GITHUB_ORG RUNNER_NAME RUNNER_LABELS)
       --tmpfs /tmp:rw,nosuid,size=1g
       --tmpfs /root:rw,nosuid,size=512m      (docker login credentials, runner config)
       --tmpfs /kaniko:rw,nosuid,size=RUNNER_KANIKO_SIZE  (Buildah graphRoot + Kaniko scratch space)
       --device /dev/fuse                                (required by fuse-overlayfs)
     Inspect the resulting container to confirm it is running. An immediate exit is
     cleaned up and backed off; an inspect/API failure leaves the container for the next
     reconcile because a job may already be running.
     Failed registration/run → cleanup_job (incl. deregistering the JIT runner).
  The runner entrypoint unsets the JIT config / registration token before `exec run.sh`,
  so job steps never inherit it.

cleanup_job(job_id [gh_id]):
  docker rm -f runner-job-{id}; docker network rm runner-net-{id}
  DELETE /orgs/{org}/actions/runners/{gh_id}  (404 = already gone, ignored)

shutdown() (SIGTERM/SIGINT), per SHUTDOWN_CLEANUP:
  idle (default) → remove runners GitHub reports as not busy (and whose JIT ID matches);
                   busy, absent and mismatched registrations remain for the next controller.
                   API down → leave everything.
  all            → remove every runner (interrupts jobs).   none → leave everything.
```

Logging: structured JSON to stdout (`ts`, `level`, `svc`, `msg`, plus contextual fields).
All per-job resources carry labels `runner-managed=true` and `runner-job-id={id}`;
job networks also carry `runner-created-at={epoch}` for orphan cleanup's 120 s grace.

---

## deployer/entrypoint.sh walkthrough

Level-triggered reconcile loop: every cycle re-reads desired state (the locally tagged
`:verified` image) and actual state (the running container's image) and applies the
difference. A failed deploy is therefore retried every cycle. Pending plugin `on_update`
hooks are stored in the `deployer-state` volume before `compose up`, so a deployer restart
does not discard them.

```
Startup:
  Validate env (COMPOSE_PROJECT_DIR required + absolute; numeric intervals).
  write_health starting (→ 503); start health_server.py.
  GITHUB_TOKEN (classic PAT) set → write GHCR auth with GHCR_USERNAME to /root/.docker/config.json.
  Otherwise → anonymous pulls (images must be public). The deployer needs no GitHub
  App credential: App installation tokens cannot access GHCR anyway.
  Remove a leftover self-update helper container.

Each cycle (run_cycle, every POLL_INTERVAL seconds; never exits the loop on errors):

  sync_image(REF, IDENTITY):                        ← shared by every component
    verify_remote:  cosign verify REF (:latest) → the digest cosign verified (_digest).
                    cosign stderr is logged; "no matching signatures / identity mismatch"
                    vs "could not complete" (network/registry) give different reasons.
    ensure_verified_local: docker pull REPO@DIGEST (only if absent) and docker tag it as
                    REPO:verified AND REPO:<watched tag>. Unverified content never lands
                    on the host, and the local :latest only ever points to a verified image.
    _desired_id = image ID of REPO:verified (the previous verified image if this
                  cycle's verification failed).

  1. deployer:   sync_image(uye-deployer:latest); actual = image of the compose container
                 (labels com.docker.compose.project/service). Differs → self_update():
                   docker run -d --entrypoint docker uye-deployer:verified \
                     compose --project-name P --project-directory DIR up -d --no-deps deployer
                   (argv, no shell string; mounts the project's PARENT at its real path and
                    runs with -w <project dir> so COMPOSE_FILE + sibling plugin overlays resolve)
                 Polls the helper every 3 s: exit≠0 → its last 20 log lines + 503 and the
                 cycle continues; exit 0 but still alive after 30 s → 503; SELF_UPDATE_TIMEOUT.
                 Success: compose stops us (SIGTERM → shutdown) and starts the replacement.
  2. controller: sync_image(infra-runner-controller:latest); differs →
                 docker compose -f /workspace/docker-compose.yml up -d --no-deps controller,
                 then confirm a running container uses the verified image (missing, inspect
                 failure or mismatch → 503).
  3. runner:     sync_image(infra-runner:latest) only — the controller spawns from :verified.
  4. plugins:    run_plugins() — see "Plugin system" below.
  5. No reasons recorded → write_health ok, then maybe_prune (dangling images older than
     24 h, at most every PRUNE_INTERVAL). Otherwise write_health unhealthy with all reasons.
  6. Interruptible sleep POLL_INTERVAL (SIGTERM handled immediately).
```

**Health semantics.** `set_unhealthy` writes `/tmp/health` immediately and records the
reason; the end-of-cycle write reports `ok` only if no reason was recorded. Because desired
vs actual is re-evaluated every cycle, a failing deploy keeps `/health` at 503 until it
succeeds — including across deployer restarts. The health server returns 503 `stale` if the
file is older than `HEALTH_MAX_AGE` (wedged loop), and the loop restarts the server if it dies.
Each managed Compose service has one running container; multiple matches for the same
project/service labels make inspection ambiguous and report 503 without an update attempt.

**Functions return data through globals** (`_digest`, `_desired_id`, `_actual_id`, `P[]`),
not `$(…)`: they call `set_unhealthy`, and a reason recorded inside a subshell would be lost.

**Migration from the tag-pull deployer.** Old servers update themselves: the old deployer
self-updates with the old compose file (`:latest`), and the new deployer's first cycle tags
everything `:verified`/`:latest`. After `git pull` of the new compose file run
`docker compose up -d` once. Fresh hosts use `scripts/bootstrap-images.sh`.

---

## Plugin system — constraints & gotchas

The plugin path was first exercised by [infra-vault](https://github.com/uye-ltd/infra-vault);
several latent deployer bugs surfaced and were fixed then (crash on the first plugin hook via
`(( i++ ))` under `set -e`; the deployer's own `COMPOSE_FILE` leaking into the plugin's compose
call; the self-update helper unable to resolve the plugin overlay; the controller-update path
hitting the same overlay-resolution failure). The rules below are load-bearing — breaking any of
them silently disables a plugin (or the deployer's own self/controller updates).

- **Image-only GitOps.** The deployer pulls new *images*; it never `git pull`s a plugin's
  workspace (or its own repo). A new signed image auto-deploys; changes to checked-out **repo
  content** — policy files, compose files, the `*.plugin` descriptor — take effect only after the
  on-server clone is updated (run a `git pull` cron for each plugin repo).
- **Images must be public on the GitHub-App auth path.** The deployer authenticates to GHCR
  only with a classic PAT (`GITHUB_TOKEN`); otherwise it pulls anonymously — this applies to
  plugin images too. For private packages use the PAT path (`GITHUB_TOKEN` + `scripts/ghcr-login.sh`).
- **The plugin's compose file must reference exactly `PLUGIN_IMAGE` and must not use
  `pull_policy: always`.** The deployer pulls the verified digest and re-tags it as
  `PLUGIN_IMAGE`'s tag; compose then starts that local image. A different ref or a forced pull
  would bypass verification — the deployer detects the mismatch after `compose up` and reports 503.
- **Descriptors are parsed as data, never `source`d.** `KEY=VALUE` lines, `${VAR}`/`$VAR`
  expanded from the deployer's exported environment, no command substitution; unknown keys are
  ignored with a warning. Missing required fields, invalid names and duplicate names set
  `/health` to 503 while other plugins continue.
- **Hooks are the trust boundary.** Hook scripts are unsigned code from the on-server checkout
  and run inside the deployer, which can reach the Docker API (= root on the host). Anyone who can
  push to a plugin repo that a `git pull` cron follows can execute code here — protect those
  branches (or verify signed commits in the cron). Hooks run under `env -i` with an allowlist
  (`PLUGIN_HOOK_ENV` in the descriptor and/or `.env`); without an allowlist they get the full
  environment **minus** `GITHUB_TOKEN`/`GITHUB_APP_*` (legacy, warns once). These credentials
  are also denied in explicit allowlists. Each hook has a
  timeout (`PLUGIN_POST_DEPLOY_N_TIMEOUT`, default `PLUGIN_HOOK_TIMEOUT=300`, 1–3600 s).
  Invalid hook timeouts mark health unhealthy, even for non-blocking hooks. A hook that
  ignores SIGTERM is killed 5 s after its timeout.
- **on_update hook retries are persistent.** The deployer writes a marker with the target
  image ID to `deployer-state` before changing a plugin service. An `on_update` hook runs
  only after that image is observed running. Inspection or blocking-hook failure keeps
  the marker across cycles and deployer restarts. A hook may rerun after a crash between
  its success and marker removal, so hook scripts must be idempotent.
- **`COMPOSE_FILE`'s relative entries resolve against the working directory, not
  `--project-directory`.** The deployer inherits `COMPOSE_FILE` from its `.env` (that's how a
  plugin overlay is activated), so every compose call must be shielded from it or run from the
  right CWD. Three guards in `deployer/entrypoint.sh` exist solely for this:
  - **plugin compose** runs with `env -u COMPOSE_FILE COMPOSE_PROJECT_NAME` (relies on the
    descriptor's own `--project-directory`);
  - **self-update helper** mounts the project's parent at its real path and runs with
    `-w <project-dir>` so `COMPOSE_FILE` + the sibling overlay resolve when recreating the deployer;
  - **controller update** (`COMPOSE` array) pins `-f /workspace/docker-compose.yml`
    (+ `override.yml` if present), bypassing `COMPOSE_FILE` entirely.
- **`PLUGIN_COMPOSE_DIR` must be the directory that holds the plugin's compose file *and* its
  `.env`** — Compose reads `.env` from the project directory, and the plugin's runtime secrets
  (e.g. `VAULT_UNSEAL_KEY`) come from there. Post-deploy hook `SCRIPT` paths are relative to
  `PLUGIN_COMPOSE_DIR` (infra-vault's compose lives in `docker/` but its scripts at repo root, so
  its hook is `../scripts/apply-policies.sh`).
- **`PLUGIN_CERT_IDENTITY` must name the workflow that *signs* the image**, and `cosign verify` is
  an **exact** identity match. infra-vault signs `vault-unseal` in `ci.yml`, so the identity is
  `.../infra-vault/.github/workflows/ci.yml@refs/heads/main` — not `deploy.yml`.

See `deployer/PLUGINS.md` for the descriptor format and a worked example.

---

## docker-compose.yml details

**Socket proxies** (`controller-proxy`, `deployer-proxy`)
- Image: `tecnativa/docker-socket-proxy@sha256:1f3a6...`
- Each mounts `/var/run/docker.sock:ro` and exposes port `2375` on an internal network
- Allowed API groups: `CONTAINERS`, `NETWORKS`, `IMAGES`, `POST`, `DELETE`, `INFO`
- Deployer proxy additionally allows: `VOLUMES`
- Disabled on both: `AUTH=0` (credentials travel per request, `/auth` is never called),
  `EXEC=0`, `BUILD=0`, `PLUGINS=0`, `SYSTEM=0`, `SWARM=0`, `SECRETS=0`
- The proxy filters API **paths**, not request bodies: `CONTAINERS`+`POST` still lets the client
  create a privileged container with host mounts. Controller and deployer are therefore
  host-root-equivalent; the proxy reduces the surface, it is not a sandbox.
- `security_opt: no-new-privileges`, `logging` capped (json-file 10 MB × 3)
- Resource limits: `memory: 128m`, `cpus: 0.25` — prevents a runaway proxy from affecting the host
- `restart: unless-stopped`

**controller service**
- Connects via `DOCKER_HOST=tcp://controller-proxy:2375` — no direct socket mount
- `depends_on: controller-proxy`
- `restart: unless-stopped`
- No registry credentials or `/root/.docker` tmpfs: the controller never pulls images
- **No `env_file`**: an explicit `environment:` allowlist interpolated from `.env`, so secrets
  meant for plugin hooks (e.g. `VAULT_TOKEN`) never reach the controller.
  `RUNNER_APPARMOR_PROFILE: ${RUNNER_APPARMOR_PROFILE-infra-runner}` uses `-` so an explicitly
  empty value disables AppArmor
- `volumes`: `seccomp/runner-profile.json` at the same path inside the container (the docker CLI
  reads the profile file client-side) and the App key from `GITHUB_APP_PRIVATE_KEY_HOST_PATH`
- `cap_drop: ALL`, `no-new-privileges`, logging capped; `stop_grace_period: 60s`
- `healthcheck`: heartbeat file younger than 5 min

**deployer service**
- Connects via `DOCKER_HOST=tcp://deployer-proxy:2375` — no direct socket mount
- `image: …/uye-deployer:verified`, `pull_policy: never` — `:verified` is a local tag set by
  the deployer after cosign verification (controller likewise; `RUNNER_IMAGE` is `:verified`)
- Mounts `${COMPOSE_PROJECT_DIR}:/workspace:ro` for `docker compose up` (reads compose file + `.env`);
  no GitHub App key (the deployer does not need one)
- Publishes `HEALTH_PORT` on `HEALTH_BIND` (default `0.0.0.0`; `127.0.0.1` keeps it local —
  Docker-published ports bypass ufw)
- `cap_drop: ALL`, `no-new-privileges`, logging capped
- Self-update helper mounts only the project dir and the directories of the `COMPOSE_FILE`
  entries (read-only, at their host paths) — not the whole home directory
- `depends_on: deployer-proxy`
- `restart: unless-stopped`
- `tmpfs: /root/.docker` — GHCR credentials written here (ephemeral, never touches overlay fs)
- `healthcheck`: `GET /health` every 30s (`start_period: 120s`). Docker only marks the
  container unhealthy — it does **not** restart it; alert on `/health` externally

**Networks** (fixed subnets in 172.20.0.0/16, outside the 10.89.0.0/16 runner range):
- `controller-proxy-net`: 172.20.0.0/26 — controller-proxy ↔ controller only
- `controller-net`: 172.20.0.64/26 — controller egress (internet, GitHub API)
- `deployer-proxy-net`: 172.20.128.0/26 — deployer-proxy ↔ deployer only
- `deployer-net`: 172.20.128.64/26 — deployer egress (internet, GHCR)

**Named volume:** `deployer-state` stores plugin hook retry markers. Runner jobs still use
tmpfs only. Per-job networks are created by the controller
with an explicit `--subnet` `<RUNNER_SUBNET_PREFIX>.<n>.0/24` (third octet derived from the job
id, moved on overlap through all 256 `/24` candidates), so only runner networks fall into the egress-restricted range.
The deployer checks that its hook state path is a mount point before processing plugins,
so a new image started with an older Compose file cannot silently lose pending retries.

**Plugin overlays** — external projects ship their own `docker-compose.infra-runner.yml` that
extends the deployer service with the mounts their plugin needs (the `*.plugin` descriptor file
and their compose workspace). Activated by appending the overlay path to `COMPOSE_FILE` in `.env`.
The base `docker-compose.yml` is unchanged; each plugin is strictly opt-in.

---

## CI workflows

All `uses:` references are pinned to full commit SHAs; tool images in `run:` steps are pinned
by digest. Every workflow starts from `permissions: {}` and grants per job.

**`deploy.yml`** — matrix over runner / controller / deployer:

```
pull_request → job build   (contents: read)
                 checkout (persist-credentials: false) → build + load locally → trivy scan
push to main → job verify (contents: read) → scripts/verify.sh all
             → job publish (needs verify; contents: read, packages: write, id-token: write)
                 checkout → cosign-installer (v2.2.4) → login ghcr.io
                 → build + push ghcr.io/{owner}/{image}:sha
                 → cosign sign --yes {image}@{digest}   (keyless; auth from the login step)
                 → trivy scan
             → job promote (needs all publish matrix jobs to succeed)
                 → cosign-verify all three :sha tags → promote signed digests to :latest
```

- `concurrency`: publishes are serialised (`cancel-in-progress: false`), so an older build can
  never finish last and move `:latest` backwards; PR builds of the same ref cancel each other.
- No `:latest` tag moves if lint, tests, image build, signing or CRITICAL scan fails. Promotion
  across three separate registry tags is sequential, so a registry error during promotion
  can still leave a partially updated set of tags.
- Trivy reports fixable HIGH findings and blocks on fixable CRITICAL findings; reviewed,
  expiring exceptions live in `.trivyignore.yaml`.
- `${{ }}` expressions are passed to `run:` via `env:` only (no template injection — zizmor).

**`ci.yml`** — on PRs, `lint` and `test` call `scripts/verify.sh`, the same local entrypoint.
Pushes to main run the combined checks in `deploy.yml` before publishing.

**`runner-version.yml`** — weekly; fails with an annotation containing the exact
`ARG RUNNER_VERSION` / `ARG RUNNER_SHA256` lines when actions/runner has a newer release.

**Build context**: all three images use `.` (repo root) as the build context; the root
`.dockerignore` applies to all of them.

No SSH secrets are needed. Remove `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`
from repo secrets if previously set.

---

## Tests

```bash
bash scripts/verify.sh         # lint + tests, same checks as CI
bash scripts/verify.sh syntax  # host-only syntax checks
```

The entrypoints only run `main` when executed, so tests `source` them and call functions
directly against stubs in `tests/stubs/` (state kept in files under `$ST`, every call logged
to `$CALLS`). The bootstrap tests run a copy of the standalone script against a temporary
`.env` and Docker stub. Conventions that matter:

- Call `reconcile` / `run_cycle` as `if reconcile; …` — production relies on errexit being
  ignored inside them.
- Use `refute cmd` for negative assertions. `! cmd` never fails a bats test (bash ignores
  errexit for negated commands).
- Variables whose defaults are computed at source time (e.g. `RUNNER_APPARMOR_PROFILE`) must
  be exported **before** sourcing.
- Global associative arrays are declared with `declare -gA` so the scripts also work when
  sourced from a function (bats `setup`).
- `tests/deployer.bats` expands its readable two-character SHA fixture IDs to full 64-character
  digests before cosign returns them; fake Docker image IDs remain compact.
- `BATS_TEST_TIMEOUT=60` turns a hang into a failure.

---

## First-time server setup

```bash
# 1. Create dedicated user
sudo useradd -m -s /bin/bash ghrunner
sudo usermod -aG docker ghrunner

# 2. Run one-time setup scripts (as root)
sudo bash ~/infra-runner/scripts/setup-egress-policy.sh
sudo bash ~/infra-runner/scripts/setup-apparmor.sh
# Verify: aa-status | grep infra-runner

# 3. Clone and configure (as ghrunner)
sudo -iu ghrunner
git clone https://github.com/YOUR_ORG/infra-runner ~/infra-runner
cd ~/infra-runner
cp .env.example .env
$EDITOR .env   # required: GITHUB_ORG, COMPOSE_PROJECT_NAME
               # auth (pick one): GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID + GITHUB_APP_PRIVATE_KEY_PATH
               #              or: GITHUB_TOKEN + GHCR_USERNAME (classic PAT, backward compat)
               # recommended: RUNNER_SECCOMP_HOST_PATH

# 4. Start
# GitHub App path: packages must be public — no GHCR auth needed.
# PAT path with private images: run `bash scripts/ghcr-login.sh` first.
bash scripts/bootstrap-images.sh   # cosign-verify, pull by digest, tag :verified
docker compose up -d

# 5. Verify
docker compose logs -f --no-log-prefix controller | jq .
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
docker compose logs -f --no-log-prefix controller | jq .
docker compose logs -f --no-log-prefix deployer   | jq .

# Check health endpoint
curl -s http://localhost:8080/health | jq .

# List all live per-job containers
docker ps --filter label=runner-managed=true

# Respawn idle runners (e.g. after changing RUNNER_LABELS or limits in .env);
# busy runners finish their job first
docker compose restart controller

# Stop the stack. Busy runners keep running until their job ends (SHUTDOWN_CLEANUP=idle).
docker compose down
# Full teardown including in-progress jobs:
docker rm -f $(docker ps -aq --filter label=runner-managed=true --filter label=runner-role=runner)

# Local build + start (after code changes in this repo)
docker compose build
docker compose up -d
```

---

## Updating the runner binary

Bump both `ARG RUNNER_VERSION` and `ARG RUNNER_SHA256` in `Dockerfile`, then push to `main`.
CI rebuilds all three images; the deployer verifies and applies the update within `POLL_INTERVAL` seconds.

```dockerfile
ARG RUNNER_VERSION=2.335.0   # ← bump here
ARG RUNNER_SHA256=<sha256>   # ← get from the release page (see below)
```

Find the SHA256 for `actions-runner-linux-x64-<version>.tar.gz` in the release body at
https://github.com/actions/runner/releases — each release lists checksums inline.
The build will fail at `sha256sum -c` if the hash does not match, catching supply-chain issues.

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

- **No `--privileged`, no Docker socket in the job path — but runners hold `CAP_SYS_ADMIN`.**
  Buildah with fuse-overlayfs builds images without a daemon. Runner containers get Docker's
  default capabilities plus `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID` (layer
  extraction) and `SYS_PTRACE` + `SYS_ADMIN` (Buildah user-namespace setup: `proc_setgroups_open`
  calls `ptrace_may_access`, and the full-range uid_map write needs `CAP_SYS_ADMIN` in the parent
  namespace). The AppArmor profile **grants** both, grants `userns,` (Ubuntu 24.04's
  `apparmor_restrict_unprivileged_userns=1` blocks `clone(CLONE_NEWUSER)` otherwise) and allows
  `mount,` without restriction. This is the largest residual risk — see README → *Threat model*.
- **The controller's GitHub credential never enters runner containers.** The controller
  holds either a GitHub App installation token (preferred, auto-refreshed every 55 min) or
  a static PAT. Runners receive only a single-use JIT config (default), which is unset from the environment
  before `run.sh` starts. In legacy `token` mode the registration token is reusable for ~1 h,
  so it too is unset before any job step runs.
- **`--ephemeral` ensures single-use.** Even if a job attempts to persist a backdoor in
  the container filesystem, the container is destroyed before any subsequent job runs.
- **Docker socket proxies** (`tecnativa/docker-socket-proxy@sha256:1f3a6...`) sit between each service
  and `/var/run/docker.sock`. Controller and deployer connect via `DOCKER_HOST=tcp://proxy:2375`.
  `EXEC`, `BUILD` and `AUTH` are disabled. The proxy filters by API path, not by request
  body, so container creation with `--privileged` or host mounts remains possible — treat a
  compromised controller/deployer as root on the host. Both run with `cap_drop: ALL` and
  `no-new-privileges`. The proxy containers themselves mount the raw socket (unavoidable);
  they are minimal, digest-pinned, and tracked by Dependabot.
- **Seccomp** (`seccomp/runner-profile.json`) is a **default-ALLOW** profile that denies only
  `kexec_*`, kernel-module syscalls, `bpf`, `perf_event_open`, `iopl`/`ioperm`, keyring syscalls
  and `pivot_root`. It *replaces* Docker's default profile, so syscalls Docker would normally
  block (`unshare`, `setns`, `mount`, `open_by_handle_at`, `userfaultfd`, …) are allowed.
  `mount`/`umount2` are needed by fuse-overlayfs; AppArmor does **not** narrow mount types
  (`mount,` is unrestricted because Buildah's flag combinations cannot be expressed per rule).
- **AppArmor profile** (`apparmor/infra-runner`) is applied to every runner container via
  `--security-opt apparmor=infra-runner`. It denies `sys_module`, `sys_rawio`, `sys_boot`,
  `sys_time`, `net_admin`, `net_raw`, `mac_*`, raw/packet sockets, writes to kernel tunables,
  sysfs and cgroupfs, reads of `/etc/shadow`/`sudoers`, and cron/module paths. It **grants**
  `sys_admin`, `sys_ptrace`, `userns,` and unrestricted `mount,` (Buildah). Path-based denials
  are best-effort while `mount` is allowed (a path can be re-mounted elsewhere). Reload after any profile
  edit with `sudo apparmor_parser -r apparmor/infra-runner`. Load fresh with
  `scripts/setup-apparmor.sh` on first start. Set `RUNNER_APPARMOR_PROFILE=` (empty) in
  `.env` to disable.
- **Runner binary SHA256 is verified at build time.** `ARG RUNNER_SHA256` is checked with
  `sha256sum -c` before extraction. A mismatch fails the Docker build immediately.
- **GitHub Actions in CI are SHA-pinned.** All `uses:` references in `deploy.yml` are pinned
  to full commit SHAs so a retag cannot silently change the code that builds or signs images.
  Dependabot tracks version bumps and sends PRs.
- **Resource limits** prevent crypto mining or denial-of-service against the host. Socket proxy
  containers are additionally limited to `memory: 128m` / `cpus: 0.25`.
- **Network egress is restricted.** Job networks get explicit subnets from `10.89.0.0/16`.
  `scripts/setup-egress-policy.sh` installs chain `INFRA-RUNNER-FWD` (from `DOCKER-USER`):
  only DNS (53) and HTTPS (443) to the internet; RFC 1918, link-local/metadata and CGNAT
  ranges dropped; and `INFRA-RUNNER-IN` (from `INPUT`): runners cannot reach the host's own
  services (sshd, published ports), except DNS. The script requires Docker's iptables
  backend and checks that `DOCKER-USER` is the first unconditional `FORWARD` rule before
  changing rules. The controller explicitly disables IPv6 on job networks.
- **Image signatures.** CI signs all three images (runner, controller, deployer) with cosign
  keyless signing tied to the workflow's GitHub Actions OIDC identity. The deployer
  cosign-verifies the remote tag, pulls **the exact digest cosign verified**, and only then tags
  it `:verified`; compose (`pull_policy: never`) and the controller (`--pull never`) run only
  that tag. A verification failure sets `/health` to `503` and nothing is pulled.
- **Workflow `GITHUB_TOKEN` scope must be minimised in downstream workflows.** Declare a
  `permissions:` block in every workflow, and set the org-level default to read-only at
  **Settings → Actions → General → Workflow permissions**.
- **Structured JSON logging.** Both controller and deployer emit newline-delimited JSON
  (`ts`, `level`, `svc`, `msg`, plus contextual fields). Pipe through `jq` or ingest with
  any log aggregator that reads Docker container logs.
- **Health endpoint.** `GET :<HEALTH_PORT>/health` returns `200 {"status":"ok","ts":"..."}` during
  normal operation and `503` with `status` `starting` (before the first cycle), `unhealthy`
  (`reason`: signature failure, pull/compose error, failed blocking hook, self-update failure) or
  `stale` (no cycle finished within `HEALTH_MAX_AGE`). Failed deploys are retried every cycle,
  so it stays 503 until the deploy succeeds. Poll with UptimeRobot, Grafana, etc.
- **The `.env` file and any mounted PEM key contain secrets — both are gitignored. Never commit them.**
- **Residual risks** are listed in README → *Threat model* (runner `SYS_ADMIN` + permissive
  seccomp, host-root-equivalent controller/deployer, unsigned plugin hooks, unbounded
  `$GITHUB_WORKSPACE` disk, IPv6, runner-group scope).
