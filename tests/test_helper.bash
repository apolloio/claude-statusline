#!/usr/bin/env bash
# Shared setup and helpers for all test files.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/statusline-command.sh"

# ANSI codes for color assertions
ANSI_RESET=$'\033[0m'
ANSI_DIM=$'\033[90m'
ANSI_GREEN=$'\033[32m'
ANSI_YELLOW=$'\033[33m'
ANSI_ORANGE=$'\033[38;5;208m'
ANSI_RED=$'\033[31m'
ANSI_BLUE=$'\033[34m'
ANSI_MAGENTA=$'\033[35m'
ANSI_BOLD=$'\033[1m'
ANSI_STRIKETHROUGH=$'\033[9m'
# 256-color dot palette
ANSI_DOT_GREEN=$'\033[38;5;82m'
ANSI_DOT_YELLOW=$'\033[38;5;220m'
ANSI_DOT_ORANGE=$'\033[38;5;208m'
ANSI_DOT_RED=$'\033[38;5;196m'
ANSI_DOT_GREY=$'\033[38;5;245m'

setup() {
  # Per-test isolated home so all cache files go here and never bleed between tests.
  export HOME="$BATS_TEST_TMPDIR/home"
  export CLAUDE_STATUSLINE_STATE_DIR="$BATS_TEST_TMPDIR/claude-state"
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  # UTF-8 locale required so multi-byte glyphs (●○) aren't split into bytes by grep.
  export LC_ALL=C.UTF-8

  # Unset all optional env vars so tests run against known defaults regardless
  # of what the developer has set in their shell environment.
  unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
  unset CLAUDE_STATUSLINE_CTX_WARN_PCT
  unset CLAUDE_STATUSLINE_CTX_CAUTION_TOKENS
  unset CLAUDE_STATUSLINE_COST_CURRENT
  unset CLAUDE_STATUSLINE_COST_LOADAVG
  unset CLAUDE_STATUSLINE_PERF_BADGE
  unset CLAUDE_STATUSLINE_SHOW_PACE_RATIO
  unset CLAUDE_STATUSLINE_BUDGET_SIGN_MODE
  unset CLAUDE_STATUSLINE_BUDGET_HOURS_PER_DAY
  unset CLAUDE_STATUSLINE_BUDGET_WORK_DAYS
  unset CLAUDE_STATUSLINE_BUDGET_HOLIDAYS
  unset CLAUDE_STATUSLINE_EXTRA_PREVIEW_PCT
  unset CLAUDE_STATUSLINE_CWD_MAXLEN
  unset CLAUDE_STATUSLINE_BRANCH_MAXLEN
  export COLUMNS=200  # deterministic terminal width for budget math (bypasses tput)
  export CLAUDE_STATUSLINE_INSTANCE_ID="test-instance"  # deterministic ∑ⁱ carry-file key

  # Mock bin: security returns no token; curl immediately fails.
  # This prevents the background OAuth fetch from doing anything.
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

  # No tput mock needed: COLUMNS=200 is exported above, so the script reads
  # terminal width from $COLUMNS without invoking tput at all.

  export PATH="$MOCK_BIN:$PATH"

  # Stable non-git directory used by tests that don't need git.
  export NO_GIT_DIR="$BATS_TEST_TMPDIR/noproject"
  mkdir -p "$NO_GIT_DIR"
}

# ── Execution ──────────────────────────────────────────────────────────────────

# Feed JSON to the script and capture output via bats `run`.
run_statusline() {
  run bash "$SCRIPT" <<< "$1"
}

# ── Output accessors ───────────────────────────────────────────────────────────

strip_ansi() {
  perl -pe 's/\e\[[0-9;]*[mGKHF]//g'
}

# Stripped Line 1 / Line 2
line1()     { printf '%s' "${lines[0]}"   | strip_ansi; }
line2()     { printf '%s' "${lines[1]:-}" | strip_ansi; }

# Raw (with ANSI) Line 1 / Line 2
raw_line1() { printf '%s' "${lines[0]}"; }
raw_line2() { printf '%s' "${lines[1]:-}"; }

# ── Fixture builders ───────────────────────────────────────────────────────────

# make_git_repo <dir> [<branch>]
make_git_repo() {
  local dir="$1" branch="${2:-main}"
  mkdir -p "$dir"
  git -C "$dir" init -b "$branch" --quiet 2>/dev/null \
    || { git -C "$dir" init --quiet; git -C "$dir" checkout -b "$branch" --quiet 2>/dev/null || true; }
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  git -C "$dir" commit --allow-empty -m "init" --quiet
}

