# Digest-pinned; Dependabot bumps tag + digest together.
FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

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
