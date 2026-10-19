# Digest-pinned; Dependabot bumps tag + digest together.
FROM ubuntu:25.10@sha256:7cc5e35f6567ee8c66d2abb4aab0fd866669e6207c237c3a8f0947a5c7f17092

# pipefail: a failed curl in `curl … | gpg/sha256sum` must fail the build.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# System dependencies:
#   curl + jq  — GitHub API calls and JSON parsing in entrypoint.sh
#   docker-ce-cli — Docker CLI for spawning/managing per-job containers via the socket proxy
#   uuid-runtime — uuidgen for generating unique job IDs
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      jq \
      ca-certificates \
      gnupg \
      lsb-release \
      openssl \
      uuid-runtime \
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

COPY scripts/logging.sh /scripts/logging.sh
COPY scripts/github-app-token.sh /scripts/github-app-token.sh
COPY controller/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
