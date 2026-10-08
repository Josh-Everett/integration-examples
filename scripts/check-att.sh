#!/usr/bin/env bash
# Second half of the Chains-signed check: Chains writes the provenance for the statement as the tag
# sha256-<statement digest hex>.att in the image's repository (subject is <repository>@<statement digest>).
# The tag is created by the default DSSE storage path, cosign ociremote.WriteAttestations
# (tektoncd/chains@7f543807 pkg/chains/storage/oci/attestation.go:100-146). If chains-config sets
# storage.oci.encoding-format: sigstore-bundle, Chains writes an OCI referrer instead and creates no .att
# tag (attestation.go:70-88); look for a sigstore-bundle referrer on the statement then. The image's own
# sha256-<image digest>.att comes from the build and proves nothing here.
#
# usage: check-att.sh <repository> <statement-digest>
#   REGISTRY_CONFIG=/path/auth.json to use a docker config other than ~/.docker/config.json
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

[ $# -eq 2 ] || { sed -n '2,11p' "$0"; exit 3; }
repo="$1"; sd="$2"
need oras jq
case "$sd" in sha256:*) ;; *) die "statement digest must look like sha256:<hex>";; esac
auth=()
while IFS= read -r a; do auth+=("$a"); done < <(oras_auth_args)

tag="sha256-${sd#sha256:}.att"
if m=$(oras manifest fetch ${auth[@]+"${auth[@]}"} "${repo}:${tag}" 2>/dev/null); then
  echo "PASS: ${repo}:${tag} exists"
  jq -c '{mediaType, layers: [.layers[] | {mediaType, predicateType: .annotations.predicateType, size}]}' <<<"$m"
else
  echo "FAIL: no tag ${tag} in ${repo}" >&2
  echo "Tags ending in .att:" >&2
  oras repo tags ${auth[@]+"${auth[@]}"} "$repo" | grep '\.att$' >&2 || true
  exit 1
fi
