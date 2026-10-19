# Digest-pinned; Dependabot bumps tag + digest together.
FROM ubuntu:25.10@sha256:7cc5e35f6567ee8c66d2abb4aab0fd866669e6207c237c3a8f0947a5c7f17092

# pipefail: a failed curl in `curl … | gpg/sha256sum` must fail the build.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

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
COPY --from=ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8 /ko-app/cosign /usr/local/bin/cosign

COPY scripts/logging.sh /scripts/logging.sh
COPY scripts/ghcr-auth.sh /scripts/ghcr-auth.sh
COPY deployer/entrypoint.sh /entrypoint.sh
COPY deployer/health_server.py /health_server.py
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
