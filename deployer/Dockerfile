FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      jq \
      python3 \
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
    && apt-get install -y --no-install-recommends \
         docker-ce-cli \
         docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# cosign — verifies image signatures before the deployer applies any update.
# Keyless verification: no private key stored here; trust is anchored to the
# GitHub Actions OIDC identity that signed the image in CI.
# Pinned by both version tag and digest so a force-pushed tag cannot substitute a different binary.
COPY --from=gcr.io/projectsigstore/cosign:v2.4.1@sha256:b03690aa52bfe94054187142fba24dc54137650682810633901767d8a3e15b31 /ko-app/cosign /usr/local/bin/cosign

COPY scripts/logging.sh /scripts/logging.sh
COPY deployer/entrypoint.sh /entrypoint.sh
COPY deployer/health_server.py /health_server.py
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
