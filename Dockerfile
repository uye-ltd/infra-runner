FROM ubuntu:24.04

ARG RUNNER_VERSION=2.323.0

# System dependencies + Docker CLI (for `docker login` — no daemon needed for credential storage)
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      git \
      jq \
      ca-certificates \
      gnupg \
      lsb-release \
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

# Kaniko executor — builds Docker images from a Dockerfile without a daemon
# and without a privileged container. Kaniko requires root inside the container
# but the container itself is unprivileged.
COPY --from=gcr.io/kaniko-project/executor:latest /kaniko/executor /usr/local/bin/kaniko

WORKDIR /opt/actions-runner

# Download and extract GitHub Actions runner binary
RUN curl -fsSL \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
      | tar -xz

# Install runner .NET dependencies
RUN ./bin/installdependencies.sh

COPY entrypoint.sh /opt/actions-runner/entrypoint.sh
RUN chmod +x /opt/actions-runner/entrypoint.sh

# Runs as root — required by Kaniko for layer extraction and RUN instruction execution.
# Container-level isolation (seccomp, resource limits, no Docker socket, ephemeral)
# is the security boundary, not the in-container user.
ENTRYPOINT ["/opt/actions-runner/entrypoint.sh"]
