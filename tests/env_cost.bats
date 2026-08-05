#!/usr/bin/env bats
# Env var tests: CLAUDE_STATUSLINE_COST_CURRENT and CLAUDE_STATUSLINE_COST_LOADAVG

load test_helper

# ── COST_CURRENT=off ──────────────────────────────────────────────────────────

@test "cost_current=off: ∑ˢ symbol absent from line 2" {
  CLAUDE_STATUSLINE_COST_CURRENT=off run_statusline "$(make_json cost=1.23)"
  assert_line2_not_contains "∑ˢ"
}

@test "cost_current=off: ∑ⁱ symbol absent from line 2" {
  CLAUDE_STATUSLINE_COST_CURRENT=off run_statusline "$(make_json cost=1.23)"
  assert_line2_not_contains "∑ⁱ"
}

@test "cost_current=off: rolling 💸 windows still shown (independent)" {
  CLAUDE_STATUSLINE_COST_CURRENT=off run_statusline "$(make_json)"
  assert_line2_contains "💸"
}

@test "cost_current=off: script exits 0 and produces 2 lines" {
  CLAUDE_STATUSLINE_COST_CURRENT=off run_statusline "$(make_json cost=5.00)"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "cost_current=OFF: uppercase treated same as off" {
  CLAUDE_STATUSLINE_COST_CURRENT=OFF run_statusline "$(make_json cost=1.23)"
  assert_line2_not_contains "∑ˢ"
  assert_line2_not_contains "∑ⁱ"
}

# ── COST_CURRENT=on (default) ────────────────────────────────────────────────

@test "cost_current=on: ∑ˢ always shown" {
  CLAUDE_STATUSLINE_COST_CURRENT=on run_statusline "$(make_json cost=0.00)"
  assert_line2_contains "∑ˢ"
}

@test "cost_current=on: dedup hides ∑ⁱ when session and instance are same" {
  # Zero cost: session=0, instance=0 → same within $0.01 → only ∑ˢ shown
  CLAUDE_STATUSLINE_COST_CURRENT=on run_statusline "$(make_json cost=0.00)"
  assert_line2_contains "∑ˢ"
  assert_line2_not_contains "∑ⁱ"
}

@test "cost_current=on: shows both ∑ˢ and ∑ⁱ after /clear (carry)" {
  # Simulate /clear: pre-clear session had cost=5.00, then new session_id + cost resets.
  # Carry mechanism detects the session change and carries 5.00 into ∑ⁱ.
  run_statusline "$(make_json session=on-pre-clear cost=5.00)"
  CLAUDE_STATUSLINE_COST_CURRENT=on run_statusline "$(make_json session=on-post-clear cost=0.00)"
  assert_line2_contains "∑ˢ"
  assert_line2_contains "∑ⁱ"
}

# ── COST_CURRENT=session ─────────────────────────────────────────────────────

@test "cost_current=session: ∑ˢ shown" {
  CLAUDE_STATUSLINE_COST_CURRENT=session run_statusline "$(make_json cost=2.00)"
  assert_line2_contains "∑ˢ"
}

@test "cost_current=session: ∑ⁱ never shown (session is single-badge mode)" {
  # SPEC §8.6: session mode shows only ∑ˢ regardless of equality check — ∑ⁱ is never shown.
  CLAUDE_STATUSLINE_COST_CURRENT=session run_statusline "$(make_json cost=0.00)"
  assert_line2_contains "∑ˢ"
  assert_line2_not_contains "∑ⁱ"
}

@test "cost_current=SESSION: uppercase treated same as session" {
  CLAUDE_STATUSLINE_COST_CURRENT=SESSION run_statusline "$(make_json cost=2.00)"
  assert_line2_contains "∑ˢ"
}

# ── COST_CURRENT=instance ────────────────────────────────────────────────────

@test "cost_current=instance: ∑ˢ never shown (instance is single-badge mode)" {
  # SPEC §8.6: instance mode shows only ∑ⁱ regardless of equality check — ∑ˢ is never shown.
  CLAUDE_STATUSLINE_COST_CURRENT=instance run_statusline "$(make_json cost=2.00)"
  assert_line2_not_contains "∑ˢ"
}

@test "cost_current=instance: ∑ⁱ shown (no dedup in instance mode)" {
  CLAUDE_STATUSLINE_COST_CURRENT=instance run_statusline "$(make_json cost=3.00)"
  assert_line2_contains "∑ⁱ"
}

@test "cost_current=INSTANCE: uppercase treated same as instance (∑ⁱ shown, ∑ˢ not)" {
  CLAUDE_STATUSLINE_COST_CURRENT=INSTANCE run_statusline "$(make_json cost=2.00)"
  assert_line2_contains "∑ⁱ"
  assert_line2_not_contains "∑ˢ"
}

# ── COST_LOADAVG=off ─────────────────────────────────────────────────────────

@test "cost_loadavg=off: 💸 symbol absent from line 2" {
  CLAUDE_STATUSLINE_COST_LOADAVG=off run_statusline "$(make_json)"
  assert_line2_not_contains "💸"
}

@test "cost_loadavg=off: 15m/1h/1d slots absent" {
  CLAUDE_STATUSLINE_COST_LOADAVG=off run_statusline "$(make_json)"
  assert_line2_not_contains "15m:"
  assert_line2_not_contains "1h:"
  assert_line2_not_contains "1d:"
}

@test "cost_loadavg=off: ∑ˢ/∑ⁱ cost pair still shown (independent)" {
  CLAUDE_STATUSLINE_COST_LOADAVG=off run_statusline "$(make_json cost=0.00)"
  assert_line2_contains "∑ˢ"
}

@test "cost_loadavg=off: script exits 0 and produces 2 lines" {
  CLAUDE_STATUSLINE_COST_LOADAVG=off run_statusline "$(make_json)"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "cost_loadavg=OFF: uppercase treated same as off" {
  CLAUDE_STATUSLINE_COST_LOADAVG=OFF run_statusline "$(make_json)"
  assert_line2_not_contains "💸"
}

# ── COST_LOADAVG=on (default) ─────────────────────────────────────────────────

@test "cost_loadavg=on: 💸 symbol present" {
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json)"
  assert_line2_contains "💸"
}

@test "cost_loadavg=on: all three window slots present" {
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json)"
  assert_line2_contains "15m:"
  assert_line2_contains "1h:"
  assert_line2_contains "1d:"
}

