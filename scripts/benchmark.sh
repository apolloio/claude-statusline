#!/usr/bin/env bash
# Local, deterministic advisory benchmark for the statusline render path.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
script="$root/statusline-command.sh"
state=$(mktemp -d "${TMPDIR:-/tmp}/claude-statusline-bench.XXXXXX")
trap 'rm -rf "$state"' EXIT
export CLAUDE_STATUSLINE_STATE_DIR="$state"
export CLAUDE_STATUSLINE_INSTANCE_ID=benchmark
export COLUMNS=200
fixture="$root/examples/input.json"

render() { bash "$script" < "$1" >/dev/null; }
clock_ms() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time * 1000'; }
measure() {
  local name=$1 input=$2 count=${3:-20} started ended elapsed average
  started=$(clock_ms)
  local i
  for ((i=0; i<count; i++)); do render "$input"; done
  ended=$(clock_ms)
  read -r elapsed average < <(awk -v a="$started" -v b="$ended" -v n="$count" 'BEGIN{printf "%.1f %.1f\n",b-a,(b-a)/n}')
  printf '%-25s %7s ms avg  (%s ms total)\n' "$name" "$average" "$elapsed"
}

render "$fixture"
measure 'minimal warm render' "$fixture" 20

cp "$root/examples/api_oauth_usage.enterprise.json" "$state/statusline-usage-cache.json"
touch "$state/statusline-usage-cache.json"
measure 'enterprise render' "$fixture" 10

git_dir="$state/git-workspace"
mkdir -p "$git_dir"
git -C "$git_dir" init --quiet
jq --arg d "$git_dir" '.workspace.current_dir=$d' "$fixture" > "$state/git-input.json"
measure 'git workspace render' "$state/git-input.json" 10

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
printf '{"type":"user","timestamp":%d,"message":{"usage":{"input_tokens":1}}}\n' "$((now+5001))" >> "$transcript"
measure '5k one-row append' "$state/input.json" 10
