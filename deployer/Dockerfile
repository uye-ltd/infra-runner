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
ARG COSIGN_VERSION=2.4.3
RUN set -e \
    && curl -fsSL \
         "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64" \
         -o /usr/local/bin/cosign \
    && expected=$(curl -fsSL \
         "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64.sha256" \
         | awk '{print $1}') \
    && echo "${expected}  /usr/local/bin/cosign" | sha256sum -c \
    && chmod +x /usr/local/bin/cosign

COPY entrypoint.sh /entrypoint.sh
COPY health_server.py /health_server.py
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
