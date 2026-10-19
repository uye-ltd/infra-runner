# Test environment for tests/run.sh — same base as the controller/deployer images, plus
# bats. The scripts under test need bash, jq, coreutils (timeout), Python and OpenSSL.
FROM ubuntu:25.10@sha256:7cc5e35f6567ee8c66d2abb4aab0fd866669e6207c237c3a8f0947a5c7f17092
RUN apt-get update \
    && apt-get install -y --no-install-recommends bats jq python3 curl openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /repo
