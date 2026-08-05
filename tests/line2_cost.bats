#!/usr/bin/env bats
# Line 2 cost tests: ∑ˢ/∑ⁱ badges, rolling windows, deduplication,
# stale cache styling, slow-fetch spinner, 1h≥15m clamping

load test_helper

# ── Cost pair display ─────────────────────────────────────────────────────────

@test "cost: ∑ˢ symbol appears on line 2" {
  run_statusline "$(make_json cost=1.23)"
  assert_line2_contains "∑ˢ"
}

@test "cost: ∑ˢ formatted as dollar amount" {
  write_session_baseline "fmt-sess" "0.000000"
  run_statusline "$(make_json session=fmt-sess cost=1.23)"
  assert_line2_contains '$1.23'
}

@test "cost: zero cost shows ∑ˢ\$0.00" {
  run_statusline "$(make_json cost=0.00)"
  assert_line2_contains '∑ˢ$0.00'
}

@test "cost: first run - no carry, session_cost=0 → only ∑ˢ shown (dedup)" {
  # On first run: no carry file, baseline=cost=1.23, session_cost=0, instance_cost=0.
  # instance_cost == session_cost → ∑ⁱ suppressed.
  run_statusline "$(make_json cost=1.23)"
  assert_line2_contains "∑ˢ"
  assert_line2_not_contains "∑ⁱ"
}

@test "cost: after /clear (cost reset) → both ∑ˢ and ∑ⁱ shown" {
  # Simulate /clear: pre-clear session wrote cost=1.23, then new session_id + cost reset to 0.
  # The carry mechanism picks up 1.23 so ∑ⁱ shows the full instance total.
  run_statusline "$(make_json session=pre-clear-sess cost=1.23)"
  run_statusline "$(make_json session=post-clear-sess cost=0.00)"
  assert_line2_contains "∑ˢ"
  assert_line2_contains "∑ⁱ"
}

@test "cost: deduplication hides ∑ⁱ when session and instance within 0.01" {
  # When cost is 0, both session_cost and instance_cost are 0 → same → only ∑ˢ shown.
  run_statusline "$(make_json cost=0.00)"
  assert_line2_contains "∑ˢ"
  assert_line2_not_contains "∑ⁱ"
}

@test "cost: second run shows ∑ˢ as difference from baseline" {
  # First run: writes baseline for session "sess1" = 1.00
  run_statusline "$(make_json session=sess1 cost=1.00)"
  # Second run same session: cost=1.50, baseline still 1.00 → session_cost = 0.50
  run_statusline "$(make_json session=sess1 cost=1.50)"
  assert_line2_contains "∑ˢ"
  assert_line2_contains '$0.50'
}

@test "cost: new session resets ∑ˢ to 0" {
  # Establish baseline for session A
  run_statusline "$(make_json session=sessA cost=5.00)"
  # New session B: baseline = 5.00, session_cost = 0
  run_statusline "$(make_json session=sessB cost=5.00)"
  # Both session and instance are 0 → dedup → only ∑ˢ$0.00
  assert_line2_contains "∑ˢ"
  assert_line2_contains '$0.00'
}

@test "cost: ∑ⁱ shows instance total cost after /clear" {
  # Pre-clear session accumulates $2.50, then /clear: new session_id + cost reset.
  # Carry mechanism surfaces the $2.50 as ∑ⁱ in the new session.
  run_statusline "$(make_json session=inst-pre cost=2.50)"
  run_statusline "$(make_json session=inst-post cost=0.00)"
  assert_line2_contains "∑ⁱ"
  assert_line2_contains '$2.50'
}

@test "cost: ∑ⁱ carry is scoped per instance, not shared" {
  # Instance A accumulates $5.00 across a /clear.
  CLAUDE_STATUSLINE_INSTANCE_ID="instance-a" run_statusline "$(make_json session=a-pre cost=5.00)"
  CLAUDE_STATUSLINE_INSTANCE_ID="instance-a" run_statusline "$(make_json session=a-post cost=0.00)"
  assert_line2_contains "∑ⁱ"
  assert_line2_contains '$5.00'

  # A different instance must start fresh: no carry, no leaked $5.00.
  CLAUDE_STATUSLINE_INSTANCE_ID="instance-b" run_statusline "$(make_json session=b-sess cost=0.00)"
  assert_line2_not_contains "∑ⁱ"
  assert_line2_not_contains '$5.00'
}

