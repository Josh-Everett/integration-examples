#!/usr/bin/env bash
# Run `ec validate image` with the kit policy against one image and summarise what the probe and the
# test_attestation rules said about the component whose image is the one you passed (for an index,
# ec also reports each per-architecture child; those carry no statement and show
# poc_probe.verified_test_statement_missing, which is expected).
#
# usage: run-ec.sh <repository>@<image-digest> <output-prefix> [effective-time, default now] [policy file, default ../policy.yaml]
#   PUBLIC_KEY=path  staging Chains public key (default ./chains-public-key.pub in the current directory)
#   DOCKER_CONFIG=dir  directory holding config.json with pull access to the repository (ec reads it)
# Writes <prefix>.report.json, <prefix>.input.jsonl (policy input), <prefix>.debug.log, <prefix>.text.
# exit: ec's exit status (1 when the policy fails, which is the expected result for the FAILURE run).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
kit="$(cd "${here}/.." && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

[ $# -ge 2 ] || { sed -n '2,13p' "$0"; exit 3; }
image="$1"; prefix="$2"; eff="${3:-now}"; policy="${4:-${kit}/policy.yaml}"
need ec jq
case "$image" in *@sha256:*) ;; *) die "image must be <repository>@sha256:<hex>";; esac
case "$prefix" in /*) ;; *) prefix="$(pwd)/${prefix}";; esac
key="${PUBLIC_KEY:-$(pwd)/chains-public-key.pub}"
case "$key" in /*|k8s://*) ;; *) key="$(pwd)/${key}";; esac
case "$policy" in /*) ;; *) policy="$(pwd)/${policy}";; esac
case "$key" in
  k8s://*) ;;
  *) [ -s "$key" ] || die "public key ${key} is missing or empty (see step zero)" ;;
esac

set +e
# ./probe and ./poc-data in the policy resolve against the working directory, so run from the kit.
( cd "$kit" && ec validate image \
    --image "$image" \
    --policy "$policy" \
    --public-key "$key" \
    --ignore-rekor \
    --effective-time "$eff" \
    --info --show-successes \
    --output "text=${prefix}.text" \
    --output "json=${prefix}.report.json" \
    --output "policy-input=${prefix}.input.jsonl" \
    --debug --logfile "${prefix}.debug.log" )
rc=$?
set -e
echo "ec exit status: ${rc}"
[ -s "${prefix}.report.json" ] || { echo "no report written; see ${prefix}.debug.log and ${prefix}.text" >&2; exit "$rc"; }
"${here}/summarize-report.sh" "${prefix}.report.json" "${image#*@}" || true
echo "--- debug lines about referrers and attestation verification:"
grep -E 'found referrer via OCI Referrers API|attestation verification complete' "${prefix}.debug.log" | tail -20 || true
exit "$rc"
