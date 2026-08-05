#!/usr/bin/env bats
# Env var tests: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, CLAUDE_STATUSLINE_CTX_WARN_PCT,
#                CLAUDE_STATUSLINE_CTX_CAUTION_TOKENS

load test_helper

# ── CLAUDE_AUTOCOMPACT_PCT_OVERRIDE ───────────────────────────────────────────
#
# When set to N (1-100): E = min(N, 95), warn_at = E * ctx_warn_pct / 100
#   used >= E        → RED
#   used > warn_at   → ORANGE
#   tokens > caution → BLUE
#   else             → DIM

@test "autocompact=50: used=50% triggers RED (at ceiling)" {
  # E=50, warn_at=50*80/100=40; used_int=50 >= E=50 → RED
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 \
    run_statusline "$(make_json used=50 window=200000)"
  assert_raw_line1_contains "${ANSI_RED}"
}

@test "autocompact=50: used=45% triggers ORANGE (above warn_at=40)" {
  # E=50, warn_at=40; used_int=45 > 40 → ORANGE
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 \
    run_statusline "$(make_json used=45 window=200000)"
  assert_raw_line1_contains "${ANSI_ORANGE}"
}

@test "autocompact=50: used=35% is DIM (below warn_at=40, tokens not exceeding caution)" {
  # E=50, warn_at=40; 35 > 40? No. tokens=70000 < caution_tokens=150000 → DIM
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 \
    run_statusline "$(make_json used=35 window=200000)"
  assert_raw_line1_contains "${ANSI_DIM}"
}

@test "autocompact=80: used=80% triggers RED (at ceiling)" {
  # E=80, warn_at=64; used_int=80 >= E=80 → RED
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=80 \
    run_statusline "$(make_json used=80 window=200000)"
  assert_raw_line1_contains "${ANSI_RED}"
}

@test "autocompact=80: used=70% triggers ORANGE (above warn_at=64)" {
  # E=80, warn_at=64; used_int=70 > 64 → ORANGE
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=80 \
    run_statusline "$(make_json used=70 window=200000)"
  assert_raw_line1_contains "${ANSI_ORANGE}"
}

@test "autocompact=80: used=60% is DIM (below warn_at=64)" {
  # E=80, warn_at=64; 60 > 64? No. tokens=120000 < 150000 → DIM
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=80 \
    run_statusline "$(make_json used=60 window=200000)"
  assert_raw_line1_contains "${ANSI_DIM}"
}

@test "autocompact=100: E is capped at 95 (used=96% → RED)" {
  # N=100, E=min(100,95)=95; used_int=96 >= 95 → RED (same as default behavior)
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=100 \
    run_statusline "$(make_json used=96 window=200000)"
  assert_raw_line1_contains "${ANSI_RED}"
}

@test "autocompact=0: invalid value ignored (falls back to standard thresholds)" {
  # 0 is out of range 1-100; pct_ov stays empty → standard thresholds
  # Standard: used=96% → RED (>= 95)
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=0 \
    run_statusline "$(make_json used=96 window=200000)"
  assert_raw_line1_contains "${ANSI_RED}"
}

@test "autocompact=abc: non-numeric value ignored (standard thresholds)" {
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=abc \
    run_statusline "$(make_json used=96 window=200000)"
  assert_raw_line1_contains "${ANSI_RED}"
}

# ── CLAUDE_STATUSLINE_CTX_WARN_PCT ────────────────────────────────────────────
#
# Only takes effect when AUTOCOMPACT_PCT_OVERRIDE is also set.
# warn_at = E * ctx_warn_pct / 100

@test "ctx_warn_pct=50 with autocompact=80: ORANGE at 45% usage (above warn_at=40)" {
  # E=80, warn_at=80*50/100=40; used_int=45 > 40 → ORANGE
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=80 CLAUDE_STATUSLINE_CTX_WARN_PCT=50 \
    run_statusline "$(make_json used=45 window=200000)"
  assert_raw_line1_contains "${ANSI_ORANGE}"
}

