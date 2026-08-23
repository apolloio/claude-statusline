#!/usr/bin/env bash
# Local, deterministic advisory benchmark for the statusline render path.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script="$root/statusline-command.sh"
state=$(mktemp -d "${TMPDIR:-/tmp}/claude-statusline-bench.XXXXXX")
trap 'rm -rf "$state"' EXIT
export CLAUDE_STATUSLINE_STATE_DIR="$state"
export CLAUDE_STATUSLINE_INSTANCE_ID=benchmark
export COLUMNS=200
fixture="$root/examples/input.json"

render() { bash "$script" < "$1" >/dev/null; }
measure() {
  local name=$1 input=$2 count=${3:-20} started ended
  started=$(date +%s)
  local i
  for ((i=0; i<count; i++)); do render "$input"; done
  ended=$(date +%s)
  printf '%-24s %4d renders in %ss\n' "$name" "$count" "$((ended-started))"
}

measure 'minimal warm render' "$fixture"
measure 'enterprise render' "$root/examples/api_oauth_usage.enterprise.json" 5

transcript="$state/benchmark.jsonl"
now=$(date +%s)
for ((i=0; i<5000; i++)); do
  if (( i % 2 )); then
    printf '{"type":"assistant","timestamp":%d,"message":{"usage":{"input_tokens":1}}}\n' "$((now+i))"
  else
    printf '{"type":"user","timestamp":%d,"message":{"usage":{"input_tokens":1,"cache_read_input_tokens":1}}}\n' "$((now+i))"
  fi
done > "$transcript"
jq --arg t "$transcript" '.transcript_path=$t' "$fixture" > "$state/input.json"
measure '5k transcript cold' "$state/input.json" 1
measure '5k transcript warm' "$state/input.json"
