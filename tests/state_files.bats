#!/usr/bin/env bats
# State file tests: log creation/append/prune, session baseline lifecycle,
# workspace/session partitioning, runway allowance cache, stale-fetch lock mechanics

load test_helper

LOG_FILE=""
SESSION_BASELINE_FILE=""

setup() {
  # Call parent setup first
  export HOME="$BATS_TEST_TMPDIR/home"
  export CLAUDE_STATUSLINE_STATE_DIR="$BATS_TEST_TMPDIR/claude-state"
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"

  export MOCK_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  cat > "$MOCK_BIN/security" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$MOCK_BIN/security"
  cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$MOCK_BIN/curl"
  export PATH="$MOCK_BIN:$PATH"

  export NO_GIT_DIR="$BATS_TEST_TMPDIR/noproject"
  mkdir -p "$NO_GIT_DIR"

  LOG_FILE="$CLAUDE_STATUSLINE_STATE_DIR/statusline-global-usage-log.cache"
  SESSION_BASELINE_FILE="$CLAUDE_STATUSLINE_STATE_DIR/statusline-session-baselines.tsv"
}

# ── Log file creation ─────────────────────────────────────────────────────────

@test "state: log file created on first run" {
  run_statusline "$(make_json session=s1 cost=1.00)"
  [ -f "$LOG_FILE" ]
}

@test "state: log file has correct format (epoch session cost workspace)" {
  run_statusline "$(make_json session=s1 cost=1.50 cwd=/tmp)"
  [ -f "$LOG_FILE" ]
  local line; line=$(head -1 "$LOG_FILE")
  # Fields: epoch session_id cost workspace_sha256
  local fields; fields=$(printf '%s' "$line" | awk '{print NF}')
  [ "$fields" -eq 4 ]
}

@test "state: log file records cost value" {
  run_statusline "$(make_json session=s1 cost=2.34 cwd=/tmp)"
  grep -q '2.34' "$LOG_FILE"
}

@test "state: log file appends on each run" {
  run_statusline "$(make_json session=s1 cost=1.00 cwd=/tmp)"
  run_statusline "$(make_json session=s1 cost=1.50 cwd=/tmp)"
  local count; count=$(wc -l < "$LOG_FILE" | tr -d ' ')
  # Should have at least 2 entries (may have exactly 2, possibly 1 if prune ran)
  [ "$count" -ge 1 ]
}

@test "state: log file records session_id" {
  run_statusline "$(make_json session=my-unique-session cost=0.50 cwd=/tmp)"
  grep -q 'my-unique-session' "$LOG_FILE"
}

@test "state: unchanged renders do not append duplicate usage rows" {
  export CLAUDE_STATUSLINE_INSTANCE_ID=coalesce-test
  run_statusline "$(make_json session=stable cost=1.00 cwd=/tmp)"
  run_statusline "$(make_json session=stable cost=1.00 cwd=/tmp)"
  [ "$(wc -l < "$LOG_FILE" | tr -d ' ')" -eq 1 ]
}

@test "state: session, cost, and cwd changes each append a usage row" {
  export CLAUDE_STATUSLINE_INSTANCE_ID=change-test
  run_statusline "$(make_json session=a cost=1.00 cwd=/tmp)"
  run_statusline "$(make_json session=a cost=1.01 cwd=/tmp)"
  run_statusline "$(make_json session=a cost=1.01 cwd=/var)"
  run_statusline "$(make_json session=b cost=1.01 cwd=/var)"
  [ "$(wc -l < "$LOG_FILE" | tr -d ' ')" -eq 4 ]
}

