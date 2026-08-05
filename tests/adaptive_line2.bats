#!/usr/bin/env bats
# Adaptive line 2 truncation: suppress 💸 rolling-spend segment when terminal is too narrow

load test_helper

@test "adaptive line2: spend segment visible when terminal is wide" {
  # Default COLUMNS=200 from test_helper setup — plenty of room
  inject_log_entry "/tmp" 0.10 5 "sess-wide"
  run_statusline "$(make_json cost=0.10 session=sess-wide)"
  assert_line2_contains "💸"
}

@test "adaptive line2: spend segment suppressed when terminal is narrow" {
  # COLUMNS=40 leaves substantially less room than the complete line needs.
  export COLUMNS=40
  inject_log_entry "/tmp" 0.10 5 "sess-narrow"
  run_statusline "$(make_json cost=0.10 session=sess-narrow)"
  assert_line2_not_contains "💸"
}

@test "adaptive line2: spend visible just above threshold (no budget segment)" {
  # With the first-run ∑ⁱ badge deduplicated, the plain line2 fits at COLUMNS=52.
  export COLUMNS=52
  inject_log_entry "/tmp" 0.10 5 "sess-threshold"
  run_statusline "$(make_json cost=0.10 session=sess-threshold)"
  assert_line2_contains "💸"
}

@test "adaptive line2: spend suppressed just below threshold (no budget segment)" {
  export COLUMNS=51
  inject_log_entry "/tmp" 0.10 5 "sess-below"
  run_statusline "$(make_json cost=0.10 session=sess-below)"
  assert_line2_not_contains "💸"
}

@test "adaptive line2: enterprise emoji widen line2, suppressing spend at moderate width" {
  # Enterprise line2 includes 💰 and 🔥 (each 2 cols). At COLUMNS=75 the plain line2
  # fits with spend, but the enterprise line2 (wider due to emoji) does not.
  export COLUMNS=75
  write_enterprise_cache 36470 50000
  inject_log_entry "/tmp" 0.10 5 "sess-ent"
  run_statusline "$(make_json cost=0.10 session=sess-ent)"
  assert_line2_not_contains "💸"
}

@test "adaptive line2: without enterprise segment spend fits at same moderate width" {
  # Same COLUMNS=75 but no budget cache → no 💰/🔥 emoji on line2 → spend fits.
  export COLUMNS=75
  inject_log_entry "/tmp" 0.10 5 "sess-plain"
  run_statusline "$(make_json cost=0.10 session=sess-plain)"
  assert_line2_contains "💸"
}
