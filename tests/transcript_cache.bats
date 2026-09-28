#!/usr/bin/env bats

load test_helper

cache_file() {
  find "$CLAUDE_STATUSLINE_STATE_DIR" -name 'statusline-transcript-metrics.*.cache' -type f | head -1
}

@test "transcript cache: creates and reuses a version 4 cache" {
  local t="$BATS_TEST_TMPDIR/transcript.jsonl" now cache before after
  now=$(date +%s)
  make_transcript "$t" "user:$((now-5)):5:0:95" "assistant:${now}:0:0:0"
  run_statusline "$(make_json transcript="$t")"
  [ "$status" -eq 0 ]
  cache=$(cache_file)
  [ -f "$cache" ]
  [ "$(head -1 "$cache")" = 4 ]
  before=$(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache")
  run_statusline "$(make_json transcript="$t")"
  after=$(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache")
  [ "$before" = "$after" ]
}

@test "transcript cache: incrementally merges appended records" {
  local t="$BATS_TEST_TMPDIR/append.jsonl" now cache old_offset new_offset
  now=$(date +%s)
  make_transcript "$t" "user:$((now-5)):90:0:10" "assistant:${now}:0:0:0"
  CLAUDE_STATUSLINE_PERF_BADGE=cache_only run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "$ANSI_DOT_RED"
  cache=$(cache_file); old_offset=$(sed -n '5p' "$cache")
  printf '{"type":"user","timestamp":%s,"message":{"usage":{"input_tokens":0,"cache_read_input_tokens":900}}}\n' "$((now+1))" >> "$t"
  CLAUDE_STATUSLINE_PERF_BADGE=cache_only run_statusline "$(make_json transcript="$t")"
  new_offset=$(sed -n '5p' "$cache")
  [ "$new_offset" -gt "$old_offset" ]
  assert_raw_line2_contains "$ANSI_DOT_YELLOW"
}

@test "transcript cache: retains a partial trailing JSON record for retry" {
  local t="$BATS_TEST_TMPDIR/partial.jsonl" now cache offset size
  now=$(date +%s)
  printf '{"type":"user","timestamp":%s}' "$now" > "$t"
  run_statusline "$(make_json transcript="$t")"
  cache=$(cache_file); offset=$(sed -n '5p' "$cache")
  [ "$offset" -eq 0 ]
  printf '\n{"type":"assistant","timestamp":%s}\n' "$((now+5))" >> "$t"
  run_statusline "$(make_json transcript="$t")"
  size=$(wc -c < "$t" | tr -d ' ')
  [ "$(sed -n '5p' "$cache")" -eq "$size" ]
  assert_raw_line2_contains "$ANSI_DOT_GREEN"
}

@test "transcript metrics: normalize documented roles, timestamps, and ordering" {
  local t="$BATS_TEST_TMPDIR/forms.jsonl"
  printf '%s\n' \
    '{"role":"assistant","timestamp":"2026-01-01T12:00:05.999+02:00"}' \
    '{"message":{"role":"human"},"timestamp":{"milliseconds":1767261600000000}}' \
    '{"type":"ignored","timestamp":true}' > "$t"
  CLAUDE_STATUSLINE_PERF_BADGE=latency_only run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "$ANSI_DOT_GREEN"
}

@test "transcript cache: ultracode shares the processor and last event wins" {
  local t="$BATS_TEST_TMPDIR/ultra.jsonl"
  printf '%s\n' \
    '{"attachment":{"type":"ultra_effort_enter"}}' \
    '{"attachment":{"type":"ultra_effort_exit"}}' \
    '{"attachment":{"type":"ultra_effort_enter"}}' > "$t"
  run_statusline "$(make_json transcript="$t" effort=xhigh)"
  [[ "$(line1)" == *ultracode* ]]
  [ -f "$(cache_file)" ]
}

@test "transcript cache: disabling both consumers performs no transcript stat or read" {
  local t="$BATS_TEST_TMPDIR/no-read.jsonl"
  printf 'not-json\n' > "$t"
  chmod 000 "$t"
  CLAUDE_STATUSLINE_PERF_BADGE=off CLAUDE_STATUSLINE_ULTRACODE=off run_statusline "$(make_json transcript="$t")"
  [ "$status" -eq 0 ]
  [ -z "$(cache_file)" ]
}

@test "transcript cache: mode changes rebuild only missing historical validity" {
  local t="$BATS_TEST_TMPDIR/modes.jsonl" now cache
  now=$(date +%s)
  make_transcript "$t" "user:$((now-5)):5:0:95" "assistant:${now}:0:0:0"
  CLAUDE_STATUSLINE_PERF_BADGE=cache_only run_statusline "$(make_json transcript="$t")"
  cache=$(cache_file)
  [ "$(sed -n '6p' "$cache")" = 1 ]
  [ "$(sed -n '7p' "$cache")" = 0 ]
  CLAUDE_STATUSLINE_PERF_BADGE=latency_only run_statusline "$(make_json transcript="$t")"
  [ "$(sed -n '6p' "$cache")" = 1 ]
  [ "$(sed -n '7p' "$cache")" = 1 ]
  assert_raw_line2_contains "$ANSI_DOT_GREEN"
}

@test "transcript cache: corruption and truncation trigger safe rebuilds" {
  local t="$BATS_TEST_TMPDIR/rebuild.jsonl" now cache
  now=$(date +%s)
  make_transcript "$t" "user:$((now-5)):5:0:95" "assistant:${now}:0:0:0"
  run_statusline "$(make_json transcript="$t")"; cache=$(cache_file)
  printf 'broken\n' > "$cache"
  run_statusline "$(make_json transcript="$t")"
  [ "$(head -1 "$cache")" = 4 ]
  make_transcript "$t" "user:$((now-90)):90:0:10" "assistant:${now}:0:0:0"
  touch -t 203001010000 "$t"
  run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "$ANSI_DOT_RED"
}

@test "transcript cache: disordered append falls back to globally sorted rebuild" {
  local t="$BATS_TEST_TMPDIR/disorder.jsonl" cache
  make_transcript "$t" "user:100:0:0:0" "assistant:105:0:0:0"
  CLAUDE_STATUSLINE_PERF_BADGE=latency_only run_statusline "$(make_json transcript="$t")"
  cache=$(cache_file)
  printf '%s\n' '{"type":"user","timestamp":50}' '{"type":"assistant","timestamp":140}' >> "$t"
  CLAUDE_STATUSLINE_PERF_BADGE=latency_only run_statusline "$(make_json transcript="$t")"
  [ "$(sed -n '10p' "$cache")" = 5 ]
  [ "$(sed -n '11p' "$cache")" = 1 ]
}

@test "transcript metrics: equal and 24-hour boundary pairs are excluded" {
  local t="$BATS_TEST_TMPDIR/boundary.jsonl"
  printf '%s\n' \
    '{"type":"user","timestamp":100}' '{"type":"assistant","timestamp":100}' \
    '{"type":"user","timestamp":200}' '{"type":"assistant","timestamp":86600}' > "$t"
  CLAUDE_STATUSLINE_PERF_BADGE=latency_only run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "$ANSI_DOT_GREY"
}

@test "transcript cache: stale caches are reaped on instance cold start" {
  local stale="$CLAUDE_STATUSLINE_STATE_DIR/statusline-transcript-metrics.stale.cache"
  printf '4\n' > "$stale"; touch -t 202001010000 "$stale"
  run_statusline "$(make_json)"
  [ ! -e "$stale" ]
}
