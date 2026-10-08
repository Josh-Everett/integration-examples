#!/usr/bin/env bash
# Print pipelinerun-attest.yaml with poc-force-result set to "", FAILURE or SUCCESS.
# The run values are already filled in; this is the only one that varies between runs.
#
# usage: force.sh <"" | FAILURE | SUCCESS> [pipelinerun file]
#   example: scripts/force.sh FAILURE | oc create -f -
#
# Writes nothing; prints to stdout. The substitution is checked afterwards, because a sed that
# silently stops matching would emit the natural-result file and oc would accept it, giving a run
# that looks like the forced one it is recorded as.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
kit="$(cd "${here}/.." && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

[ $# -ge 1 ] || { sed -n '2,6p' "$0" >&2; exit 3; }
want="$1"; file="${2:-${kit}/pipelineruns/pipelinerun-attest.yaml}"
case "$want" in ""|FAILURE|SUCCESS) ;; *) die "forced result must be empty, FAILURE or SUCCESS, got '${want}'";; esac
case "$file" in /*) ;; *) [ -f "$file" ] || file="${kit}/${file}";; esac
[ -f "$file" ] || die "no such file: $2"

# The marker comment is what the substitution anchors to, so there must be exactly one.
n=$(grep -c '# POC-FORCE-RESULT' "$file" || true)
[ "$n" -eq 1 ] || die "expected exactly one '# POC-FORCE-RESULT' marker in ${file}, found ${n}"

out=$(sed '/# POC-FORCE-RESULT/s|value: "[^"]*"|value: "'"${want}"'"|' "$file")
printf '%s\n' "$out" | grep -q "value: \"${want}\".*# POC-FORCE-RESULT" \
  || die "poc-force-result was not set to '${want}'; the marker line may have been reformatted"

printf '%s\n' "$out"
