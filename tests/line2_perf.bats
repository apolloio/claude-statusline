#!/usr/bin/env bats
# Line 2 performance badge tests: 4-dot cache+latency indicator

load test_helper

# ── Badge always present ──────────────────────────────────────────────────────

@test "perf: badge always renders 4 characters" {
  run_statusline "$(make_json)"
  # Badge should have exactly 4 dot chars (● or ○) in line 2
  local stripped; stripped=$(line2)
  local dot_count; dot_count=$(printf '%s' "$stripped" | grep -o '[●○]' | wc -l | tr -d ' ')
  [ "$dot_count" -eq 4 ]
}

@test "perf: all 4 dots grey when no transcript path provided" {
  run_statusline "$(make_json)"
  # All dots grey: grey color code present, no colored-dot (green/yellow/orange/red) codes
  assert_raw_line2_contains "${ANSI_DOT_GREY}"
  assert_output_not_contains "${ANSI_DOT_GREEN}"
  assert_output_not_contains "${ANSI_DOT_YELLOW}"
  assert_output_not_contains "${ANSI_DOT_ORANGE}"
  assert_output_not_contains "${ANSI_DOT_RED}"
}

@test "perf: all 4 dots grey when transcript file does not exist" {
  run_statusline "$(make_json transcript=/nonexistent/path/transcript.jsonl)"
  assert_raw_line2_contains "${ANSI_DOT_GREY}"
  assert_output_not_contains "${ANSI_DOT_GREEN}"
  assert_output_not_contains "${ANSI_DOT_YELLOW}"
  assert_output_not_contains "${ANSI_DOT_ORANGE}"
  assert_output_not_contains "${ANSI_DOT_RED}"
}

@test "perf: badge is in line 2 not line 1" {
  run_statusline "$(make_json)"
  # In colored mode both active and inactive use ●; badge has 4 of them
  assert_line2_contains "●"
  # Line 1 should have no badge dots (it may have effort ● but not 4 in sequence)
  local l1; l1=$(line1)
  local dot_count; dot_count=$(printf '%s' "$l1" | grep -o '[●○]' | wc -l | tr -d ' ')
  [ "$dot_count" -lt 4 ]
}

# ── Green dot (position 0) — high cache + fast response ──────────────────────

@test "perf: position 0 green dot for excellent cache and fast response" {
  local t="$BATS_TEST_TMPDIR/t_green.jsonl"
  local now; now=$(date +%s)
  local u=$((now - 5))   # user at t-5
  local a=$((now - 0))   # assistant at t+0 → 5s response < 10s green threshold
  # cache: 95% hit (cache_read=95, input=5, total=100 → 95% hit rate ≥ 95% green)
  make_transcript "$t" \
    "user:${u}:5:0:95" \
    "assistant:${a}:0:0:0"
  run_statusline "$(make_json transcript="$t")"
  # Position 0 = green active dot (ANSI_DOT_GREEN), no red/orange/yellow
  assert_raw_line2_contains "${ANSI_DOT_GREEN}"
  assert_output_not_contains "${ANSI_DOT_RED}"
}

# ── Yellow dot (position 1) ───────────────────────────────────────────────────

@test "perf: position 1 yellow dot for good-but-not-great signals" {
  local t="$BATS_TEST_TMPDIR/t_yellow.jsonl"
  local now; now=$(date +%s)
  local u=$((now - 20))
  local a=$((now))
  # cache: 91% hit (≥90% but <95% → yellow); response: 20s (>10s but ≤30s → yellow)
  # worst-of: both yellow → overall yellow (level 1)
  make_transcript "$t" \
    "user:${u}:9:0:91" \
    "assistant:${a}:0:0:0"
  run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_YELLOW}"
}

# ── Orange dot (position 2) ───────────────────────────────────────────────────

