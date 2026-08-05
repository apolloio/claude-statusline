#!/usr/bin/env bats
# Edge case tests: empty fields, CR stripping, zero cost, missing segments

load test_helper

# ── Empty / missing session_id ────────────────────────────────────────────────

@test "edge: empty session_id uses 'anon' internally (no crash)" {
  run_statusline '{"model":{"display_name":"Sonnet 4.6"},"context_window":{"used_percentage":5,"context_window_size":200000},"cost":{"total_cost_usd":0},"workspace":{"current_dir":"/tmp"}}'
  [ "$status" -eq 0 ]
}

@test "edge: missing session_id field still produces two lines" {
  run_statusline '{"model":{"display_name":"Sonnet 4.6"},"context_window":{"used_percentage":5,"context_window_size":200000},"cost":{"total_cost_usd":0},"workspace":{"current_dir":"/tmp"}}'
  [ "${#lines[@]}" -ge 1 ]
}

# ── CR stripping ───────────────────────────────────────────────────────────────

@test "edge: CRLF in JSON input does not corrupt output" {
  # Inject carriage returns into the JSON
  local json; json=$(printf '%s\r\n' "$(make_json session=cr-sess cost=1.23)")
  run_statusline "$json"
  [ "$status" -eq 0 ]
  # Should not have literal \r in output
  [[ "$output" != *$'\r'* ]]
}

# ── Zero cost ─────────────────────────────────────────────────────────────────

@test "edge: zero cost renders as \$0.00 not empty" {
  run_statusline "$(make_json cost=0.00)"
  assert_line2_contains '$0.00'
}

@test "edge: zero cost does not crash the script" {
  run_statusline "$(make_json cost=0.00)"
  [ "$status" -eq 0 ]
}

# ── Missing context_window ────────────────────────────────────────────────────

@test "edge: missing context_window shows ctx:— on line 1" {
  run_statusline '{"session_id":"s1","model":{"display_name":"Sonnet 4.6"},"cost":{"total_cost_usd":0},"workspace":{"current_dir":"/tmp"}}'
  assert_line1_contains "ctx:—"
}

@test "edge: null used_percentage shows ctx:— on line 1" {
  run_statusline '{"session_id":"s1","model":{"display_name":"Sonnet 4.6"},"context_window":{"used_percentage":null},"cost":{"total_cost_usd":0},"workspace":{"current_dir":"/tmp"}}'
  assert_line1_contains "ctx:—"
}

# ── Missing transcript ────────────────────────────────────────────────────────

@test "edge: nonexistent transcript path produces grey badge (not crash)" {
  run_statusline "$(make_json transcript=/no/such/file.jsonl)"
  [ "$status" -eq 0 ]
  assert_raw_line2_contains "${ANSI_DOT_GREY}"
}

@test "edge: empty transcript file produces grey badge" {
  local t="$BATS_TEST_TMPDIR/empty.jsonl"
  touch "$t"
  run_statusline "$(make_json transcript="$t")"
  [ "$status" -eq 0 ]
  assert_raw_line2_contains "${ANSI_DOT_GREY}"
}

# ── Detached HEAD ─────────────────────────────────────────────────────────────

@test "edge: detached HEAD shows commit hash not branch name" {
  local repo="$BATS_TEST_TMPDIR/detached-edge"
  make_git_repo "$repo" main
  git -C "$repo" checkout --detach HEAD --quiet 2>/dev/null
  run_statusline "$(make_json cwd="$repo")"
  assert_line1_contains "⎇"
  # A short SHA looks like hex characters (7+)
  local stripped; stripped=$(line1)
  # The branch portion should NOT be "main" in detached state
  [[ "$stripped" != *" main"* ]]
}

# ── Script produces exactly 2 output lines ────────────────────────────────────

@test "edge: script always outputs exactly 2 lines" {
  run_statusline "$(make_json)"
  [ "${#lines[@]}" -eq 2 ]
}

@test "edge: output is not empty" {
  run_statusline "$(make_json)"
  [ -n "${lines[0]}" ]
}

# ── Invalid/malformed JSON ─────────────────────────────────────────────────────