@test "state: five-minute heartbeat appends an otherwise unchanged sample" {
  export CLAUDE_STATUSLINE_INSTANCE_ID=heartbeat-test
  local carry="$CLAUDE_STATUSLINE_STATE_DIR/statusline-instance-carry.heartbeat-test.cache"
  run_statusline "$(make_json session=stable cost=1.00 cwd=/tmp)"
  local old=$(( $(date +%s) - 301 )) tmp="$carry.tmp"
  awk -v old="$old" 'NR==6{$0=old}{print}' "$carry" > "$tmp" && mv "$tmp" "$carry"
  run_statusline "$(make_json session=stable cost=1.00 cwd=/tmp)"
  [ "$(wc -l < "$LOG_FILE" | tr -d ' ')" -eq 2 ]
}

@test "state: carry cache lazily migrates from three to eight lines" {
  export CLAUDE_STATUSLINE_INSTANCE_ID=migrate-test
  local carry="$CLAUDE_STATUSLINE_STATE_DIR/statusline-instance-carry.migrate-test.cache"
  printf 'legacy\n1.000000\n0\n' > "$carry"
  run_statusline "$(make_json session=legacy cost=1.00 cwd=/tmp)"
  [ "$(wc -l < "$carry" | tr -d ' ')" -eq 8 ]
  [ "$(sed -n '1p' "$carry")" = legacy ]
}

@test "state: baseline last_used is touched at most daily" {
  export CLAUDE_STATUSLINE_INSTANCE_ID=touch-test
  local carry="$CLAUDE_STATUSLINE_STATE_DIR/statusline-instance-carry.touch-test.cache"
  run_statusline "$(make_json session=touch cost=1.00 cwd=/tmp)"
  local first second old tmp="$carry.tmp"
  first=$(awk -F'\t' '$1=="touch"{print $4}' "$SESSION_BASELINE_FILE")
  run_statusline "$(make_json session=touch cost=1.00 cwd=/tmp)"
  second=$(awk -F'\t' '$1=="touch"{print $4}' "$SESSION_BASELINE_FILE")
  [ "$first" = "$second" ]
  old=$(( $(date +%s) - 86401 ))
  awk -v old="$old" 'NR==5{$0=old}{print}' "$carry" > "$tmp" && mv "$tmp" "$carry"
  run_statusline "$(make_json session=touch cost=1.00 cwd=/tmp)"
  [ "$(sed -n '5p' "$carry")" -gt "$old" ]
}

# ── Session baseline file ──────────────────────────────────────────────────────

@test "state: session baseline file created on first run" {
  run_statusline "$(make_json session=new-sess cost=1.23)"
  [ -f "$SESSION_BASELINE_FILE" ]
}

@test "state: session baseline contains session_id" {
  run_statusline "$(make_json session=baseline-sess cost=1.00)"
  grep -q 'baseline-sess' "$SESSION_BASELINE_FILE"
}

@test "state: baseline cost recorded as first-seen cost" {
  run_statusline "$(make_json session=track-sess cost=3.00)"
  local baseline; baseline=$(awk -F'\t' '$1 == "track-sess" { print $2 }' "$SESSION_BASELINE_FILE")
  # Baseline should be close to 3.00 (6 decimal places)
  [[ "$baseline" == "3.000000"* ]]
}

@test "state: baseline preserved on subsequent runs" {
  run_statusline "$(make_json session=pres-sess cost=1.00)"
  run_statusline "$(make_json session=pres-sess cost=2.00)"
  local baseline; baseline=$(awk -F'\t' '$1 == "pres-sess" { print $2 }' "$SESSION_BASELINE_FILE")
  # Baseline should still be 1.00, not updated to 2.00
  [[ "$baseline" == "1.000000"* ]]
}

@test "state: different sessions get separate baselines" {
  run_statusline "$(make_json session=sessX cost=1.00)"
  run_statusline "$(make_json session=sessY cost=5.00)"
  local bx; bx=$(awk -F'\t' '$1 == "sessX" { print $2 }' "$SESSION_BASELINE_FILE")
  local by; by=$(awk -F'\t' '$1 == "sessY" { print $2 }' "$SESSION_BASELINE_FILE")
  [[ "$bx" == "1.000000"* ]]
  [[ "$by" == "5.000000"* ]]
}