# make_transcript <path> <role:epoch:input:creation:cache_read> ...
# Writes a minimal JSONL transcript file for performance badge tests.
make_transcript() {
  local path="$1"; shift
  : > "$path"
  for entry; do
    local role epoch input creation cache_read
    IFS=: read -r role epoch input creation cache_read <<< "$entry"
    printf '{"type":"%s","timestamp":%d,"message":{"usage":{"input_tokens":%d,"cache_creation_input_tokens":%d,"cache_read_input_tokens":%d}}}\n' \
      "$role" "$epoch" "${input:-0}" "${creation:-0}" "${cache_read:-0}" >> "$path"
  done
}

# Write a fresh Pro/Max usage cache JSON (5h + 7d utilization %).
write_promax_cache() {
  local fh_util="${1:-50}" sd_util="${2:-30}"
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  printf '{"five_hour":{"utilization":%s},"seven_day":{"utilization":%s},"extra_usage":{"is_enabled":false}}\n' \
    "$fh_util" "$sd_util" > "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-cache.json"
}

# Write a Pro/Max usage cache with extra_usage enabled (amounts in cents).
write_promax_extra_cache() {
  local fh_util="${1:-80}" sd_util="${2:-30}" used_cents="${3:-0}" limit_cents="${4:-5000}"
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  printf '{"five_hour":{"utilization":%s},"seven_day":{"utilization":%s},"extra_usage":{"is_enabled":true,"used_credits":%s,"monthly_limit":%s}}\n' \
    "$fh_util" "$sd_util" "$used_cents" "$limit_cents" > "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-cache.json"
}

# Write a Pro/Max usage cache JSON (amounts in cents, utilization in percent).
# Args: fh_util sd_util used_cents limit_cents [fh_resets_utc]
write_pro_cache() {
  local fh_util="${1:-60}" sd_util="${2:-7}" used_cents="${3:-0}" limit_cents="${4:-100}"
  local fh_resets="${5:-}"
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  local resets_field=""
  [ -n "$fh_resets" ] && resets_field=',"resets_at":"'"$fh_resets"'"'
  printf '{"five_hour":{"utilization":%s%s},"seven_day":{"utilization":%s},"extra_usage":{"is_enabled":true,"used_credits":%s,"monthly_limit":%s}}\n' \
    "$fh_util" "$resets_field" "$sd_util" "$used_cents" "$limit_cents" \
    > "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-cache.json"
}

# Write the auth-error sentinel file (§4.6).
write_auth_error_sentinel() {
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  printf '%d\n' "$(date +%s)" > "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.error"
}

# Write a fresh Enterprise usage cache JSON (amounts in cents).
write_enterprise_cache() {
  local used_cents="${1:-0}" limit_cents="${2:-100000}"
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  printf '{"extra_usage":{"is_enabled":true,"used_credits":%s,"monthly_limit":%s}}\n' \
    "$used_cents" "$limit_cents" > "$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-cache.json"
}

# Inject a log entry into the global usage log at a given age.
# inject_log_entry <cwd> <cost_usd> <minutes_ago> [<session_id>]
inject_log_entry() {
  local cwd="${1:-/tmp}" cost="${2:-0}" minutes_ago="${3:-0}" sess="${4:-anon}"
  local epoch=$(( $(date +%s) - minutes_ago * 60 ))
  local ws_hash
  ws_hash=$(printf '%s' "$cwd" | (command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum) 2>/dev/null | awk '{print $1}')
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  printf '%d %s %s %s\n' "$epoch" "$sess" "$cost" "${ws_hash}" >> "$CLAUDE_STATUSLINE_STATE_DIR/statusline-global-usage-log.cache"
}

# Convenience: minimal valid JSON with sensible defaults.
# All fields are injected only when the arg is non-empty (except cost which defaults to 0).
make_json() {
  # named-style: call with: make_json cwd=... model=... used=... ...
  local cwd="/tmp" model="Sonnet 4.6" used="12" window="200000"
  local cost="0.00" session="test-session-42" transcript="" fast="" effort="" thinking=""

  for arg; do
    case "$arg" in
      cwd=*)        cwd="${arg#cwd=}" ;;
      model=*)      model="${arg#model=}" ;;
      used=*)       used="${arg#used=}" ;;
      window=*)     window="${arg#window=}" ;;
      cost=*)       cost="${arg#cost=}" ;;
      session=*)    session="${arg#session=}" ;;
      transcript=*) transcript="${arg#transcript=}" ;;
      fast=*)       fast="${arg#fast=}" ;;
      effort=*)     effort="${arg#effort=}" ;;
      thinking=*)   thinking="${arg#thinking=}" ;;
    esac
  done

  local json
  json=$(printf '{"session_id":"%s","model":{"display_name":"%s"},"context_window":{"used_percentage":%s,"context_window_size":%s},"cost":{"total_cost_usd":%s},"workspace":{"current_dir":"%s"}' \
    "$session" "$model" "$used" "$window" "$cost" "$cwd")
  [ -n "$transcript" ] && json+=",\"transcript_path\":\"$transcript\""
  [ -n "$fast"       ] && json+=",\"fast_mode\":$fast"
  [ -n "$effort"     ] && json+=",\"effort\":{\"level\":\"$effort\"}"
  [ -n "$thinking"   ] && json+=",\"thinking\":{\"enabled\":$thinking}"
  json+="}"
  printf '%s' "$json"
}

