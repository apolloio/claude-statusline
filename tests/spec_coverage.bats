#!/usr/bin/env bats
# Tests for SPEC behaviors not covered by other test files.

load test_helper

# ═══════════════════════════════════════════════════════════════════════════════
# §8.2 — 5h-burned state (Pro/Max: utilization ≥ 100)
# ═══════════════════════════════════════════════════════════════════════════════

@test "5h-burned: utilization=100 → 🪫 glyph on line 2" {
  write_promax_cache 100 30
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "🪫"
}

@test "5h-burned: utilization=100 → shows 100% in 5h slot" {
  write_promax_cache 100 30
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "100%"
}

@test "5h-burned: utilization=100 → RED BOLD applied to 5h slot" {
  write_promax_cache 100 30
  run_statusline "$(make_json cwd=/tmp)"
  assert_raw_line2_contains "${ANSI_RED}"
  assert_raw_line2_contains "${ANSI_BOLD}"
}

@test "5h-burned: utilization=100 → no STRIKETHROUGH (burned ≠ stale)" {
  # SPEC §8.2: burned state uses RED BOLD, not STRIKETHROUGH (which means stale).
  write_promax_cache 100 30
  run_statusline "$(make_json cwd=/tmp)"
  assert_raw_line2_not_contains "${ANSI_STRIKETHROUGH}"
}

@test "5h-burned: 7d slot still rendered normally when only 5h hits 100" {
  write_promax_cache 100 30
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "7d:"
}

# ═══════════════════════════════════════════════════════════════════════════════
# §8.4 — Budget-burned state (Enterprise: used_credits ≥ monthly_limit)
# ═══════════════════════════════════════════════════════════════════════════════

@test "budget-burned: used_credits >= monthly_limit → 🪫 glyph" {
  write_enterprise_cache 100000 100000
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "🪫"
}

@test "budget-burned: no ≈% shown when burned" {
  # SPEC §8.4: burned state omits percentage (≈pct_int%).
  write_enterprise_cache 100000 100000
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_not_contains "≈"
}

@test "budget-burned: no 🔥pace shown when burned (even with show_pace_ratio=on)" {
  # SPEC §8.4: burned state omits pace ratio.
  write_enterprise_cache 100000 100000
  CLAUDE_STATUSLINE_SHOW_PACE_RATIO=on run_statusline "$(make_json cwd=/tmp)"
  assert_line2_not_contains "🔥"
}

@test "budget-burned: 💰 glyph replaced by 🪫" {
  write_enterprise_cache 100000 100000
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_not_contains "💰"
  assert_line2_contains "🪫"
}