@test "ctx_warn_pct=90 with autocompact=80: 45% is DIM (below warn_at=72)" {
  # E=80, warn_at=80*90/100=72; used_int=45 > 72? No → DIM (tokens below caution)
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=80 CLAUDE_STATUSLINE_CTX_WARN_PCT=90 \
    run_statusline "$(make_json used=45 window=200000)"
  assert_raw_line1_contains "${ANSI_DIM}"
}

@test "ctx_warn_pct=90 with autocompact=80: 75% triggers ORANGE (above warn_at=72)" {
  # E=80, warn_at=72; used_int=75 > 72 → ORANGE
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=80 CLAUDE_STATUSLINE_CTX_WARN_PCT=90 \
    run_statusline "$(make_json used=75 window=200000)"
  assert_raw_line1_contains "${ANSI_ORANGE}"
}

@test "ctx_warn_pct=50 with autocompact=80: 35% is DIM (below warn_at=40)" {
  # E=80, warn_at=40; used_int=35 > 40? No → DIM
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=80 CLAUDE_STATUSLINE_CTX_WARN_PCT=50 \
    run_statusline "$(make_json used=35 window=200000)"
  assert_raw_line1_contains "${ANSI_DIM}"
}

@test "ctx_warn_pct invalid (0) is silently ignored (defaults to 80)" {
  # Invalid value → keeps default 80; E=50, warn_at=50*80/100=40; used=45 → ORANGE
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 CLAUDE_STATUSLINE_CTX_WARN_PCT=0 \
    run_statusline "$(make_json used=45 window=200000)"
  assert_raw_line1_contains "${ANSI_ORANGE}"
}

@test "ctx_warn_pct invalid (100) is silently ignored (defaults to 80)" {
  # 100 is out of range 1-99; defaults to 80; E=50, warn_at=40
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 CLAUDE_STATUSLINE_CTX_WARN_PCT=100 \
    run_statusline "$(make_json used=45 window=200000)"
  assert_raw_line1_contains "${ANSI_ORANGE}"
}

# ── CLAUDE_STATUSLINE_CTX_CAUTION_TOKENS ──────────────────────────────────────
#
# Threshold for BLUE caution color. 0 → disabled.
# Only triggers when used_int is below orange threshold.

@test "ctx_caution_tokens=100000: BLUE when tokens exceed custom threshold" {
  # Window=500000, used=31% → 155000 tokens > 100000 → BLUE
  # (31 > 75? No; 31 > warn_at? depends on mode; standard: 31 > 75 No → check blue)
  CLAUDE_STATUSLINE_CTX_CAUTION_TOKENS=100000 \
    run_statusline "$(make_json used=31 window=500000)"
  assert_raw_line1_contains "${ANSI_BLUE}"
}

@test "ctx_caution_tokens=0: BLUE disabled even when tokens would normally trigger it" {
  # Window=500000, used=31% → 155000 tokens; default would be BLUE, but 0 disables
  # Note: BLUE also appears on line 2 from the ∑ˢ badge, so check only line 1.
  CLAUDE_STATUSLINE_CTX_CAUTION_TOKENS=0 \
    run_statusline "$(make_json used=31 window=500000)"
  assert_raw_line1_not_contains "${ANSI_BLUE}"
  # Should fall through to DIM
  assert_raw_line1_contains "${ANSI_DIM}"
}

@test "ctx_caution_tokens=200000: BLUE NOT triggered when tokens below new threshold" {
  # Window=500000, used=31% → 155000 tokens; 155000 > 200000? No → DIM (not BLUE)
  # Note: BLUE also appears on line 2 from the ∑ˢ badge, so check only line 1.
  CLAUDE_STATUSLINE_CTX_CAUTION_TOKENS=200000 \
    run_statusline "$(make_json used=31 window=500000)"
  assert_raw_line1_not_contains "${ANSI_BLUE}"
}

@test "ctx_caution_tokens default (150000): BLUE at 31% of 500k window" {
  # 31% of 500000 = 155000 tokens > 150000 → BLUE (default threshold)
  run_statusline "$(make_json used=31 window=500000)"
  assert_raw_line1_contains "${ANSI_BLUE}"
}

@test "ctx_caution_tokens=0 script still exits 0 and produces 2 lines" {
  CLAUDE_STATUSLINE_CTX_CAUTION_TOKENS=0 \
    run_statusline "$(make_json used=31 window=500000)"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}