# ── Assertion helpers ──────────────────────────────────────────────────────────

# Fail with a helpful message when a string is not a substring of $output.
assert_output_contains() {
  local needle="$1"
  if [[ "$output" != *"$needle"* ]]; then
    echo "Expected output to contain: $(printf '%s' "$needle" | cat -v)"
    echo "Actual output (cat -v):     $(printf '%s' "$output"  | cat -v)"
    return 1
  fi
}

assert_output_not_contains() {
  local needle="$1"
  if [[ "$output" == *"$needle"* ]]; then
    echo "Expected output NOT to contain: $(printf '%s' "$needle" | cat -v)"
    return 1
  fi
}

# Same checks scoped to Line 1 / Line 2.
assert_line1_contains() {
  local stripped; stripped=$(line1)
  if [[ "$stripped" != *"$1"* ]]; then
    echo "Expected Line 1 to contain: $1"
    echo "Line 1 stripped: $stripped"
    return 1
  fi
}

assert_line1_not_contains() {
  local stripped; stripped=$(line1)
  if [[ "$stripped" == *"$1"* ]]; then
    echo "Expected Line 1 NOT to contain: $1"
    echo "Line 1 stripped: $stripped"
    return 1
  fi
}

assert_line2_contains() {
  local stripped; stripped=$(line2)
  if [[ "$stripped" != *"$1"* ]]; then
    echo "Expected Line 2 to contain: $1"
    echo "Line 2 stripped: $stripped"
    return 1
  fi
}

assert_line2_not_contains() {
  local stripped; stripped=$(line2)
  if [[ "$stripped" == *"$1"* ]]; then
    echo "Expected Line 2 NOT to contain: $1"
    echo "Line 2 stripped: $stripped"
    return 1
  fi
}

# Check raw (ANSI-bearing) Line 1 / Line 2 for a literal byte sequence.
assert_raw_line1_contains() {
  local raw; raw=$(raw_line1)
  if [[ "$raw" != *"$1"* ]]; then
    echo "Expected raw Line 1 to contain the given escape sequence"
    echo "Raw Line 1 (cat -v): $(raw_line1 | cat -v)"
    return 1
  fi
}

assert_raw_line1_not_contains() {
  local raw; raw=$(raw_line1)
  if [[ "$raw" == *"$1"* ]]; then
    echo "Expected raw Line 1 NOT to contain the given escape sequence"
    echo "Raw Line 1 (cat -v): $(raw_line1 | cat -v)"
    return 1
  fi
}

assert_raw_line2_contains() {
  local raw; raw=$(raw_line2)
  if [[ "$raw" != *"$1"* ]]; then
    echo "Expected raw Line 2 to contain the given escape sequence"
    echo "Raw Line 2 (cat -v): $(raw_line2 | cat -v)"
    return 1
  fi
}

assert_raw_line2_not_contains() {
  local raw; raw=$(raw_line2)
  if [[ "$raw" == *"$1"* ]]; then
    echo "Expected raw Line 2 NOT to contain the given escape sequence"
    echo "Raw Line 2 (cat -v): $(raw_line2 | cat -v)"
    return 1
  fi
}

# ── State helpers for todo_behaviors tests ────────────────────────────────────

# Write a session baseline TSV row so tests can seed ∑ˢ state.
# write_session_baseline <session_id> <baseline_cost_usd>
write_session_baseline() {
  local sess="$1" baseline="$2"
  local epoch; epoch=$(date +%s)
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  printf '%s\t%s\t%d\t%d\n' "$sess" "$baseline" "$epoch" "$epoch" \
    >> "$CLAUDE_STATUSLINE_STATE_DIR/statusline-session-baselines.tsv"
}

