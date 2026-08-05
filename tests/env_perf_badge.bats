#!/usr/bin/env bats
# Env var tests: CLAUDE_STATUSLINE_PERF_BADGE (off/on/cache_only/latency_only)

load test_helper

# ── off: badge completely suppressed ─────────────────────────────────────────

@test "perf_badge=off: no dot characters in line 2 (no transcript)" {
  CLAUDE_STATUSLINE_PERF_BADGE=off run_statusline "$(make_json)"
  assert_output_not_contains "${ANSI_DOT_GREY}"
  assert_output_not_contains "${ANSI_DOT_GREEN}"
  assert_output_not_contains "${ANSI_DOT_YELLOW}"
  assert_output_not_contains "${ANSI_DOT_ORANGE}"
  assert_output_not_contains "${ANSI_DOT_RED}"
}

@test "perf_badge=off: no dots even with a high-cache transcript" {
  local t="$BATS_TEST_TMPDIR/t_off.jsonl"
  local now; now=$(date +%s)
  make_transcript "$t" \
    "user:$((now - 5)):5:0:95" \
    "assistant:${now}:0:0:0"
  CLAUDE_STATUSLINE_PERF_BADGE=off run_statusline "$(make_json transcript="$t")"
  assert_output_not_contains "${ANSI_DOT_GREEN}"
  assert_output_not_contains "${ANSI_DOT_GREY}"
}

@test "perf_badge=off: script still exits 0 and produces 2 lines" {
  CLAUDE_STATUSLINE_PERF_BADGE=off run_statusline "$(make_json)"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

# ── on: default full badge (cache + latency) ──────────────────────────────────

@test "perf_badge=on: badge present (grey dots with no transcript)" {
  CLAUDE_STATUSLINE_PERF_BADGE=on run_statusline "$(make_json)"
  assert_raw_line2_contains "${ANSI_DOT_GREY}"
}

@test "perf_badge=on: green dot when cache and latency both excellent" {
  local t="$BATS_TEST_TMPDIR/t_on_green.jsonl"
  local now; now=$(date +%s)
  make_transcript "$t" \
    "user:$((now - 5)):5:0:95" \
    "assistant:${now}:0:0:0"
  CLAUDE_STATUSLINE_PERF_BADGE=on run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_GREEN}"
}

# ── cache_only: latency signal is ignored ────────────────────────────────────

@test "perf_badge=cache_only: poor cache → red despite fast response" {
  local t="$BATS_TEST_TMPDIR/t_cache_bad.jsonl"
  local now; now=$(date +%s)
  # Fast response (5s → green latency), poor cache (10% → red cache)
  # cache_only must ignore latency → badge driven by cache → red
  make_transcript "$t" \
    "user:$((now - 5)):90:0:10" \
    "assistant:${now}:0:0:0"
  CLAUDE_STATUSLINE_PERF_BADGE=cache_only run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_RED}"
  assert_output_not_contains "${ANSI_DOT_GREEN}"
}

@test "perf_badge=cache_only: excellent cache → green (latency not consulted)" {
  local t="$BATS_TEST_TMPDIR/t_cache_good.jsonl"
  local now; now=$(date +%s)
  # Slow response (90s → red latency), but cache_only ignores it
  make_transcript "$t" \
    "user:$((now - 90)):5:0:95" \
    "assistant:${now}:0:0:0"
  CLAUDE_STATUSLINE_PERF_BADGE=cache_only run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_GREEN}"
  assert_output_not_contains "${ANSI_DOT_RED}"
}

@test "perf_badge=cache_only: no cache tokens in transcript → grey badge" {
  local t="$BATS_TEST_TMPDIR/t_cache_zero.jsonl"
  local now; now=$(date +%s)
  # Zero tokens → no cache_hit_rate (cache unknown); cache_only → latency also skipped
  make_transcript "$t" \
    "user:$((now - 5)):0:0:0" \
    "assistant:${now}:0:0:0"
  CLAUDE_STATUSLINE_PERF_BADGE=cache_only run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_GREY}"
  assert_output_not_contains "${ANSI_DOT_GREEN}"
}

# ── latency_only: cache signal is ignored ────────────────────────────────────

@test "perf_badge=latency_only: fast response → green despite poor cache" {
  local t="$BATS_TEST_TMPDIR/t_lat_fast.jsonl"
  local now; now=$(date +%s)
  # Poor cache (10% → red), fast response (5s → green)
  # latency_only ignores cache → green
  make_transcript "$t" \
    "user:$((now - 5)):90:0:10" \
    "assistant:${now}:0:0:0"
  CLAUDE_STATUSLINE_PERF_BADGE=latency_only run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_GREEN}"
  assert_output_not_contains "${ANSI_DOT_RED}"
}

@test "perf_badge=latency_only: slow response → red despite excellent cache" {
  local t="$BATS_TEST_TMPDIR/t_lat_slow.jsonl"
  local now; now=$(date +%s)
  make_transcript "$t" \
    "user:$((now - 90)):5:0:95" \
    "assistant:${now}:0:0:0"
  CLAUDE_STATUSLINE_PERF_BADGE=latency_only run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_RED}"
  assert_output_not_contains "${ANSI_DOT_GREEN}"
}

@test "perf_badge=latency_only: no timing pairs → grey (cache not consulted)" {
  local t="$BATS_TEST_TMPDIR/t_lat_no_timing.jsonl"
  local now; now=$(date +%s)
  # Only assistant entry → no user→assistant pair → no response time
  make_transcript "$t" \
    "assistant:${now}:5:0:95"
  CLAUDE_STATUSLINE_PERF_BADGE=latency_only run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_GREY}"
  assert_output_not_contains "${ANSI_DOT_GREEN}"
}

# ── Case insensitivity ────────────────────────────────────────────────────────

@test "perf_badge=OFF: uppercase treated same as off (no dots)" {
  CLAUDE_STATUSLINE_PERF_BADGE=OFF run_statusline "$(make_json)"
  assert_output_not_contains "${ANSI_DOT_GREY}"
  assert_output_not_contains "${ANSI_DOT_GREEN}"
}

@test "perf_badge=CACHE_ONLY: uppercase treated same as cache_only" {
  local t="$BATS_TEST_TMPDIR/t_cache_upper.jsonl"
  local now; now=$(date +%s)
  make_transcript "$t" \
    "user:$((now - 5)):5:0:95" \
    "assistant:${now}:0:0:0"
  CLAUDE_STATUSLINE_PERF_BADGE=CACHE_ONLY run_statusline "$(make_json transcript="$t")"
  assert_raw_line2_contains "${ANSI_DOT_GREEN}"
}

@test "perf_badge=LATENCY_ONLY: uppercase treated same as latency_only" {
  local t="$BATS_TEST_TMPDIR/t_lat_upper.jsonl"
  local now; now=$(date +%s)
  make_transcript "$t" \
    "user:$((now - 5)):90:0:10" \
    "assistant:${now}:0:0:0"
  CLAUDE_STATUSLINE_PERF_BADGE=LATENCY_ONLY run_statusline "$(make_json transcript="$t")"
  # latency_only: 5s → green (cache ignored)
  assert_raw_line2_contains "${ANSI_DOT_GREEN}"
}

# ── Unknown value falls back to on (default) ──────────────────────────────────

@test "perf_badge=bogus: unknown value treated as default (badge shown)" {
  CLAUDE_STATUSLINE_PERF_BADGE=bogus run_statusline "$(make_json)"
  # Falls through to default on-like behavior; badge computed (no transcript → grey)
  assert_raw_line2_contains "${ANSI_DOT_GREY}"
}
