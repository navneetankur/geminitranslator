#!/usr/bin/env bash
# check_batches.sh — report the state of one or more Gemini batches.
#
# Usage:
#   ./check_batches.sh <batch-id-or-file> [<batch-id-or-file> ...]
#
# Each argument is either a batch name ("batches/xxxx") or a path to a
# file containing one (e.g. a batch.txt written by translation_job.lua).
#
# Exits 0 if ANY batch has finished (SUCCEEDED/DONE), else 1 — so you can do:
#   ./check_batches.sh a/batch.txt b/batch.txt && echo "something's ready"

set -euo pipefail

KEY=$(lua -e 'io.write(dofile(os.getenv("HOME").."/.config/geminitran/toktok.txt"))')
API="https://generativelanguage.googleapis.com/v1beta"

[ "$#" -ge 1 ] || { echo "usage: $0 <batch-id-or-file> [...]" >&2; exit 2; }

any_done=1
printf '%-28s %-24s %s\n' "BATCH" "STATE" "DONE/TOTAL"
for arg in "$@"; do
  # accept either a file holding the id, or the id itself
  if [ -f "$arg" ]; then name=$(tr -d '[:space:]' < "$arg"); else name=$arg; fi

  resp=$(curl -sS "$API/$name" -H "x-goog-api-key: $KEY")

  read -r state succ total < <(printf '%s' "$resp" | jq -r '
    [ (.metadata.state // .state // "UNKNOWN"),
      (.metadata.batchStats.successfulRequestCount // 0),
      (.metadata.batchStats.requestCount // 0) ] | @tsv')

  printf '%-28s %-24s %s/%s\n' "$arg" "$state" "$succ" "$total"
  case "$state" in *SUCCEEDED|DONE) any_done=0 ;; esac
done

exit $any_done
