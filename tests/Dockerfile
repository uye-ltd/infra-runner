# Test environment for tests/run.sh — same base as the controller/deployer images, plus
# bats. The scripts under test need bash, jq, coreutils (timeout), Python and OpenSSL.
FROM ubuntu:26.04@sha256:f144425ff09be612d6d9ad965196e9cdc23dae1f42110a8a11a3e9a8198759f7
RUN apt-get update \
    && apt-get install -y --no-install-recommends bats jq python3 curl openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /repo