@test "perf: position 2 orange dot for mediocre signals" {
  local t="$BATS_TEST_TMPDIR/t_orange.jsonl"
  local now; now=$(date +%s)
  local u=$((now - 45))
  local a=$((now))
  # cache: 80% hit (≥75% but <90% → orange level 2); response: 45s (>30s ≤60s → orange)
  make_transcript "$t" \
    "user:${u}:20:0:80" \
    "assistant:${a}:0:0:0"
  run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_ORANGE}"
}

# ── Red dot (position 3) — poor cache + slow response ────────────────────────

@test "perf: position 3 red dot for poor cache and slow response" {
  local t="$BATS_TEST_TMPDIR/t_red.jsonl"
  local now; now=$(date +%s)
  local u=$((now - 90))
  local a=$((now))
  # cache: 10% hit (<75% → red level 3); response: 90s (>60s → red level 3)
  make_transcript "$t" \
    "user:${u}:90:0:10" \
    "assistant:${a}:0:0:0"
  run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_RED}"
  assert_output_not_contains "${ANSI_DOT_GREEN}"
}

# ── Cache-only signal (no timing pairs) ──────────────────────────────────────

@test "perf: cache signal alone drives badge color when no timing pairs" {
  local t="$BATS_TEST_TMPDIR/t_cache_only.jsonl"
  local now; now=$(date +%s)
  # Only assistant entries, no user entries → no timing pairs
  # cache: 97% hit rate → green level 0
  make_transcript "$t" \
    "assistant:${now}:3:0:97"
  run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_GREEN}"
}

@test "perf: poor cache alone → red badge when no timing data" {
  local t="$BATS_TEST_TMPDIR/t_cache_poor.jsonl"
  local now; now=$(date +%s)
  make_transcript "$t" \
    "assistant:${now}:90:0:10"
  run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_RED}"
}

# ── Latency-only: no tokens in transcript ────────────────────────────────────

@test "perf: response-time signal alone drives badge when zero total tokens" {
  local t="$BATS_TEST_TMPDIR/t_rt_only.jsonl"
  local now; now=$(date +%s)
  local u=$((now - 5))
  local a="$now"
  # Zero tokens → cache_hit_rate = "" (unknown); 5s response → green level 0
  make_transcript "$t" \
    "user:${u}:0:0:0" \
    "assistant:${a}:0:0:0"
  run_statusline "$(make_json transcript="$t")"
  # No cache signal + fast response → green
  assert_raw_line2_contains "${ANSI_DOT_GREEN}"
}

# ── Worst-of: mixed signals ────────────────────────────────────────────────────

@test "perf: worst-of logic: poor latency overrides good cache" {
  local t="$BATS_TEST_TMPDIR/t_worst.jsonl"
  local now; now=$(date +%s)
  local u=$((now - 90))
  local a="$now"
  # cache: 97% → green level 0; response: 90s → red level 3 → worst-of = red
  make_transcript "$t" \
    "user:${u}:3:0:97" \
    "assistant:${a}:0:0:0"
  run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_RED}"
}

@test "perf: worst-of logic: poor cache overrides good latency" {
  local t="$BATS_TEST_TMPDIR/t_worst2.jsonl"
  local now; now=$(date +%s)
  local u=$((now - 5))
  local a="$now"
  # cache: 10% → red level 3; response: 5s → green level 0 → worst-of = red
  make_transcript "$t" \
    "user:${u}:90:0:10" \
    "assistant:${a}:0:0:0"
  run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_RED}"
}

# ── Multiple message pairs ────────────────────────────────────────────────────

@test "perf: averages response time across multiple pairs" {
  local t="$BATS_TEST_TMPDIR/t_multi.jsonl"
  local now; now=$(date +%s)
  # Two pairs: 5s and 7s → avg 6s → green (<10s)
  # high cache rate too
  make_transcript "$t" \
    "user:$((now - 100)):5:0:95" \
    "assistant:$((now - 95)):0:0:0" \
    "user:$((now - 10)):0:0:0" \
    "assistant:$((now - 3)):0:0:0"
  run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_GREEN}"
}