@test "budget-burned: still exits 0 and produces 2 lines" {
  write_enterprise_cache 100000 100000
  run_statusline "$(make_json cwd=/tmp)"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# §4.6 / §8.4 — Auth-broken state (Enterprise monthly segment)
# ═══════════════════════════════════════════════════════════════════════════════

@test "auth-broken enterprise: 🔑 shown instead of 💰 or ⚠️" {
  write_enterprise_cache 5000 100000
  write_auth_error_sentinel
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "🔑"
  assert_line2_not_contains "💰"
  assert_line2_not_contains "⚠️"
}

@test "auth-broken enterprise: amount struck through" {
  # SPEC §8.4: auth-broken state applies STRIKETHROUGH to the last-known amount.
  write_enterprise_cache 5000 100000
  write_auth_error_sentinel
  run_statusline "$(make_json cwd=/tmp)"
  assert_raw_line2_contains "${ANSI_STRIKETHROUGH}"
}

@test "auth-broken enterprise: takes precedence over stale cache" {
  write_enterprise_cache 5000 100000
  make_usage_cache_stale
  write_auth_error_sentinel
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "🔑"
  assert_line2_not_contains "⚠️"
}

# ═══════════════════════════════════════════════════════════════════════════════
# §4.6 / §8.3 — Auth-broken state (Pro/Max extra usage badge)
# ═══════════════════════════════════════════════════════════════════════════════

@test "auth-broken promax extra: 🔑 shown in extra badge" {
  write_promax_extra_cache 80 30 1000 5000
  write_auth_error_sentinel
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "🔑"
}

@test "auth-broken promax extra: takes precedence over stale" {
  write_promax_extra_cache 80 30 1000 5000
  make_usage_cache_stale
  write_auth_error_sentinel
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "🔑"
  assert_line2_not_contains "+⚠️"
}

# ═══════════════════════════════════════════════════════════════════════════════
# §8.3 — Pro/Max extra usage badge (+💰)
# ═══════════════════════════════════════════════════════════════════════════════

@test "extra badge: shown when used_credits > 0 and extra_usage.is_enabled" {
  write_promax_extra_cache 50 30 1000 5000
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "+💰"
}

@test "extra badge: shown when utilization >= EXTRA_PREVIEW_PCT (default 75)" {
  # utilization=80 >= 75 (default threshold), used_credits=0 → preview trigger.
  write_promax_extra_cache 80 30 0 5000
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "+💰"
}

@test "extra badge: NOT shown when utilization < EXTRA_PREVIEW_PCT and used_credits=0" {
  # utilization=50 < 75 (default), used_credits=0 → neither trigger met.
  write_promax_extra_cache 50 30 0 5000
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_not_contains "+💰"
}

@test "extra badge: NOT shown when monthly_limit=0 even if used_credits > 0" {
  # SPEC §8.3: shown only when monthly_limit != 0.
  write_promax_extra_cache 80 30 1000 0
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_not_contains "+💰"
}

@test "extra badge: NOT shown when extra_usage.is_enabled=false" {
  # is_enabled=false → badge suppressed entirely.
  write_promax_cache 80 30
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_not_contains "+💰"
}

# ═══════════════════════════════════════════════════════════════════════════════
# §3.4 — CLAUDE_STATUSLINE_EXTRA_PREVIEW_PCT env var
# ═══════════════════════════════════════════════════════════════════════════════

@test "extra_preview_pct=50: badge shown when utilization=60 (above custom threshold)" {
  write_promax_extra_cache 60 30 0 5000
  CLAUDE_STATUSLINE_EXTRA_PREVIEW_PCT=50 run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "+💰"
}

@test "extra_preview_pct=90: badge NOT shown when utilization=80 (below custom threshold)" {
  write_promax_extra_cache 80 30 0 5000
  CLAUDE_STATUSLINE_EXTRA_PREVIEW_PCT=90 run_statusline "$(make_json cwd=/tmp)"
  assert_line2_not_contains "+💰"
}

@test "extra_preview_pct=0: badge always shown when is_enabled and limit>0" {
  # 0 = always show. Even with utilization=10, used_credits=0.
  write_promax_extra_cache 10 30 0 5000
  CLAUDE_STATUSLINE_EXTRA_PREVIEW_PCT=0 run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "+💰"
}

@test "extra_preview_pct=100: badge shown only when used_credits > 0 (100 = never preview)" {
  # Threshold 100 means utilization must be >= 100 for preview; effectively disabled for preview.
  # With used_credits > 0, it still shows.
  write_promax_extra_cache 80 30 1000 5000
  CLAUDE_STATUSLINE_EXTRA_PREVIEW_PCT=100 run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "+💰"
}

@test "extra_preview_pct does not affect Enterprise segment (no extra badge there)" {
  write_enterprise_cache 5000 100000
  CLAUDE_STATUSLINE_EXTRA_PREVIEW_PCT=50 run_statusline "$(make_json cwd=/tmp)"
  # Enterprise monthly segment should still render normally
  assert_line2_contains "💰"
  assert_line2_not_contains "+💰"
}

# ═══════════════════════════════════════════════════════════════════════════════
# §8.7 — NODATA em-dash in rolling windows
# ═══════════════════════════════════════════════════════════════════════════════

@test "NODATA: em-dash (—) in 15m slot when cost_now=0 and no session rows" {
  # SPEC §8.7: trigger = no matching log rows in window AND cost_now == 0.
  run_statusline "$(make_json cwd=/tmp cost=0.00)"
  assert_line2_contains "15m:—"
}

@test "NODATA: em-dash (—) in 1h slot when cost_now=0 and no session rows" {
  run_statusline "$(make_json cwd=/tmp cost=0.00)"
  assert_line2_contains "1h:—"
}

@test "NODATA: em-dash (—) in 1d slot when cost_now=0 and no session rows" {
  run_statusline "$(make_json cwd=/tmp cost=0.00)"
  assert_line2_contains "1d:—"
}

@test "NODATA: no em-dash when cost_now > 0 (even without prior log rows)" {
  # With cost_now > 0, fallback ref = cost_now → spent = 0 → show \$0.00, not em-dash.
  run_statusline "$(make_json cwd=/tmp cost=0.50)"
  assert_line2_not_contains "—"
}

@test "NODATA: no em-dash after session has a prior log row" {
  # Inject a prior log entry for the same cwd; now there IS a matching row.
  inject_log_entry /tmp 0.10 30 "test-session-42"
  run_statusline "$(make_json cwd=/tmp cost=0.00 session=test-session-42)"
  assert_line2_not_contains "—"
}

# ═══════════════════════════════════════════════════════════════════════════════
# §4.6 — API error body in cache file (rate-limit / server error)
# ═══════════════════════════════════════════════════════════════════════════════

@test "api-error-in-cache: renders 2 lines without crash" {
  # An API error body (not a curl failure) previously bypassed the jq validity
  # check and silently replaced a good cache, hiding the plan segment entirely.
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  printf '{"error":{"type":"rate_limit_error","message":"Rate limited."}}\n' \
    > "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-cache.json"
  run_statusline "$(make_json cwd=/tmp)"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "api-error-in-cache: no plan segment rendered (error body has no usage fields)" {
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  printf '{"error":{"type":"rate_limit_error","message":"Rate limited."}}\n' \
    > "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-cache.json"
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_not_contains "💰"
  assert_line2_not_contains "🪫"
  assert_line2_not_contains "⚠️"
  assert_line2_not_contains "🔑"
}

@test "api-error-in-cache: no 5h/7d slots rendered" {
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  printf '{"error":{"type":"rate_limit_error","message":"Rate limited."}}\n' \
    > "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-cache.json"
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_not_contains "5h:"
  assert_line2_not_contains "7d:"
}