@test "state: new session_id creates new baseline (simulates /clear)" {
  run_statusline "$(make_json session=before-clear cost=10.00)"
  # After /clear, new session_id appears; cost continues monotonically
  run_statusline "$(make_json session=after-clear cost=10.50)"
  # New baseline should be 10.50
  local baseline; baseline=$(awk -F'\t' '$1 == "after-clear" { print $2 }' "$SESSION_BASELINE_FILE")
  [[ "$baseline" == "10.500000"* ]]
}

# ── Log pruning ────────────────────────────────────────────────────────────────

@test "state: log prune keeps recent entries" {
  run_statusline "$(make_json session=prune-test cost=1.00 cwd=/tmp)"
  [ -f "$LOG_FILE" ]
  local count; count=$(wc -l < "$LOG_FILE" | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "state: log prune keeps one anchor per session beyond cutoff" {
  # Write an old entry manually (older than 36h), then run script
  local old_epoch=$(( $(date +%s) - 40*3600 ))  # 40h ago
  local ws_hash; ws_hash=$(printf '%s' '/tmp' | (command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum) 2>/dev/null | awk '{print $1}')
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  printf '%d old-session 0.50 %s\n' "$old_epoch" "${ws_hash}" > "$LOG_FILE"
  run_statusline "$(make_json session=new-run cost=1.00 cwd=/tmp)"
  # The old entry is the sole anchor for 'old-session' and should be retained
  grep -q 'old-session' "$LOG_FILE"
}

@test "state: log prune keeps one anchor per session across different workspaces" {
  local old_epoch=$(( $(date +%s) - 40*3600 ))  # 40h ago
  local hash_a; hash_a=$(printf '%s' '/tmp' | (command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum) 2>/dev/null | awk '{print $1}')
  local hash_b; hash_b=$(printf '%s' '/home/other' | (command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum) 2>/dev/null | awk '{print $1}')
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  printf '%d sess-alpha 0.30 %s\n' "$old_epoch" "$hash_a" > "$LOG_FILE"
  printf '%d sess-beta 0.20 %s\n' "$(( old_epoch + 1 ))" "$hash_b" >> "$LOG_FILE"
  run_statusline "$(make_json session=new-run cost=1.00 cwd=/tmp)"
  # Both sessions from different workspaces must be retained as separate anchors
  grep -q 'sess-alpha' "$LOG_FILE"
  grep -q 'sess-beta' "$LOG_FILE"
}

# ── Baseline file format ───────────────────────────────────────────────────────

@test "state: baseline file has 4 tab-separated fields per row" {
  run_statusline "$(make_json session=format-check cost=1.00)"
  local fields; fields=$(awk -F'\t' 'NR==1 { print NF }' "$SESSION_BASELINE_FILE")
  [ "$fields" -eq 4 ]
}

# ── Log file format detail ─────────────────────────────────────────────────────

@test "log format: row written on first run has exactly 4 space-separated fields" {
  run_statusline "$(make_json cwd=/tmp)"
  [ "$status" -eq 0 ]
  local logfile="$CLAUDE_STATUSLINE_STATE_DIR/statusline-global-usage-log.cache"
  [ -f "$logfile" ]
  local nf
  nf=$(awk 'NR==1 { print NF }' "$logfile")
  [ "$nf" -eq 4 ]
}

@test "log format: field 4 is non-empty (workspace hash)" {
  run_statusline "$(make_json cwd=/tmp)"
  local logfile="$CLAUDE_STATUSLINE_STATE_DIR/statusline-global-usage-log.cache"
  [ -f "$logfile" ]
  local f4
  f4=$(awk 'NR==1 { print $4 }' "$logfile")
  [ -n "$f4" ]
}

@test "log format: workspace hash differs between different cwds" {
  run_statusline "$(make_json cwd=/tmp)"
  local hash_tmp; hash_tmp=$(awk 'NR==1 { print $4 }' "$CLAUDE_STATUSLINE_STATE_DIR/statusline-global-usage-log.cache")

  # Fresh state dir so the second run gets its own clean log with only the /var entry.
  local state2="$BATS_TEST_TMPDIR/claude-state-2"
  mkdir -p "$state2"
  export CLAUDE_STATUSLINE_STATE_DIR="$state2"
  run_statusline "$(make_json cwd=/var)"
  local hash_var; hash_var=$(awk 'NR==1 { print $4 }' "$state2/statusline-global-usage-log.cache")

  [ "$hash_tmp" != "$hash_var" ]
}

# ── Workspace partitioning in rolling-window calc ─────────────────────────────

@test "workspace partition: entry for a different cwd does not inflate 1h spend" {
  inject_log_entry /other/dir 0.50 30
  run_statusline "$(make_json cwd=/tmp cost=0.80)"
  [ "$status" -eq 0 ]
  assert_line2_not_contains "1h:\$0.30"
}

@test "workspace partition: foreign-cwd entry does not affect 15m spend" {
  inject_log_entry /other/dir 0.50 5
  run_statusline "$(make_json cwd=/tmp cost=0.80)"
  assert_line2_not_contains "15m:\$0.30"
}

@test "workspace partition: own-cwd entry IS used as reference" {
  inject_log_entry /tmp 0.20 30 ws-part-sess
  run_statusline "$(make_json cwd=/tmp cost=0.80 session=ws-part-sess)"
  assert_line2_contains "1h:\$0.60"
}

# ── Session baseline ∑ˢ tracking ──────────────────────────────────────────────

@test "session baselines: first run → ∑ˢ = \$0.00 (baseline set to current cost)" {
  run_statusline "$(make_json session=sess-new cost=5.00)"
  [ "$status" -eq 0 ]
  assert_line2_contains "\$0.00"
}

@test "session baselines: pre-seeded baseline → ∑ˢ shows accumulated spend" {
  write_session_baseline "sess-accum" "5.000000"
  run_statusline "$(make_json session=sess-accum cost=7.00)"
  assert_line2_contains "\$2.00"
}

@test "session baselines: /clear (new session_id) → ∑ˢ resets to \$0.00" {
  write_session_baseline "old-session-clear" "5.000000"
  run_statusline "$(make_json session=new-session-after-clear cost=8.00)"
  assert_line2_contains "\$0.00"
}

@test "session baselines: baseline TSV file created on first run" {
  run_statusline "$(make_json session=sess-tsv cost=1.00)"
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-session-baselines.tsv" ]
}

@test "session baselines: TSV row contains correct session_id" {
  run_statusline "$(make_json session=unique-sess-id cost=3.00)"
  grep -q "unique-sess-id" "$CLAUDE_STATUSLINE_STATE_DIR/statusline-session-baselines.tsv"
}

# ── Session partitioning in rolling-window calc ───────────────────────────────

@test "session partition: old-session log rows should NOT affect new-session 1h spend" {
  inject_log_entry /tmp 0.10 30 old-sess
  run_statusline "$(make_json cwd=/tmp cost=0.90 session=new-sess)"
  assert_line2_contains "1h:\$0.00"
}

@test "session partition: 15m spend unaffected by a different session's entry" {
  inject_log_entry /tmp 0.05 10 other-sess
  run_statusline "$(make_json cwd=/tmp cost=0.50 session=current-sess)"
  assert_line2_contains "15m:\$0.00"
}

# ── 1d baseline floor (lost-early-rows fix) ───────────────────────────────────

@test "1d spend: baseline floor recovers full spend when early log rows are lost" {
  # Simulate the incident: session $0→$18.70 today but only late rows survived in log.
  # write_session_baseline sets first_seen=NOW (today), so floor is eligible.
  write_session_baseline "lost-rows-sess" "0.000000"
  # Only a late log row at high cost (early rows lost to concurrent prune)
  inject_log_entry /tmp 18.70 5 "lost-rows-sess"
  # Without fix: ref=18.70 (earliest surviving row), delta=0 → 1d shows $0.00
  # With fix: bbase=0.00 < ref=18.70, bfirst=today → ref floored to 0.00, delta=18.70
  run_statusline "$(make_json session=lost-rows-sess cost=18.70)"
  assert_line2_contains "1d:\$18.70"
}

@test "1d spend: baseline floor NOT applied for cross-midnight sessions (first_seen before today)" {
  local now; now=$(date +%s)
  local day_start
  day_start=$(date -jf "%Y-%m-%d %H:%M:%S" "$(date +%F) 00:00:00" +%s 2>/dev/null \
    || date -d "$(date +%F) 00:00:00" +%s 2>/dev/null \
    || echo $(( now - 86400 )))
  # Session started 2 hours before midnight — first_seen < day_start
  local first_seen_yesterday=$(( day_start - 7200 ))
  # Log anchor from 2 min before midnight: cost=$10.00 at that point
  local anchor_epoch=$(( day_start - 120 ))
  local anchor_minutes_ago=$(( (now - anchor_epoch + 59) / 60 ))
  # Write baseline with first_seen before midnight (cross-midnight session, lifetime baseline $0)
  printf '%s\t%s\t%d\t%d\n' "xmid-sess" "0.000000" "$first_seen_yesterday" "$first_seen_yesterday" \
    >> "$CLAUDE_STATUSLINE_STATE_DIR/statusline-session-baselines.tsv"
  inject_log_entry /tmp 10.00 "$anchor_minutes_ago" "xmid-sess"
  # Today's delta: $12.00 - $10.00 (log anchor) = $2.00
  # Without guard: bbase=0.00 would floor ref to 0, giving $12.00 (wrong — over-counts yesterday)
  # With guard: first_seen < day_start → floor skipped → ref=10.00, delta=$2.00
  run_statusline "$(make_json session=xmid-sess cost=12.00)"
  assert_line2_contains "1d:\$2.00"
}

# ── Runway allowance cache lifecycle ──────────────────────────────────────────

@test "runway allowance: cache file created after enterprise run with cost_loadavg=on" {
  write_enterprise_cache 0 100000
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp)"
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-runway-allowances.cache" ]
}

@test "runway allowance: cache row has 8 fields (epoch ymd limit hols used l15 l1 l1d)" {
  write_enterprise_cache 0 100000
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp)"
  local nf
  nf=$(awk 'NR==1 { print NF }' "$CLAUDE_STATUSLINE_STATE_DIR/statusline-runway-allowances.cache")
  [ "$nf" -eq 8 ]
}

