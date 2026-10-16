FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl python3 \
    && rm -rf /var/lib/apt/lists/*

# Public keyless verification needs no GitHub or registry credential.
COPY --from=ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8 /ko-app/cosign /usr/local/bin/cosign
COPY deployer/health_server.py /health_server.py
COPY deployer/poller.py /poller.py

USER 65532:65532
ENTRYPOINT ["python3", "/poller.py"]
