#!/usr/bin/env bash
# The statement-is-a-referrer check. Lists the in-toto referrers of <repository>@<image-digest> with
# their annotations, fetches each statement and prints its test name, timestamp, result and subject.
# With a third argument, exits non-zero unless that statement digest is among the referrers.
#
# usage: check-referrer.sh <repository> <image-digest> [expected-statement-digest]
#   repository: bare, e.g. quay.io/redhat-user-workloads-stage/<ns>/<component>
#   REGISTRY_CONFIG=/path/auth.json to use a docker config other than ~/.docker/config.json
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

[ $# -ge 2 ] || { sed -n '2,9p' "$0"; exit 3; }
repo="$1"; img="$2"; want="${3:-}"
need oras jq
auth=()
while IFS= read -r a; do auth+=("$a"); done < <(oras_auth_args)

json=$(oras discover ${auth[@]+"${auth[@]}"} --artifact-type application/vnd.in-toto+json --format json "${repo}@${img}")
# oras prints the list under a top-level "manifests" key (verified with oras 1.2.2 against quay.io,
# 2026-10-07); some builds and conforma/step-actions@1969ae1 attest-test-result.yaml:143-147 say
# "referrers". Accept either, or the count is silently always zero.
n=$(jq '(.referrers // .manifests // []) | length' <<<"$json")
echo "in-toto referrers of ${repo}@${img}: ${n}"
jq -r '(.referrers // .manifests // [])[] | "\(.digest)  created=\(.annotations["org.opencontainers.image.created"] // "-")  testName=\(.annotations.testName // "-")  predicateType=\(.annotations.predicateType // "-")"' <<<"$json"

for d in $(jq -r '(.referrers // .manifests // [])[].digest' <<<"$json"); do
  layer=$(oras manifest fetch ${auth[@]+"${auth[@]}"} "${repo}@${d}" | jq -r '.layers[0].digest')
  oras blob fetch ${auth[@]+"${auth[@]}"} --output - "${repo}@${layer}" \
    | jq -c --arg d "$d" '{statement: $d, name: .predicate.configuration[0].name, timestamp: .predicate.timestamp,
        result: .predicate.result, failures: .predicate.failures, subject: .subject[0].name,
        subject_digest: .subject[0].digest.sha256, predicateType}'
done

if [ -n "$want" ]; then
  if jq -e --arg w "$want" '(.referrers // .manifests // []) | any(.digest == $w)' <<<"$json" >/dev/null; then
    echo "PASS: ${want} is a referrer of ${repo}@${img}"
  else
    echo "FAIL: ${want} is not among the in-toto referrers" >&2
    exit 1
  fi
fi