# Touch the usage cache file to appear 1000 s old without blocking lock creation.
# Use this when you want the script to detect staleness but still be able to
# create the fetch lock file (and thus suppress ⚠️ on the first render).
make_cache_file_stale() {
  local file="$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-cache.json"
  [ -f "$file" ] || return 1
  local old_ts
  old_ts=$(date -v-1000S +%Y%m%d%H%M.%S 2>/dev/null) \
    || old_ts=$(date -d "@$(($(date +%s) - 1000))" +%Y%m%d%H%M.%S 2>/dev/null)
  [ -n "$old_ts" ] && touch -t "$old_ts" "$file" 2>/dev/null
}

# Touch the usage cache file to appear 1000 s old (3× TTL = stale).
# Also create a lock file aged 200 s to simulate a fetch that completed without
# refreshing the cache (lock_age in INFLIGHT_GRACE..LEAK_TIMEOUT → ⚠️ shown).
make_usage_cache_stale() {
  local file="$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-cache.json"
  [ -f "$file" ] || return 1
  local old_ts
  old_ts=$(date -v-1000S +%Y%m%d%H%M.%S 2>/dev/null) \
    || old_ts=$(date -d "@$(($(date +%s) - 1000))" +%Y%m%d%H%M.%S 2>/dev/null)
  [ -n "$old_ts" ] && touch -t "$old_ts" "$file" 2>/dev/null
  local lock="$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.lock"
  printf 'stale\n' > "$lock"
  local lock_ts
  lock_ts=$(date -v-200S +%Y%m%d%H%M.%S 2>/dev/null) \
    || lock_ts=$(date -d "@$(($(date +%s) - 200))" +%Y%m%d%H%M.%S 2>/dev/null)
  [ -n "$lock_ts" ] && touch -t "$lock_ts" "$lock" 2>/dev/null
}

# Age the usage cache to 400 s (past TTL+30 but below 3×TTL stale threshold).
# No lock file — simulates the window where ↻ shows without ⚠️.
make_cache_overdue() {
  local file="$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-cache.json"
  [ -f "$file" ] || return 1
  local ts
  ts=$(date -v-400S +%Y%m%d%H%M.%S 2>/dev/null) \
    || ts=$(date -d "@$(($(date +%s) - 400))" +%Y%m%d%H%M.%S 2>/dev/null)
  [ -n "$ts" ] && touch -t "$ts" "$file" 2>/dev/null
}

# Create a USAGE_FETCH_LOCK with a bogus (non-running) PID dated 40 s ago,
# so _usage_fetch_slow=1 without triggering the inflight guard.
write_stale_fetch_lock() {
  local lock="$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.lock"
  mkdir -p "$CLAUDE_STATUSLINE_STATE_DIR"
  printf '2147483647\n' > "$lock"   # max-int PID — never running
  local old_ts
  old_ts=$(date -v-40S +%Y%m%d%H%M.%S 2>/dev/null) \
    || old_ts=$(date -d "@$(($(date +%s) - 40))" +%Y%m%d%H%M.%S 2>/dev/null)
  [ -n "$old_ts" ] && touch -t "$old_ts" "$lock" 2>/dev/null
}

# Create a stale cache (1000 s old) AND a lock file aged <seconds> ago.
# Useful for testing specific lock-age windows without spawning real fetches.
# write_stale_cache_with_lock_age <seconds>
write_stale_cache_with_lock_age() {
  local lock_seconds="${1:-300}"
  local cache_file="$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-cache.json"
  local lock_file="$CLAUDE_STATUSLINE_STATE_DIR/statusline-usage-fetch.lock"

  [ -f "$cache_file" ] || return 1

  # Age the cache file to 1000 s old (3× TTL = stale)
  local cache_ts
  cache_ts=$(date -v-1000S +%Y%m%d%H%M.%S 2>/dev/null) \
    || cache_ts=$(date -d "@$(($(date +%s) - 1000))" +%Y%m%d%H%M.%S 2>/dev/null)
  [ -n "$cache_ts" ] && touch -t "$cache_ts" "$cache_file" 2>/dev/null

  # Create lock file aged <lock_seconds> ago
  printf 'stale\n' > "$lock_file"
  local lock_ts
  lock_ts=$(date -v-${lock_seconds}S +%Y%m%d%H%M.%S 2>/dev/null) \
    || lock_ts=$(date -d "@$(($(date +%s) - lock_seconds))" +%Y%m%d%H%M.%S 2>/dev/null)
  [ -n "$lock_ts" ] && touch -t "$lock_ts" "$lock_file" 2>/dev/null
}
