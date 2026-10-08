#!/usr/bin/env bash
# Wait for Tekton Chains to finish with a PipelineRun: polls chains.tekton.dev/signed until it is
# "true" or "failed", or until the timeout. Prints each poll and the seconds from the PipelineRun's
# completionTime to the moment the annotation was seen (signing latency, for the go/no-go record).
#
# usage: wait-signed.sh <namespace> <pipelinerun> [timeout-seconds, default 900] [poll-seconds, default 10]
#   The timeout counts from when the PipelineRun has a completionTime; while it is still running the
#   script keeps waiting (Ctrl-C to stop).
# exit:  0 signed=true, 1 signed=failed, 2 timeout, 3 usage or tool error
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

[ $# -ge 2 ] || { sed -n '2,11p' "$0"; exit 3; }
ns="$1"; pr="$2"; timeout="${3:-900}"; poll="${4:-10}"
need "$OC" jq

start=$(date +%s)
done_at=""
echo "Waiting for ${ns}/${pr} to complete, then for chains.tekton.dev/signed (timeout ${timeout}s)"
while :; do
  json=$("$OC" get pipelinerun "$pr" -n "$ns" -o json) || { echo "could not read the PipelineRun" >&2; exit 3; }
  succeeded=$(jq -r '(.status.conditions // [])[] | select(.type=="Succeeded") | .status' <<<"$json")
  reason=$(jq -r '(.status.conditions // [])[] | select(.type=="Succeeded") | .reason' <<<"$json")
  completion=$(jq -r '.status.completionTime // empty' <<<"$json")
  signed=$(jq -r '.metadata.annotations["chains.tekton.dev/signed"] // empty' <<<"$json")
  retries=$(jq -r '.metadata.annotations["chains.tekton.dev/retries"] // empty' <<<"$json")
  elapsed=$(( $(date +%s) - start ))
  echo "$(now_utc) +${elapsed}s run=${succeeded:-?}/${reason:-?} completionTime=${completion:-<none>} signed=${signed:-<unset>} retries=${retries:-0}"

  if [ "$signed" = "true" ] || [ "$signed" = "failed" ]; then
    seen=$(now_utc)
    if [ -n "$completion" ] && c=$(to_epoch "$completion") && s=$(to_epoch "$seen"); then
      echo "signing latency: $(( s - c ))s from completionTime ${completion} to annotation seen at ${seen} (resolution ${poll}s)"
    fi
    if [ "$signed" = "true" ]; then
      echo "signed=true. This alone is not proof: also run check-att.sh with the statement digest."
      exit 0
    fi
    echo "signed=failed. Chains gave up after its retries. The actual error is usually readable:" >&2
    echo "  oc get events -n ${ns} --field-selector involvedObject.name=${pr},type=Warning -o json | jq -r '.items[].message'" >&2
    echo "  oc logs deploy/tekton-chains-controller -n openshift-pipelines --since=10m | grep ${pr}" >&2
    echo "(both worked as a tenant on stone-stg-rh01, 2026-10-08, despite the kit's note to the contrary)." >&2
    echo "UNAUTHORIZED on .../blobs/uploads/ means the keychain picked a pull-only credential: check that" >&2
    echo "the account's imagePullSecrets holds no other credential for this registry (see harness.sh)." >&2
    exit 1
  fi

  if [ -n "$completion" ] && [ -z "$done_at" ]; then done_at=$(date +%s); fi
  if [ -n "$done_at" ] && [ $(( $(date +%s) - done_at )) -ge "$timeout" ]; then
    echo "timed out ${timeout}s after the run completed, with signed=${signed:-<unset>}" >&2
    exit 2
  fi
  sleep "$poll"
done