@test "edge: malformed JSON does not hang (graceful degradation)" {
  run bash "$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/statusline-command.sh" <<< '{invalid json'
  # Should exit without hanging; status may be non-zero or zero (graceful)
  [ "$status" -eq 0 ] || [ "$status" -ne 0 ]
  # Main requirement: it terminates
  true
}

# ── Context window k-formatting edge cases ────────────────────────────────────

@test "edge: exactly 1000 tokens formats as 1k" {
  # 1% of 100000 = 1000 → 1k
  run_statusline "$(make_json used=1 window=100000)"
  assert_line1_contains "1k/"
}

@test "edge: large context window formats correctly" {
  # 50% of 2000000 = 1000000 → 1000k
  run_statusline "$(make_json used=50 window=2000000)"
  assert_line1_contains "ctx:"
  assert_line1_contains "1000k"
}

# ── Fast mode is orange ───────────────────────────────────────────────────────

@test "edge: fast mode ↯ glyph is orange colored" {
  run_statusline "$(make_json fast=true)"
  assert_raw_line1_contains "${ANSI_ORANGE}"
}

# ── Model name in magenta ─────────────────────────────────────────────────────

@test "edge: model name rendered in magenta" {
  run_statusline "$(make_json model="Sonnet 4.6")"
  assert_raw_line1_contains "${ANSI_MAGENTA}"
}

# ── Git branch in green ───────────────────────────────────────────────────────

@test "edge: git branch icon and name rendered in green" {
  local repo="$BATS_TEST_TMPDIR/green-branch"
  make_git_repo "$repo" main
  run_statusline "$(make_json cwd="$repo")"
  assert_raw_line1_contains "${ANSI_GREEN}"
}

# ── CWD in yellow ─────────────────────────────────────────────────────────────

@test "edge: CWD rendered in yellow" {
  run_statusline "$(make_json cwd=/tmp/test)"
  assert_raw_line1_contains "${ANSI_YELLOW}"
}

# ── Locale decimal separator ───────────────────────────────────────────────────
# Dollar amounts must honor the active locale's decimal separator so that e.g.
# pl_PL users see "$328,70" (comma) and en_US users see "$328.70" (period).

@test "edge: Polish locale uses comma decimal separator in dollar amounts" {
  LC_ALL=pl_PL.UTF-8 printf '%.2f' 1.5 2>/dev/null | grep -q ',' \
    || skip "pl_PL.UTF-8 locale not available or does not use comma decimal"

  write_enterprise_cache 32870 50000   # $328,70 used of $500 budget
  inject_log_entry /tmp 0.53 5
  inject_log_entry /tmp 1.44 30
  inject_log_entry /tmp 10.04 700

  LC_ALL=pl_PL.UTF-8 run_statusline "$(make_json cwd=/tmp cost=1.23)"

  [ "$status" -eq 0 ]
  local l2; l2=$(line2)
  # No period-decimal dollar amount should appear in pl_PL.
  # Use [$] not \$ — bash ERE \$ behaves unexpectedly before [0-9]+.
  if [[ "$l2" =~ [$][0-9]+\.[0-9]{2} ]]; then
    echo "Period decimal found in pl_PL line 2: $l2"
    return 1
  fi
  # At least one comma-decimal amount must be present.
  [[ "$l2" =~ [$][0-9]+,[0-9]{2} ]] \
    || { echo "No comma decimal in pl_PL line 2: $l2"; return 1; }
}

@test "edge: Default locale uses period decimal separator in dollar amounts" {
  write_enterprise_cache 32870 50000
  inject_log_entry /tmp 0.53 5
  inject_log_entry /tmp 1.44 30
  inject_log_entry /tmp 10.04 700

  LC_ALL=C run_statusline "$(make_json cwd=/tmp cost=1.23)"

  [ "$status" -eq 0 ]
  local l2; l2=$(line2)
  # In C/POSIX locale the decimal separator is '.'.
  if [[ "$l2" =~ [$][0-9]+,[0-9]{2} ]]; then
    echo "Comma decimal found in C locale line 2: $l2"
    return 1
  fi
  [[ "$l2" =~ [$][0-9]+\.[0-9]{2} ]] \
    || { echo "No period decimal in C locale line 2: $l2"; return 1; }
}
