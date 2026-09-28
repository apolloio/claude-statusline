#!/usr/bin/env bats

load test_helper

@test "render caches: enterprise and rolling results are cached on a warm render" {
  write_enterprise_cache 10000 100000
  local payload
  payload=$(make_json cwd=/tmp cost=1.00 session=cache-session)

  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$payload"
  [ "$status" -eq 0 ]

  local fields="$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fields.cache"
  local render="$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-render.cache"
  local spend="$CLAUDE_STATUSLINE_STATE_DIR/statusline-spend-metrics.cache"
  [ -s "$fields" ]
  [ -s "$render" ]
  [ -s "$spend" ]
  local fields_before render_before spend_before
  fields_before=$(cksum "$fields")
  render_before=$(cksum "$render")
  spend_before=$(cksum "$spend")

  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$payload"
  [ "$status" -eq 0 ]
  [ "$(cksum "$fields")" = "$fields_before" ]
  [ "$(cksum "$render")" = "$render_before" ]
  [ "$(cksum "$spend")" = "$spend_before" ]
}

@test "render caches: same-size OAuth rewrite invalidates parsed and rendered values" {
  write_enterprise_cache 10000 100000
  local payload
  payload=$(make_json cwd=/tmp cost=1.00 session=cache-session)

  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$payload"
  [ "$status" -eq 0 ]
  assert_line2_contains "≈10%"

  # Both JSON payloads have the same byte length; high-resolution mtime must
  # still invalidate the source identity within the same wall-clock second.
  sleep 0.01
  write_enterprise_cache 20000 100000
  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$payload"
  [ "$status" -eq 0 ]
  assert_line2_contains "≈20%"
  assert_line2_not_contains "≈10%"
}

@test "render caches: rolling metrics invalidate when the usage log changes" {
  local first second cache
  first=$(make_json cwd=/tmp cost=1.00 session=rolling-session)
  second=$(make_json cwd=/tmp cost=2.00 session=rolling-session)
  cache="$CLAUDE_STATUSLINE_STATE_DIR/statusline-spend-metrics.cache"

  CLAUDE_STATUSLINE_COST_LOADAVG=spent_only run_statusline "$first"
  [ "$status" -eq 0 ]
  [ -s "$cache" ]
  local before
  before=$(cksum "$cache")

  CLAUDE_STATUSLINE_COST_LOADAVG=spent_only run_statusline "$second"
  [ "$status" -eq 0 ]
  [ "$(cksum "$cache")" != "$before" ]
  assert_line2_contains "1d:\$1.00"
}

@test "render caches: rolling metrics invalidate when the wall-clock minute bucket advances" {
  local payload cache
  payload=$(make_json cwd=/tmp cost=1.00 session=bucket-session)
  cache="$CLAUDE_STATUSLINE_STATE_DIR/statusline-spend-metrics.cache"

  CLAUDE_STATUSLINE_COST_LOADAVG=spent_only run_statusline "$payload"
  [ "$status" -eq 0 ]
  [ -s "$cache" ]

  # Rewrite the cached key with a minute bucket far in the past, leaving the
  # log/baseline identity, session, cost, and day fields untouched. If the
  # cache only keyed on those (pre-fix behavior), this would still hit.
  local v1 k v3 v4 stale_key
  { IFS= read -r v1; IFS= read -r k; IFS= read -r v3; IFS= read -r v4; } < "$cache"
  stale_key="${k%|*}|0"
  printf '%s\n%s\n%s\n%s\n' "$v1" "$stale_key" "$v3" "$v4" > "$cache"

  CLAUDE_STATUSLINE_COST_LOADAVG=spent_only run_statusline "$payload"
  [ "$status" -eq 0 ]
  local new_key
  new_key=$(sed -n '2p' "$cache")
  [ "$new_key" != "$stale_key" ]
}

@test "render caches: incomplete cache files are rebuilt safely" {
  write_enterprise_cache 10000 100000
  local payload fields render spend
  payload=$(make_json cwd=/tmp cost=1.00 session=cache-session)
  fields="$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fields.cache"
  render="$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-render.cache"
  spend="$CLAUDE_STATUSLINE_STATE_DIR/statusline-spend-metrics.cache"

  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$payload"
  [ "$status" -eq 0 ]
  printf '2\n' > "$fields"
  printf '2\n' > "$render"
  printf '2\n' > "$spend"

  CLAUDE_STATUSLINE_COST_LOADAVG=on run_statusline "$payload"
  [ "$status" -eq 0 ]
  assert_line2_contains "≈10%"
  [ "$(tail -n 1 "$fields")" = complete ]
  [ "$(tail -n 1 "$render")" = complete ]
  [ "$(tail -n 1 "$spend")" = complete ]
}
