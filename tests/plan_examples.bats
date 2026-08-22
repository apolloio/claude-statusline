#!/usr/bin/env bats
# End-to-end plan display examples (§15 Examples A–F).
#
# Example A: Pro/Max fresh cache, no extra badge.
# Example B: Pro/Max fresh cache, extra-credits preview active (5h ≥ 75%).
# Example C: Enterprise, fresh cache, cost_loadavg=on → allowance suffix on 1h/1d.
# Example E: Enterprise, budget-burned (used >= limit) → 🪫, /$0 suffix, RED on spent.
# Example F: Enterprise, auth-broken (sentinel file present) — no ≈%, no 🔥, no /$allowance.
#
# Allowance amounts (e.g. $18, $3) are date-dependent (remaining workdays vary),
# so tests verify format (/$<integer>) not exact values — except for the burned
# case where the integer must be 0.

load test_helper

# ── Example A: Pro/Max fresh, no extra badge ──────────────────────────────────

@test "example A: pro fresh → 5h slot present" {
  write_pro_cache 60 7 0 100
  run_statusline "$(make_json cwd=/tmp cost=0.42 session=s1)"
  [ "$status" -eq 0 ]
  assert_line2_contains "5h:60%"
}

@test "example A: pro fresh → 7d slot present" {
  write_pro_cache 60 7 0 100
  run_statusline "$(make_json cwd=/tmp cost=0.42 session=s1)"
  assert_line2_contains "7d:7%"
}

@test "example A: pro fresh → no extra badge (5h=60 < 75 and used=0)" {
  write_pro_cache 60 7 0 100
  run_statusline "$(make_json cwd=/tmp cost=0.42 session=s1)"
  assert_line2_not_contains "+💰"
  assert_line2_not_contains "+🔑"
  assert_line2_not_contains "+⚠️"
}

@test "example A: pro fresh → 1h and 1d slots have no allowance suffix" {
  write_pro_cache 60 7 0 100
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=0.42 session=s1)"
  local l2; l2=$(line2)
  [[ "$l2" != *"1h:"*"/\$"* ]]
  [[ "$l2" != *"1d:"*"/\$"* ]]
}

# ── Example B: Pro/Max fresh, extra-credits preview ───────────────────────────

@test "example B: extra preview → +💰 shown when 5h ≥ 75%" {
  write_pro_cache 82 7 0 100 "2099-01-01T17:00:00.000000Z"
  run_statusline "$(make_json cwd=/tmp cost=0.95 session=s1)"
  [ "$status" -eq 0 ]
  assert_line2_contains "+💰"
}

@test "example B: extra preview → ↻ reset-time suffix on 5h slot (5h ≥ 75 + resets_at set)" {
  write_pro_cache 82 7 0 100 "2099-01-01T17:00:00.000000Z"
  run_statusline "$(make_json cwd=/tmp cost=0.95 session=s1)"
  assert_line2_contains "↻"
}

@test "example B: extra preview → \$0.00 used shown in badge" {
  write_pro_cache 82 7 0 100
  run_statusline "$(make_json cwd=/tmp cost=0.95 session=s1)"
  assert_line2_contains "\$0.00"
}

@test "example B: extra preview → limit shown as /\$1" {
  write_pro_cache 82 7 0 100
  run_statusline "$(make_json cwd=/tmp cost=0.95 session=s1)"
  assert_line2_contains "/\$1"
}

@test "example B: extra preview badge has no internal spaces" {
  write_pro_cache 82 7 0 100
  run_statusline "$(make_json cwd=/tmp cost=0.95 session=s1)"
  local l2; l2=$(line2)
  [[ "$l2" == *"+💰\$0.00/\$1"* ]]
  [[ "$l2" != *"+💰 \$0.00 /\$1"* ]]
}

@test "example B: extra preview badge is separated from the 7d slot" {
  write_pro_cache 82 7 0 100
  run_statusline "$(make_json cwd=/tmp cost=0.95 session=s1)"
  local l2; l2=$(line2)
  [[ "$l2" == *"7d:7%  +💰\$0.00/\$1"* ]]
}

@test "example B: no extra badge when 5h < 75 and used=0" {
  write_pro_cache 60 7 0 100
  run_statusline "$(make_json cwd=/tmp cost=0.95 session=s1)"
  assert_line2_not_contains "+💰"
}

# ── Example C: fresh Enterprise cache — allowance suffixes in 1h/1d ───────────

@test "example C: fresh enterprise → 💰 glyph present" {
  write_enterprise_cache 18627 50000
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  [ "$status" -eq 0 ]
  assert_line2_contains "💰"
}

@test "example C: fresh enterprise → ≈37% shown (from used/limit)" {
  write_enterprise_cache 18627 50000
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  assert_line2_contains "≈37%"
}

@test "example C: fresh enterprise → 1h slot has allowance suffix (/$integer)" {
  write_enterprise_cache 18627 50000
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  [[ "$(line2)" =~ 1h:[^/]*/\$[0-9]+ ]]
}

@test "example C: fresh enterprise → 1d slot has allowance suffix (/$integer)" {
  write_enterprise_cache 18627 50000
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  [[ "$(line2)" =~ 1d:[^/]*/\$[0-9]+ ]]
}

@test "example C: fresh enterprise → 1d allowance is non-zero (budget remaining)" {
  # allow_1d is derived from per_day in awk; a typo (per_da vs per_day) leaves it
  # as an uninitialized awk variable (= 0), making /$0 appear even with budget left.
  write_enterprise_cache 18627 50000
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  [[ "$(line2)" =~ 1d:[^/]*/\$([0-9]+) ]]
  [[ "${BASH_REMATCH[1]}" -gt 0 ]]
}

