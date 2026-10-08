#!/usr/bin/env bash
# Summarise an ec JSON report for the component whose containerImage ends with <image-digest>:
# overall success, test_attestation violations, and the probe's warnings.
#
# usage: summarize-report.sh <report.json> <image-digest>
set -euo pipefail
[ $# -eq 2 ] || { sed -n '2,6p' "$0"; exit 3; }
report="$1"; d="$2"
command -v jq >/dev/null 2>&1 || { echo "jq is not on PATH" >&2; exit 3; }
jq -r --arg d "$d" '
  .components[] | select(.containerImage | endswith($d)) |
  "component: \(.containerImage)\nsuccess: \(.success)",
  "violations:",
  ((.violations // [])[] | "  \(.metadata.code)  term=\(.metadata.term // "-")  \(.msg)"),
  "warnings:",
  ((.warnings // [])[] | "  \(.metadata.code)  \(.msg)")
' "$report"
