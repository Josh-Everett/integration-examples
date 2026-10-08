#!/usr/bin/env bash
# Print what a PoC PipelineRun produced: the clamav-scan TaskRun's results (TEST_OUTPUT and the
# TEST_OUTPUT_ARTIFACT_URI / TEST_OUTPUT_ARTIFACT_DIGEST pair), each step's termination reason and times,
# the resolved task source, and the Chains annotations. Last line: the statement digest, for the other scripts.
#
# usage: show-run.sh <namespace> <pipelinerun> [pipeline-task-name, default clamav-scan]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

[ $# -ge 2 ] || { sed -n '2,7p' "$0"; exit 3; }
ns="$1"; pr="$2"; ptask="${3:-clamav-scan}"
need "$OC" jq

# jq rather than jsonpath items[0], so an empty list (run just created, or Pending in Kueue) reaches the die below.
tr=$("$OC" get taskrun -n "$ns" -l "tekton.dev/pipelineRun=${pr},tekton.dev/pipelineTask=${ptask}" -o json \
  | jq -r '.items[0].metadata.name // empty')
[ -n "$tr" ] || die "no TaskRun for pipeline task ${ptask} in ${pr} yet; wait for the run (wait-signed.sh) and try again"
echo "TaskRun: ${tr}"
"$OC" get taskrun "$tr" -n "$ns" -o json | jq '{
  succeeded: ((.status.conditions // [])[] | select(.type=="Succeeded") | {status, reason, message}),
  startTime: .status.startTime, completionTime: .status.completionTime,
  source: .status.provenance.refSource,
  results: [(.status.results // [])[] | {name, value}],
  steps: [(.status.steps // [])[] | {name, terminationReason, exitCode: .terminated.exitCode,
          startedAt: .terminated.startedAt, finishedAt: .terminated.finishedAt}]
}'
"$OC" get pipelinerun "$pr" -n "$ns" -o json | jq '{pipelinerun_annotations: (.metadata.annotations
  | with_entries(select(.key|startswith("chains.tekton.dev")))), labels: .metadata.labels}'
digest=$("$OC" get taskrun "$tr" -n "$ns" -o json \
  | jq -r '(.status.results // [])[] | select(.name=="TEST_OUTPUT_ARTIFACT_DIGEST") | .value')
echo "STATEMENT_DIGEST=${digest:-<none>}"