@test "example C: fresh enterprise → 15m slot has NO allowance suffix" {
  write_enterprise_cache 18627 50000
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  local l2; l2=$(line2)
  local m15_part="${l2#*15m:}"
  m15_part="${m15_part%%  1h:*}"
  [[ "$m15_part" != *"/\$"* ]]
}

@test "example C: runway cache written with 8 fields" {
  rm -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-runway-allowances.cache"
  write_enterprise_cache 18627 50000
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  [ -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-runway-allowances.cache" ]
  local nf
  nf=$(awk 'NR==1 { print NF }' "$CLAUDE_STATUSLINE_STATE_DIR/statusline-runway-allowances.cache")
  [ "$nf" -eq 8 ]
}

# ── Example E: budget-burned (used_credits ≥ monthly_limit) ──────────────────

@test "example E: burned enterprise → 🪫 glyph" {
  write_enterprise_cache 55000 50000
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  [ "$status" -eq 0 ]
  assert_line2_contains "🪫"
}

@test "example E: burned enterprise → no ≈% and no 🔥 pace" {
  write_enterprise_cache 55000 50000
  CLAUDE_STATUSLINE_SHOW_PACE_RATIO=on CLAUDE_STATUSLINE_COST_LOADAVG=on \
    run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  assert_line2_not_contains "≈"
  assert_line2_not_contains "🔥"
}

@test "example E: burned enterprise → 1h slot ends with /\$0" {
  write_enterprise_cache 55000 50000
  inject_log_entry /tmp 0.45 30 ent1
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  assert_line2_contains '1h:'
  [[ "$(line2)" =~ 1h:[^/]*/\$0[^0-9] ]] || [[ "$(line2)" == *'1h:'*'/$0' ]]
}

@test "example E: burned enterprise → 1d slot ends with /\$0" {
  write_enterprise_cache 55000 50000
  inject_log_entry /tmp 0.45 30 ent1
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  assert_line2_contains '1d:'
  [[ "$(line2)" =~ 1d:[^/]*/\$0[^0-9] ]] || [[ "$(line2)" == *'1d:'*'/$0' ]]
}

@test "example E: burned enterprise → 1h spent value is RED when spend > 0" {
  write_enterprise_cache 55000 50000
  inject_log_entry /tmp 0.45 30 ent1
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  local raw; raw=$(raw_line2)
  [[ "$raw" == *"1h:"*$'\033[31m'* ]]
}

@test "example E: burned enterprise → 1d spent value is RED when spend > 0" {
  write_enterprise_cache 55000 50000
  inject_log_entry /tmp 2.15 120 ent1
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  local raw; raw=$(raw_line2)
  [[ "$raw" == *"1d:"*$'\033[31m'* ]]
}

@test "example E: burned enterprise → 15m slot has no allowance suffix" {
  write_enterprise_cache 55000 50000
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  local l2; l2=$(line2)
  local m15_part="${l2#*15m:}"
  m15_part="${m15_part%%  1h:*}"
  [[ "$m15_part" != *"/\$"* ]]
}

# ── Example F: Enterprise, auth-broken ────────────────────────────────────────

@test "example F: auth-broken enterprise → 🔑 glyph shown" {
  write_enterprise_cache 18627 50000
  write_auth_error_sentinel
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  [ "$status" -eq 0 ]
  assert_line2_contains "🔑"
}

@test "example F: auth-broken enterprise → no 💰 glyph" {
  write_enterprise_cache 18627 50000
  write_auth_error_sentinel
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  assert_line2_not_contains "💰"
}

@test "example F: auth-broken enterprise → no ≈% (percent omitted)" {
  write_enterprise_cache 18627 50000
  write_auth_error_sentinel
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  assert_line2_not_contains "≈"
}

@test "example F: auth-broken enterprise → no 🔥 pace" {
  write_enterprise_cache 18627 50000
  write_auth_error_sentinel
  CLAUDE_STATUSLINE_SHOW_PACE_RATIO=on CLAUDE_STATUSLINE_COST_LOADAVG=on \
    run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  assert_line2_not_contains "🔥"
}

@test "example F: auth-broken enterprise → strikethrough on used amount" {
  write_enterprise_cache 18627 50000
  write_auth_error_sentinel
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  local raw; raw=$(raw_line2)
  [[ "$raw" == *$'\033[9m'* ]]
}

@test "example F: auth-broken enterprise → 1h slot has no allowance suffix" {
  write_enterprise_cache 18627 50000
  write_auth_error_sentinel
  inject_log_entry /tmp 0.45 30 ent1
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  local l2; l2=$(line2)
  local h1_part="${l2#*1h:}"
  h1_part="${h1_part%%  1d:*}"
  [[ "$h1_part" != *"/\$"* ]]
}

@test "example F: auth-broken enterprise → 1d slot has no allowance suffix" {
  write_enterprise_cache 18627 50000
  write_auth_error_sentinel
  inject_log_entry /tmp 2.15 120 ent1
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  local l2; l2=$(line2)
  local d1_part="${l2#*1d:}"
  [[ "$d1_part" != *"/\$"* ]]
}

@test "example F: auth-broken enterprise → /$limit still shown after used" {
  write_enterprise_cache 18627 50000
  write_auth_error_sentinel
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=4.21 session=ent1)"
  assert_line2_contains "/\$500"
}
