#!/usr/bin/env bash
# Shared helpers for the STONEINTG-1803 kit scripts. Sourced, not run. Works with bash 3.2 (macOS) and later.

OC="${OC:-oc}"

die() { echo "ERROR: $*" >&2; exit 1; }

need() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' is not on PATH (see the plan's tool list)"
  done
}

# RFC 3339 UTC timestamp (2026-09-29T12:34:56Z) -> epoch seconds, on GNU date (Linux) or BSD date (macOS).
to_epoch() {
  local ts="$1"
  if date --version >/dev/null 2>&1; then
    date -u -d "$ts" +%s          # GNU date
  else
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s   # BSD date (macOS)
  fi
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Optional: REGISTRY_CONFIG=/path/to/auth.json makes oras use that docker config instead of ~/.docker/config.json.
oras_auth_args() {
  if [ -n "${REGISTRY_CONFIG:-}" ]; then
    printf '%s\n' --registry-config "${REGISTRY_CONFIG}"
  fi
}