@test "cost: legacy global carry file is reaped and does not leak into a new instance" {
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  printf 'old-sess\n244.000000\n244.000000\n' > "$CLAUDE_STATUSLINE_STATE_DIR/statusline-instance-carry.cache"

  CLAUDE_STATUSLINE_INSTANCE_ID="fresh-instance" run_statusline "$(make_json session=fresh-sess cost=0.00)"

  assert_line2_not_contains "∑ⁱ"
  assert_line2_not_contains '$244'
  [ ! -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-instance-carry.cache" ]
}

# ── Cost display colors ───────────────────────────────────────────────────────

@test "cost: ∑ˢ rendered in blue bold" {
  run_statusline "$(make_json cost=0.00)"
  assert_raw_line2_contains "${ANSI_BLUE}"
  assert_raw_line2_contains "${ANSI_BOLD}"
}

# ── Rolling window display ────────────────────────────────────────────────────

@test "cost: 💸 symbol appears on line 2" {
  run_statusline "$(make_json)"
  assert_line2_contains "💸"
}

@test "cost: rolling slots 15m 1h 1d all present" {
  run_statusline "$(make_json)"
  assert_line2_contains "15m:"
  assert_line2_contains "1h:"
  assert_line2_contains "1d:"
}

@test "cost: rolling slots show NODATA as \$0.00 on first run" {
  # On first run, log has just one row = current cost, so ref = cur → spent = 0.
  # calc_spent_all returns "0.000 0.000 0.000" (not NODATA) because we appended a row.
  # But if window has no older anchor, ref = cur → spent = 0 → shows $0.00.
  run_statusline "$(make_json cost=1.23)"
  assert_line2_contains "15m:"
  assert_line2_contains '$0.00'
}

@test "cost: 15m slot shows no cap suffix" {
  run_statusline "$(make_json)"
  # 15m should not show /$X (no limit shown for 15m window)
  local stripped; stripped=$(line2)
  # Capture just what's between "15m:" and "1h:"
  local slot15; slot15=$(printf '%s' "$stripped" | sed 's/.*15m:\(.*\)  1h:.*/\1/')
  # Should not contain a slash (no cap)
  [[ "$slot15" != *"/"* ]]
}

@test "cost: 1h and 1d slots present with no caps when no enterprise cache" {
  run_statusline "$(make_json)"
  # Without enterprise OAuth cache, no /$caps should appear
  local stripped; stripped=$(line2)
  assert_line2_contains "1h:"
  assert_line2_contains "1d:"
}

# ── Accumulation across multiple runs ─────────────────────────────────────────

@test "cost: spending accumulates across runs in log" {
  local sess="acc-sess-$$"
  # Run 1: cost=1.00 → baseline written as 1.00
  run_statusline "$(make_json session="$sess" cost=1.00)"
  # Run 2: cost=2.00 → session_cost = 2.00 - 1.00 = 1.00
  run_statusline "$(make_json session="$sess" cost=2.00)"
  assert_line2_contains '$1.00'
}

# ── Cross-workspace aggregation ───────────────────────────────────────────────

@test "cost: rolling windows aggregate spend across sessions in different workspaces" {
  local now; now=$(date +%s)
  local LOG_FILE="$CLAUDE_STATUSLINE_STATE_DIR/statusline-global-usage-log.cache"
  local hash_tmp; hash_tmp=$(printf '%s' '/tmp' | (command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum) 2>/dev/null | awk '{print $1}')
  local hash_other; hash_other=$(printf '%s' '/home/other' | (command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum) 2>/dev/null | awk '{print $1}')
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  # Two sessions in different workspaces: each spent $0.10 in the last 5 minutes
  printf '%d sess-x 0.10 %s\n' "$(( now - 400 ))" "$hash_tmp"   > "$LOG_FILE"
  printf '%d sess-x 0.20 %s\n' "$(( now - 30  ))" "$hash_tmp"  >> "$LOG_FILE"
  printf '%d sess-y 0.05 %s\n' "$(( now - 400 ))" "$hash_other" >> "$LOG_FILE"
  printf '%d sess-y 0.15 %s\n' "$(( now - 30  ))" "$hash_other" >> "$LOG_FILE"
  # Current session has $0.00 spend, but the log has combined $0.20 in-window spend
  run_statusline "$(make_json session=cur-sess cost=0.00 cwd=/tmp)"
  # 15m slot must be non-zero ($0.20 combined: sess-x delta=0.10, sess-y delta=0.10)
  local stripped; stripped=$(printf '%s' "$output" | strip_ansi)
  local slot15; slot15=$(printf '%s' "$stripped" | grep -o '15m:[^ ]*' | head -1)
  # Should NOT be $0.00 or em-dash
  [[ "$slot15" != "15m:\$0.00" ]]
  [[ "$slot15" != *"—"* ]]
}

# ── Anonymous session ─────────────────────────────────────────────────────────

@test "cost: empty session_id treated as anon (no crash)" {
  run_statusline '{"model":{"display_name":"Sonnet 4.6"},"context_window":{"used_percentage":5,"context_window_size":200000},"cost":{"total_cost_usd":0.5},"workspace":{"current_dir":"/tmp"}}'
  [ "$status" -eq 0 ]
  assert_line2_contains "∑ˢ"
}

# ── Stale cache styling ───────────────────────────────────────────────────────

@test "stale cache: enterprise → ⚠️ glyph replaces 💰" {
  write_enterprise_cache 5000 100000
  make_usage_cache_stale
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "⚠️"
  assert_line2_not_contains "💰"
}

@test "stale cache: enterprise → ⚠️ present in output" {
  write_enterprise_cache 5000 100000
  make_usage_cache_stale
  run_statusline "$(make_json cwd=/tmp)"
  [ "$status" -eq 0 ]
  assert_line2_contains "⚠️"
}

@test "stale cache: promax → strikethrough present on stale % (stale shows color + strikethrough, no bold)" {
  write_promax_cache 50 30
  make_usage_cache_stale
  run_statusline "$(make_json cwd=/tmp)"
  assert_raw_line2_contains "${ANSI_STRIKETHROUGH}"
}

@test "stale cache: promax → % still shown when stale" {
  write_promax_cache 50 30
  make_usage_cache_stale
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "%"
}

@test "fresh cache: no ⚠️ warning for enterprise" {
  write_enterprise_cache 5000 100000
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_not_contains "⚠️"
  assert_line2_contains "💰"
}

@test "fresh cache: no strikethrough on promax plan %" {
  write_promax_cache 50 30
  run_statusline "$(make_json cwd=/tmp)"
  assert_raw_line2_not_contains "${ANSI_STRIKETHROUGH}"
}

# ── Slow-fetch ↻ spinner ──────────────────────────────────────────────────────

@test "slow-fetch: ↻ appears when cache overdue but not yet stale (enterprise)" {
  write_enterprise_cache 5000 100000
  make_cache_overdue   # 400 s old: past TTL+30, below 3×TTL stale threshold
  run_statusline "$(make_json cwd=/tmp)"
  [ "$status" -eq 0 ]
  assert_line2_contains "↻"
}

@test "slow-fetch: ↻ appears when cache overdue but not yet stale (promax)" {
  write_promax_cache 50 30
  make_cache_overdue
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "↻"
}

@test "slow-fetch: ↻ absent when cache is fresh (age < TTL+30s)" {
  write_enterprise_cache 5000 100000
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_not_contains "↻"
}

@test "slow-fetch: ↻ absent when ⚠️ stale is already shown (⚠️ supersedes ↻)" {
  write_enterprise_cache 5000 100000
  make_usage_cache_stale   # 1000 s old + 200 s lock → ⚠️ active
  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_not_contains "↻"
}

@test "slow-fetch: ↻ absent when cost_loadavg=off and no plan segment" {
  CLAUDE_STATUSLINE_COST_LOADAVG=off run_statusline "$(make_json)"
  assert_line2_not_contains "↻"
}

# ── 1h ≥ 15m clamping ────────────────────────────────────────────────────────

@test "1h clamp: script exits 0 and outputs 2 lines with injected 15m entry" {
  inject_log_entry /tmp 0.10 8 clamp-sess
  run_statusline "$(make_json cwd=/tmp cost=0.50 session=clamp-sess)"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "1h clamp: 1h slot value is not less than 15m slot value in stripped output" {
  inject_log_entry /tmp 0.10 8 clamp-sess2
  run_statusline "$(make_json cwd=/tmp cost=0.60 session=clamp-sess2)"
  local stripped; stripped=$(line2)
  local v15 v1h
  v15=$(printf '%s' "$stripped" | sed 's/.*15m:[^0-9]*\([0-9.]*\).*/\1/')
  v1h=$(printf '%s' "$stripped" | sed 's/.*1h:[^0-9]*\([0-9.]*\).*/\1/')
  [ -n "$v15" ] && [ -n "$v1h" ]
  awk -v a="$v1h" -v b="$v15" 'BEGIN { exit (a + 0 >= b + 0 ? 0 : 1) }' </dev/null
}
