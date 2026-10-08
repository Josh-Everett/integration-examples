#!/usr/bin/env bash

# environment checks on staging 
# Read-only except 
# writes the staging Chains public key to ./chains-public-key.pub in the current directory.
# each check runs even if an earlier one fails; read the whole output.

# usage: harness.sh <namespace> <component>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# helper functions
# cluster CLI: oc unless OC=kubectl is set
OC="${OC:-oc}"
die() { echo "ERROR: $*" >&2; exit 1; }


# stop early if a tool the checks use is not installed
need() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' is not on PATH"
  done
}

[ $# -eq 2 ] || { sed -n '3,8p' "$0"; exit 3; }
ns="$1"; comp="$2"; sa="build-pipeline-${comp}"
need "$OC" jq base64

section() { printf '\n=== %s\n' "$*"; }
# show every answer
# refused reads are printed as `forbidden` so not mistaken for an empty or negative
try() {
  local out rc
  out=$("$@" 2>&1) && rc=0 || rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    if grep -qi 'forbidden' <<<"$out"; then echo "(forbidden: refused for this login)"; else echo "(exit status ${rc})"; fi
  fi
}

# Collect rolebindings and print the relevant one
#looking to answer: can the account running PoC use the permissions needed for clamav
bindings_for() {
  "$OC" get rolebindings -n "$ns" -o json \
    | jq --arg sa "$1" '[.items[] | select(any(.subjects[]?; .kind=="ServiceAccount" and .name==$sa))
        | {name: .metadata.name, role: .roleRef.name}]'
}
validation_probe() {
  sed "s|REPLACE-NAMESPACE|${ns}|" "${here}/tekton-validation-probe.yaml" \
    | "$OC" create --dry-run=server -f - -o name
}

check_sa() {
  "$OC" get sa "$1" -n "$ns" -o json \
    | jq '{secrets: [.secrets[]?.name], imagePullSecrets: [.imagePullSecrets[]?.name]}'
}
check_key() {
  local tmp
  tmp=$(mktemp)
  "$OC" get secret public-key -n openshift-pipelines -o jsonpath='{.data.cosign\.pub}' | base64 -d > "$tmp"
  if head -1 "$tmp" | grep 'BEGIN PUBLIC KEY'; then
    mv "$tmp" chains-public-key.pub
  else
    rm -f "$tmp"
    return 1
  fi
}
check_chains_config() {
  "$OC" get configmap chains-config -n openshift-pipelines -o json \
    | jq '.data | with_entries(select(.key | test("format|storage|deep|transparency")))'
}

section "who am I, which cluster (nothing is asserted; this prints what the kubeconfig points at. The PoC values in poc.env were read from api.stone-stg-rh01.l2vh.p1.openshiftapps.com:6443)"
try "$OC" whoami
try "$OC" whoami --show-server

section "component and image repositories (both API groups: konflux-ci.dev gives <name>-img-push, appstudio.redhat.com gives <name>-image-push)"
try "$OC" get components.appstudio.redhat.com "$comp" -n "$ns" -o name
for g in imagerepositories.konflux-ci.dev imagerepositories.appstudio.redhat.com; do
  echo "--- ${g}"
  try "$OC" get "$g" -n "$ns" \
    -o custom-columns='NAME:.metadata.name,URL:.status.image.url,PUSH:.status.credentials.push-secret,PULL:.status.credentials.pull-secret'
done

section "build account ${sa}: .secrets should list the PUSH secret above"
try check_sa "$sa"

section "account the PoC actually runs as, konflux-integration-runner. BOTH lists matter and they are read by different consumers. .secrets must hold the component PUSH secret: that is what select-oci-auth gives the task's oras attach. imagePullSecrets must NOT hold any other registry credential for the same registry: Tekton Chains builds its keychain from both lists, a pull-only quay.io entry there wins over the push secret, and Chains then fails with 'writing attestations: POST .../blobs/uploads/: UNAUTHORIZED' while the task step still succeeds. Proven on stone-stg-rh01 2026-10-08; compare against the build account above, which signs correctly and carries only its own dockercfg in imagePullSecrets."
try check_sa konflux-integration-runner

section "role bindings for ${sa}: expect one with role appstudio-pipelines-runner (the role that carries use on appstudio-pipelines-scc)"
try bindings_for "$sa"

section "role bindings for konflux-integration-runner: on operator-managed clusters its role has no SCC rule"
try bindings_for konflux-integration-runner

section "rules of the konflux-integration-runner and appstudio-pipelines-runner ClusterRoles: does either list securitycontextconstraints/appstudio-pipelines-scc with verb use? (forbidden for tenants is likely; then ask a cluster admin, this decides what STONEINTG-1799 must bind)"
try "$OC" get clusterrole konflux-integration-runner appstudio-pipelines-runner -o yaml

section "RBAC: binding a new account to appstudio-pipelines-runner; expect a refusal (forbidden, or 'attempting to grant RBAC permissions not currently held')"
try "$OC" create rolebinding stoneintg-1803-dryrun -n "$ns" --clusterrole=appstudio-pipelines-runner \
  --serviceaccount="${ns}:stoneintg-1803-probe-nonexistent" --dry-run=server -o name

section "can I create PipelineRuns here? (expect yes)"
try "$OC" auth can-i create pipelineruns.tekton.dev -n "$ns"

section "Tekton validation probe, server dry run, nothing persisted (accepted: fix for tektoncd/pipeline #8255 present; 'non-existent variable': older Tekton)"
try validation_probe

section "staging Chains public key -> ./chains-public-key.pub (expect -----BEGIN PUBLIC KEY-----)"
try check_key

section "Tekton and Chains versions (record both; forbidden for tenants is likely, then use the pod annotation in step 2)"
try "$OC" get tektonconfig config -o jsonpath='{.status.version}{"\n"}'
try "$OC" get deploy tekton-chains-controller -n openshift-pipelines -o jsonpath='{..image}{"\n"}'

section "Chains config (expect slsa/v2alpha3, oci, transparency false, no storage.oci.encoding-format)"
try check_chains_config

section "Kueue: pipelines-queue through the visibility API (tenants cannot list LocalQueues; NotFound means no such queue) [verify API version]"
try "$OC" get --raw "/apis/visibility.kueue.x-k8s.io/v1beta1/namespaces/${ns}/localqueues/pipelines-queue/pendingworkloads"

# jq, not jsonpath: `{range .items[-3:]}` is an out-of-bounds error when the namespace holds
# fewer than three snapshots, and the error body then dumps every snapshot in full (seen 2026-10-07).
latest_snapshots() {
  "$OC" get snapshots.appstudio.redhat.com -n "$ns" --sort-by=.metadata.creationTimestamp -o json \
    | jq -r '[.items[]][-3:][] | "\(.metadata.name)  " +
             ([.spec.components[]? | "\(.name)=\(.containerImage)"] | join("  "))'
}

section "latest snapshots (pick the image digest from a component built on this cluster)"
try latest_snapshots
