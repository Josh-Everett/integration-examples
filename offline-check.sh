#!/usr/bin/env bash

# offline check of the conforma policy: no cluster, no login, no image
# runs `ec validate input` on a made-up input with no attestations, using a temporary copy of ./policy.yaml
# whose k8s:// publicKey line is swapped for a test key. ec validate input loads the key and has no flag
# to override it, and the k8s:// key needs a cluster login. the test key is not the staging key; it only
# lets the policy file load. nothing is written to the repo.
# needs network access to quay.io and github.com to fetch the policy and data sources.
# expects success, no violations, and the probe warning that no test-result statement survived.

# usage: offline-check.sh [report.json]   (EC=/path/to/ec to use a specific binary)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# helper functions
EC="${EC:-ec}"
die() { echo "ERROR: $*" >&2; exit 1; }

# stop early if a tool the check uses is not installed
need() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' is not on PATH"
  done
}

[ $# -le 1 ] || { sed -n '3,11p' "$0"; exit 3; }
report_out="${1:-}"
case "$report_out" in ""|/*) ;; *) report_out="$PWD/$report_out" ;; esac
need "$EC" jq awk

# ec resolves ./probe from the current directory, not from the policy file's folder
cd "$here"
[ -f policy.yaml ] || die "no policy.yaml next to this script"
[ -d probe ] || die "no probe/ folder next to this script"

ver=$("$EC" version 2>/dev/null | awk '$1 == "Version" { print $2 }')
[ "$ver" = "v0.10.22" ] || echo "WARNING: ec is ${ver:-of unknown version}; the expected output was recorded with v0.10.22" >&2

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# same policy, with the one key line swapped
key_line='publicKey: k8s://openshift-pipelines/public-key'
[ "$(grep -cxF "$key_line" policy.yaml)" -eq 1 ] || die "expected exactly one line '${key_line}' in policy.yaml"
awk -v key_line="$key_line" '
  $0 == key_line {
    print "publicKey: |"
    print "  -----BEGIN PUBLIC KEY-----"
    print "  MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEYUjisOAGHdgdselnh/mBiOssj839"
    print "  D35OK1FgWmVTqYU5VHw+kgx+zHOWQyc+o0kI7+58g/X+iAow5fWSf9ns6A=="
    print "  -----END PUBLIC KEY-----"
    next
  }
  { print }
' policy.yaml > "$tmp/policy-offline.yaml"

# an image reference with no attestations at all, so no test-result statement can be found
printf '%s\n' '{"image":{"ref":"quay.io/konflux-ci/release-service@sha256:4683b73f28a051b168370b297483e497ecc7b1e7d495e733555a2daf516e3066"},"attestations":[]}' \
  > "$tmp/empty-input.json"

rc=0
"$EC" validate input "$tmp/empty-input.json" --policy "$tmp/policy-offline.yaml" \
  --output "json=$tmp/report.json" --show-successes > "$tmp/ec.log" 2>&1 || rc=$?
[ -s "$tmp/report.json" ] || { cat "$tmp/ec.log" >&2; die "ec wrote no report (exit status ${rc})"; }
[ -z "$report_out" ] || cp "$tmp/report.json" "$report_out"

jq -r '
  "ec \(."ec-version")",
  "success: \(.success)",
  "violations: \([.filepaths[].violations[]?] | length)",
  (.filepaths[].violations[]? | "  \(.metadata.code): \(.msg)"),
  "successes: \([.filepaths[].successes[]?] | length) (test_attestation rules: \([.filepaths[].successes[]?.metadata.code | select(startswith("test_attestation."))] | length))",
  "warnings: \([.filepaths[].warnings[]?] | length)",
  (.filepaths[].warnings[]? | "  \(.metadata.code): \(.msg)")
' "$tmp/report.json"
[ -z "$report_out" ] || echo "report saved to ${report_out}"

if jq -e '.success == true
    and ([.filepaths[].violations[]?] | length) == 0
    and any(.filepaths[].warnings[]?; .metadata.code == "poc_probe.verified_test_statement_missing")' \
    "$tmp/report.json" >/dev/null; then
  echo "as expected: the policy loads, nothing fails, and the probe reports that no test-result statement survived"
else
  echo "NOT as expected: see the lines above" >&2
  exit 1
fi
