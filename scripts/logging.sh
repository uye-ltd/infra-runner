#!/bin/bash
# Structured JSON logger shared by controller and deployer.
# Requires LOG_SVC to be set by the sourcing script before sourcing this file.
# Usage: log <level> <message> [key value ...]

log() {
  local level="$1" msg="$2"; shift 2
  msg="${msg//\\/\\\\}"; msg="${msg//\"/\\\"}"; msg="${msg//$'\n'/\\n}"
  local kv=""
  while [[ $# -ge 2 ]]; do
    local k="$1" v="$2"; shift 2
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//$'\n'/\\n}"
    kv="${kv},\"${k}\":\"${v}\""
  done
  printf '{"ts":"%s","level":"%s","svc":"%s","msg":"%s"%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${level}" "${LOG_SVC:-unknown}" "${msg}" "${kv}"
}
