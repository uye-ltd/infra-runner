# Digest-pinned; Dependabot bumps tag + digest together.
FROM ubuntu:25.10@sha256:7cc5e35f6567ee8c66d2abb4aab0fd866669e6207c237c3a8f0947a5c7f17092

# pipefail: a failed curl in `curl … | gpg/sha256sum` must fail the build.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG RUNNER_VERSION=2.338.0
ARG RUNNER_SHA256=af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32

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
# Tag + digest pinned so a re-pushed tag cannot substitute a different binary.
COPY --from=ghcr.io/kaniko-build/dist/chainguard-forks-kaniko/executor:v1.25.14@sha256:f77cd662e4bd55c052c5db1e030b532d324be92143ee274e58dadec30472b2ee /kaniko/executor /usr/local/bin/kaniko

# Buildah + fuse-overlayfs — primary daemonless image builder.
# fuse-overlayfs provides copy-on-write layer storage over FUSE (no kernel overlay mount,
# no --privileged). graphRoot=/kaniko reuses the controller-mounted tmpfs (RUNNER_KANIKO_SIZE).
RUN apt-get update && apt-get install -y --no-install-recommends \
      buildah \
      fuse-overlayfs \
      uidmap \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/containers \
    && printf '[storage]\n  driver = "overlay"\n  graphroot = "/kaniko"\n  runroot = "/tmp/buildah-run"\n\n[storage.options]\n\n  [storage.options.overlay]\n    mount_program = "/usr/bin/fuse-overlayfs"\n' \
       > /etc/containers/storage.conf \
    && echo "root:0:4294967295" > /etc/subuid \
    && echo "root:0:4294967295" > /etc/subgid

# Vault and Cosign CLIs are present for existing workflows. Copy from official,
# version- and digest-pinned images; no runtime download is needed on the server.
COPY --from=hashicorp/vault:2.1.2@sha256:c2f666266f383d2cf424d86b8bb8ce7d065562173ffec2b476d762943608bb55 /bin/vault /usr/local/bin/vault
COPY --from=ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8 /ko-app/cosign /usr/local/bin/cosign

WORKDIR /opt/actions-runner

# Download, verify SHA256, and extract GitHub Actions runner binary.
# Node20 executes JavaScript actions, but its bundled npm is unused here and
# still carries vulnerable node-tar 6.2.1. Remove npm without removing Node20.
RUN curl -fsSL \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
      -o runner.tar.gz \
    && echo "${RUNNER_SHA256}  runner.tar.gz" | sha256sum -c - \
    && tar -xzf runner.tar.gz \
    && rm -rf externals/node20/lib/node_modules/npm \
    && rm runner.tar.gz

# Install runner .NET dependencies
RUN ./bin/installdependencies.sh

COPY entrypoint.sh /opt/actions-runner/entrypoint.sh
RUN chmod +x /opt/actions-runner/entrypoint.sh

# Runs as root — required by Kaniko and Buildah for layer extraction and RUN instruction execution.
# Container-level isolation (seccomp, resource limits, no Docker socket, ephemeral)
# is the security boundary, not the in-container user.
ENTRYPOINT ["/opt/actions-runner/entrypoint.sh"]
