FROM ubuntu:22.04

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
# Copied from the official image (same pattern as Kaniko in the runner Dockerfile)
# so Dependabot can track the version via this FROM reference.
COPY --from=gcr.io/projectsigstore/cosign:v2.4.1 /ko-app/cosign /usr/local/bin/cosign

COPY entrypoint.sh /entrypoint.sh
COPY health_server.py /health_server.py
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
