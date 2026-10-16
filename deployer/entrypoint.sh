#!/bin/sh
# Compatibility entrypoint for local operators; the image invokes poller.py directly.
set -eu
exec python3 /poller.py