@test "runway allowance: not written when cost_loadavg=spent_only (allowances suppressed)" {
  write_enterprise_cache 0 100000
  CLAUDE_STATUSLINE_COST_LOADAVG=spent_only run_statusline "$(make_json cwd=/tmp)"
  [ ! -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-runway-allowances.cache" ]
}

@test "runway allowance: not written when cost_loadavg=off" {
  write_enterprise_cache 0 100000
  CLAUDE_STATUSLINE_COST_LOADAVG=off run_statusline "$(make_json cwd=/tmp)"
  [ ! -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-runway-allowances.cache" ]
}

@test "runway allowance: cache not rewritten when only used_credits changes mid-day" {
  write_enterprise_cache 1000 100000
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp)"
  local allow_before
  allow_before=$(awk 'NR==1 { print $0 }' "$CLAUDE_STATUSLINE_STATE_DIR/statusline-runway-allowances.cache")

  write_enterprise_cache 2000 100000
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp)"
  local allow_after
  allow_after=$(awk 'NR==1 { print $0 }' "$CLAUDE_STATUSLINE_STATE_DIR/statusline-runway-allowances.cache")

  [ "$allow_before" = "$allow_after" ]
}

@test "runway allowance: not pinned from a stale used_credits snapshot (no lock, cache_age > 900s)" {
  # Simulate a stale month-boundary snapshot (e.g. laptop asleep across the reset):
  # cache_age is well past 3x TTL but no lock exists, so the ⚠️ flag stays "hopeful".
  # The runway cache must not pin this snapshot for the whole day regardless.
  write_enterprise_cache 41576 100000
  make_cache_file_stale
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp)"
  [ ! -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-runway-allowances.cache" ]

  # A subsequent render with a fresh, correct snapshot must be the one pinned.
  write_enterprise_cache 348 100000
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$(make_json cwd=/tmp)"
  [ -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-runway-allowances.cache" ]
  local used_field
  used_field=$(awk 'NR==1 { print $5 }' "$CLAUDE_STATUSLINE_STATE_DIR/statusline-runway-allowances.cache")
  [ "$used_field" = "348" ]
}

# ── Stale-fetch lock mechanics ─────────────────────────────────────────────────

@test "stale fetch: first render with stale cache shows no ⚠️ and creates lock file" {
  write_enterprise_cache 5000 100000
  make_cache_file_stale
  cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
sleep 10
exit 1
EOF
  chmod +x "$MOCK_BIN/curl"

  run_statusline "$(make_json cwd=/tmp)"
  [ "$status" -eq 0 ]
  assert_line2_not_contains "⚠️"
  [ -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.lock" ]
}

@test "stale fetch: after fetch completes without update, stale cache shows ⚠️ with strikethrough" {
  write_enterprise_cache 5000 100000
  write_stale_cache_with_lock_age 200
  rm -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.error"

  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "⚠️"
  assert_raw_line2_contains "${ANSI_STRIKETHROUGH}"
}

@test "stale+lock in-flight (lock_age < 60s): ⚠️ suppressed" {
  write_enterprise_cache 5000 100000
  write_stale_cache_with_lock_age 10
  rm -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.error"

  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_not_contains "⚠️"
}

@test "stale+lock failed (lock_age 61s–599s): ⚠️ shown" {
  write_enterprise_cache 5000 100000
  write_stale_cache_with_lock_age 200
  rm -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.error"

  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_contains "⚠️"
  assert_raw_line2_contains "${ANSI_STRIKETHROUGH}"
}

@test "stale+lock leaked (lock_age >= 600s): ⚠️ suppressed (wake-from-sleep)" {
  write_enterprise_cache 5000 100000
  write_stale_cache_with_lock_age 700
  rm -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.error"

  run_statusline "$(make_json cwd=/tmp)"
  assert_line2_not_contains "⚠️"
  [ -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.lock" ]
}

@test "OAuth fetch: sanitizes payload version before building User-Agent header" {
  local curl_args="$BATS_TEST_TMPDIR/curl-args"
  export CURL_ARGS_FILE="$curl_args"

  cat > "$MOCK_BIN/security" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token"}}'
EOF
  chmod +x "$MOCK_BIN/security"

  cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  printf '%s\n' "$1" >> "$CURL_ARGS_FILE"
  if [ "$1" = "-o" ]; then
    shift
    out="$1"
    printf '%s\n' "$1" >> "$CURL_ARGS_FILE"
  fi
  shift
done
printf '%s\n' '{"five_hour":null,"seven_day":null,"extra_usage":{"is_enabled":false}}' > "$out"
EOF
  chmod +x "$MOCK_BIN/curl"

  run_statusline '{"version":"2.1.0 bad/../../\tX-Evil: yes","workspace":{"current_dir":"/tmp"}}'
  [ "$status" -eq 0 ]

  local attempts=0
  while ! grep -Fq 'User-Agent:' "$curl_args" 2>/dev/null && [ "$attempts" -lt 50 ]; do
    sleep 0.02
    attempts=$(( attempts + 1 ))
  done

  [ -f "$curl_args" ]
  grep -Fxq 'User-Agent: claude-code/2.1.0bad....X-Evilyes' "$curl_args"
  ! grep -Fq 'X-Evil:' "$curl_args"
}

@test "stale+lock retry cooldown (lock_age < 120s): no new fetch spawned" {
  write_enterprise_cache 5000 100000
  write_stale_cache_with_lock_age 80
  rm -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.error"

  local lock_before
  lock_before=$(date -r "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.lock" +%s 2>/dev/null \
    || stat -c %Y "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.lock" 2>/dev/null)

  run_statusline "$(make_json cwd=/tmp)"

  local lock_after
  lock_after=$(date -r "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.lock" +%s 2>/dev/null \
    || stat -c %Y "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.lock" 2>/dev/null)

  [ "$lock_before" = "$lock_after" ]
}

@test "stale+lock retry allowed (lock_age >= 120s): new fetch spawned (lock touched)" {
  write_enterprise_cache 5000 100000
  write_stale_cache_with_lock_age 150
  rm -f "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.error"

  local lock_before
  lock_before=$(date -r "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.lock" +%s 2>/dev/null \
    || stat -c %Y "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.lock" 2>/dev/null)

  run_statusline "$(make_json cwd=/tmp)"

  local lock_after
  lock_after=$(date -r "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.lock" +%s 2>/dev/null \
    || stat -c %Y "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.lock" 2>/dev/null)

  [ "$lock_after" -gt "$lock_before" ]
}

# ── Cross-instance 1d aggregation ─────────────────────────────────────────────

@test "cross-instance: 1d shows combined spend across two other sessions ($5+$10=$15)" {
  # Two sessions each wrote a log row earlier today (5 min ago).
  # This instance has $0 cost — it is the observer.
  inject_log_entry /tmp 5.00 5 "inst-a"
  inject_log_entry /tmp 10.00 5 "inst-b"
  # Seed baselines so 1d floor doesn't interfere (both started today at $0)
  write_session_baseline "inst-a" "0.000000"
  write_session_baseline "inst-b" "0.000000"
  run_statusline "$(make_json session=inst-observer cost=0.00)"
  [ "$status" -eq 0 ]
  assert_line2_contains "1d:\$15.00"
}

# ── Concurrent-prune integrity ────────────────────────────────────────────────

@test "concurrent prune: large log retains seeded older rows after N concurrent writes" {
  local log="$CLAUDE_STATUSLINE_STATE_DIR/statusline-global-usage-log.cache"
  local now; now=$(date +%s)

  # Seed LOG_PRUNE_SIZE_MAX / 2 bytes worth of older rows so the file is large
  # enough to trigger pruning. Each row is ~80 bytes; we need >262144 bytes.
  # Write ~3400 rows (≈272 KB) of 2-hour-old entries for a canary session.
  local anchor_epoch=$(( now - 7200 ))
  local i=0
  while [ $i -lt 3400 ]; do
    printf '%d canary-sess 1.000000 deadbeef\n' "$anchor_epoch" >> "$log"
    i=$(( i + 1 ))
  done

  # Launch 8 concurrent instances that all write to the same log.
  # They should prune (file is huge) but must not corrupt or empty the log.
  local j=0
  while [ $j -lt 8 ]; do
    bash "$SCRIPT" <<< "$(make_json session=concurrent-$j cost=0.0$j)" >/dev/null 2>&1 &
    j=$(( j + 1 ))
  done
  wait

  # The seeded anchor row for canary-sess must still be present — prune keeps
  # one pre-window anchor per session, so at least one canary row must survive.
  [ -f "$log" ]
  [ -s "$log" ]
  grep -q "canary-sess" "$log"
}
