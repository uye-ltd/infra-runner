FROM ubuntu:24.04

ARG RUNNER_VERSION=2.334.0
ARG RUNNER_SHA256=048024cd2c848eb6f14d5646d56c13a4def2ae7ee3ad12122bee960c56f3d271

# System dependencies + Docker CLI (for `docker login` — no daemon needed for credential storage)
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      git \
      jq \
      ca-certificates \
      gnupg \
      lsb-release \
      gettext-base \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
         | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
         https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
         > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# Kaniko executor — kept for backward compat with workflows that call `kaniko` directly.
# Sourced from the Chainguard community fork (original archived by Google 2025-06-03).
# Version pinned so Dependabot can track updates and builds are reproducible.
COPY --from=ghcr.io/kaniko-build/dist/chainguard-forks-kaniko/executor:v1.25.14 /kaniko/executor /usr/local/bin/kaniko

# Buildah + fuse-overlayfs — primary daemonless image builder.
# fuse-overlayfs provides copy-on-write layer storage over FUSE (no kernel overlay mount,
# no --privileged). graphRoot=/kaniko reuses the controller-mounted tmpfs (RUNNER_KANIKO_SIZE).
RUN apt-get update && apt-get install -y --no-install-recommends \
      buildah \
      fuse-overlayfs \
      uidmap \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/containers \
    && printf '[storage]\n  driver = "overlay"\n  graphRoot = "/kaniko"\n\n[storage.options]\n\n  [storage.options.overlay]\n    mount_program = "/usr/bin/fuse-overlayfs"\n' \
       > /etc/containers/storage.conf \
    && echo "root:0:4294967295" > /etc/subuid \
    && echo "root:0:4294967295" > /etc/subgid

# Vault CLI — baked into the image because releases.hashicorp.com is geo-blocked
# from the server hosting this runner. Install during image build (on GitHub hosted
# runners) so validate.yml can use vault directly without network download at job time.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://apt.releases.hashicorp.com/gpg \
         | gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/hashicorp.gpg] \
         https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
         > /etc/apt/sources.list.d/hashicorp.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends vault \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/actions-runner

# Download, verify SHA256, and extract GitHub Actions runner binary
RUN curl -fsSL \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
      -o runner.tar.gz \
    && echo "${RUNNER_SHA256}  runner.tar.gz" | sha256sum -c - \
    && tar -xzf runner.tar.gz \
    && rm runner.tar.gz

# Install runner .NET dependencies
RUN ./bin/installdependencies.sh

COPY entrypoint.sh /opt/actions-runner/entrypoint.sh
RUN chmod +x /opt/actions-runner/entrypoint.sh

# Runs as root — required by Kaniko and Buildah for layer extraction and RUN instruction execution.
# Container-level isolation (seccomp, resource limits, no Docker socket, ephemeral)
# is the security boundary, not the in-container user.
ENTRYPOINT ["/opt/actions-runner/entrypoint.sh"]