@test "cost_loadavg=on: 1h slot shows cap suffix with enterprise cache" {
  write_enterprise_cache 0 100000
  # With cost_loadavg=on + enterprise cache → caps are computed → 1h shows /$X
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp)"
  local stripped; stripped=$(line2)
  # The 1h slot should have a cap suffix (/$X format)
  [[ "$stripped" == *"1h:"*"/"* ]]
}

@test "cost_loadavg=on: 1h slot shows cap suffix even when there are no log entries (nodata)" {
  # Regression: _roll_slot nodata early-return used to skip the allowance suffix.
  # With enterprise cache + loadavg=on but no prior log entries: nodata=1 for 1h,
  # yet the cap suffix must still appear (shows — as the spent value, /N as the cap).
  write_enterprise_cache 0 100000
  # No inject_log_entry — ensures nodata path is taken.
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp)"
  local stripped; stripped=$(line2)
  [[ "$stripped" == *"1h:"*"/"* ]]
}

@test "cost_loadavg=on: 1h slot value contains a dollar sign, not a backslash-dollar" {
  # Regression: printf '\$%.2f' in single-quoted context emits a literal backslash,
  # producing '1h:\$0.60' instead of '1h:$0.60'.
  inject_log_entry /tmp 0.20 30
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp cost=0.80 session=dollar-sign-regression)"
  local stripped; stripped=$(line2)
  # Must contain '$' somewhere after '1h:' — and must NOT contain '\$'.
  [[ "$stripped" == *"1h:"*'$'* ]]
  [[ "$stripped" != *'1h:\$'* ]]
}

# ── COST_LOADAVG=spent_only ──────────────────────────────────────────────────

@test "cost_loadavg=spent_only: 💸 symbol present" {
  CLAUDE_STATUSLINE_COST_LOADAVG=spent_only run_statusline "$(make_json)"
  assert_line2_contains "💸"
}

@test "cost_loadavg=spent_only: all three window slots present" {
  CLAUDE_STATUSLINE_COST_LOADAVG=spent_only run_statusline "$(make_json)"
  assert_line2_contains "15m:"
  assert_line2_contains "1h:"
  assert_line2_contains "1d:"
}

@test "cost_loadavg=spent_only: 1h slot has no cap suffix even with enterprise cache" {
  write_enterprise_cache 0 100000
  CLAUDE_STATUSLINE_COST_LOADAVG=spent_only run_statusline "$(make_json cwd=/tmp)"
  local stripped; stripped=$(line2)
  # Extract the 1h section: between "1h:" and "1d:"
  local slot1h; slot1h=$(printf '%s' "$stripped" | sed 's/.*1h:\(.*\)  1d:.*/\1/')
  # spent_only suppresses caps → no slash in this slot
  [[ "$slot1h" != *"/"* ]]
}

@test "cost_loadavg=spent_only: 1d slot has no cap suffix even with enterprise cache" {
  write_enterprise_cache 0 100000
  CLAUDE_STATUSLINE_COST_LOADAVG=spent_only run_statusline "$(make_json cwd=/tmp)"
  local stripped; stripped=$(line2)
  # Extract 1d section (last slot — take after "1d:" to end)
  local slot1d; slot1d=$(printf '%s' "$stripped" | sed 's/.*1d:\(.*\)/\1/')
  [[ "$slot1d" != *"/"* ]]
}

@test "cost_loadavg=SPENT_ONLY: uppercase treated same as spent_only" {
  CLAUDE_STATUSLINE_COST_LOADAVG=SPENT_ONLY run_statusline "$(make_json)"
  assert_line2_contains "💸"
  assert_line2_contains "15m:"
}
