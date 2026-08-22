# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single `statusline-command.sh` bash script consumed by Claude Code as a custom statusline command. It reads a JSON payload on stdin and prints exactly two lines of ANSI-colored text to stdout.

## Running and testing

```bash
# Run with sample input
cat input.json | bash statusline-command.sh

# Run with a specific env var
CLAUDE_STATUSLINE_COST_LOADAVG=off cat input.json | bash statusline-command.sh

# Simulate what Claude Code sends
echo '{"session_id":"s1","model":{"display_name":"Sonnet 4.6"},"context_window":{"used_percentage":80,"context_window_size":200000},"cost":{"total_cost_usd":0.42},"workspace":{"current_dir":"/tmp"}}' | bash statusline-command.sh
```

Tests live in `tests/` and run with `bats tests/`.

## Spec

**`SPEC.md` is the authoritative reference** for all behavior: input schema, output format, ANSI constants, every env var, all cache files, edge cases, and the assembly order of line 2. Read it before modifying anything non-trivial.

## Architecture

Everything lives in `statusline-command.sh`. Key sections in order:

1. **Input parsing** — `jq` extracts ~12 fields from stdin JSON; all have fallbacks
2. **Persistent state** (all under `$_CLAUDE_DIR`, which resolves from `CLAUDE_STATUSLINE_STATE_DIR` env var, defaulting to `~/.claude/`):
   - `statusline-global-usage-log.cache` — append-only cost time series; powers 💸 rolling windows
   - `statusline-session-baselines.tsv` — per-session cost baseline for ∑ˢ (resets on `/clear`); also consumed by the 💸 1d rolling-window math as a floor on the daily reference (lost-row recovery, §4.2/§8.7)
   - `statusline-instance-carry.<instance_key>.cache` — 3-line file (session_id, last_cost, carry); accumulates pre-/clear costs so ∑ⁱ shows the true instance total even after Claude Code resets `cost.total_cost_usd` at `/clear`. Keyed per owning `claude` process (`_instance_key()` walks the ppid chain, same idiom as the ancestor-PTY walk) so a freshly opened instance never inherits another instance's carry; a dead instance's file is reaped after 1 day, and the legacy single global file is removed on first sight.
   - `statusline-usage-cache.json` — OAuth API response (Pro/Max plan %, Enterprise budget); TTL 300s, refreshed in background
   - `statusline-runway-allowances.cache` — Enterprise per-window budget allowances; invalidated at local midnight
3. **Line 1** — yellow CWD (shortened to fit terminal; see `CLAUDE_STATUSLINE_CWD_MAXLEN`, default 64), green git branch (shortened, `CLAUDE_STATUSLINE_BRANCH_MAXLEN` default 64; branch gets priority in budget; resolved before CWD so its actual length drives the CWD budget) with optional opt-in git status markers (`CLAUDE_STATUSLINE_GIT_STATUS`, off by default — `*`/`?` for dirty/untracked, `↑N`/`↓N` for ahead/behind upstream; adds one extra `git status` + `awk` fork only when enabled), optional 🧠, magenta model name, effort/fast-mode glyphs, colored context %. Ultracode is not a payload field — Claude Code normalizes `/effort ultracode` to `xhigh`, so it's inferred from `ultra_effort_enter`/`ultra_effort_exit` transcript attachments (last wins) and only when `effort.level == "xhigh"`; it renders as a rainbow `ultracode` word instead of `◉` (`CLAUDE_STATUSLINE_ULTRACODE=off` to disable)
4. **Line 2** — perf dots (4-dot cache/latency badge from transcript JSONL), optional Pro/Max or Enterprise budget segments, ∑ˢ/∑ⁱ cost badges, 💸 rolling 15m/1h/1d spend windows
5. **Concurrency** — `mkdir`-based lock for log writes; mtime-sentinel file for single-flight OAuth refresh (lock is NOT removed on fetch exit; its mtime = last attempt time; three thresholds drive stale decisions: `LOCK_INFLIGHT_GRACE=60s`, `FETCH_RETRY_COOLDOWN=120s`, `LOCK_LEAK_TIMEOUT=600s`). All file rewrites (log prune, baseline GC) use per-process temp files (`$$.$RANDOM.tmp`) + non-empty guard + atomic rename so concurrent prune writers never corrupt the shared logs. The prune itself is size-gated (`LOG_PRUNE_SIZE_MAX=262144`) — the append is unconditional but the `awk|sort|mv` only runs when the file exceeds ~256 KB.

## Output contract

```
printf '%s\n' "$line1"   # line 1, trailing newline
printf '%s'   "$line2"   # line 2, NO trailing newline
```

Line 2 always starts with U+200B (zero-width space) + two spaces. All ANSI uses real `$'\033'` escape bytes.

## Keeping docs in sync

After implementing any feature or behavioral change:
- Update **`SPEC.md`** to reflect the new behavior (input fields, env vars, thresholds, edge cases, data flow)
- Update **`CLAUDE.md`** if the architecture section, env var list, or cache files change
- Update **`CHANGELOG.md`** under `## Unreleased` for any user-visible change

### CHANGELOG style rules

CHANGELOG is for **users**, not implementers. Before adding an entry, ask: *would someone configuring or reading the statusline care about this?* If the answer is "only if they're reading the source", skip it.

**Include:**
- New visual elements or glyphs (what they look like, when they appear)
- Behavioral changes a user would notice (something shows/hides differently, a threshold changed)
- New env vars or changed defaults
- Bug fixes that were visibly wrong

**Skip:**
- Implementation mechanics: lock files, PID handling, mtime tricks, retry logic, phase ordering
- Refactors with zero behavior change
- Internal constant renames or code cleanup

**Entry format:** `- **Short label:** one or two plain sentences describing the change from the user's perspective. No code blocks, no variable names unless they're env vars the user sets.`

## Subprocess environment (Claude Code only)

This script runs **only inside Claude Code** as a statusline subprocess — not as a general-purpose terminal tool. Its I/O environment is constrained:

- **stdin** is the JSON payload (a pipe, not a tty).
- **stdout/stderr** are pipes; no controlling terminal is attached.
- **`$COLUMNS`** is **set by Claude Code ≥ 2.1.153** when spawning the statusline subprocess, and is the primary width source. On older versions it may be present only if the user's shell exports it or a wrapper sets it.
- **`$LINES`** is also set by Claude Code ≥ 2.1.153 (currently unused by this script).
- **`/dev/tty`** and **stderr-fd** checks both fail: no controlling terminal is attached.
- **Ancestor PTY walk** (`_term_width_from_ancestor_pty`) is the fallback for Claude Code < 2.1.153: walks up the `ppid` chain (max 8 hops) to find a parent process with a real PTY, then queries it via `stty -f /dev/$tty size` (macOS) or `stty -F /dev/$tty size` (Linux). The `-f`/`-F` flag is required — `stty size < /dev/$tty` returns ENOTTY under Claude Code ≥ 2.1.139 because opening the device via redirection hits a different kernel code path.
- **Fallback** `_TERM_W_FALLBACK=220` (wide) is used only when all detection methods fail; wide avoids false compression.

**Terminal width detection order:** `$COLUMNS` (primary — set by Claude Code ≥ 2.1.153, or user shell export) → `/dev/tty` (harmless, always fails) → stderr-fd tty (harmless, always fails) → ancestor PTY walk (fallback for Claude Code < 2.1.153) → 220 fallback.

## Backup files

`statusline-command.sh.bak` and `statusline-command.sh.260507.bak` are previous versions kept for reference — do not commit changes to them.

## Plan model: Pro/Max vs Enterprise

The OAuth usage endpoint (`GET /api/oauth/usage`) returns the same envelope for every plan, but Pro/Max and Enterprise use it very differently. This matters because the rendering rules in SPEC §8.2–§8.4 branch on the *shape* of the response, not on an explicit plan-type field.

**Pro and Max plans:**
- Have **session-based** usage limits that reset every five hours, plus a **rolling 7-day** weekly cap. Both appear as `five_hour.utilization` and `seven_day.utilization` (numeric, 0–100) with `resets_at` timestamps.
- `extra_usage` is **optional pay-as-you-go** on top of the included plan limits. Users opt in via Settings → Usage; once enabled they can keep working past their 5h/7d caps at standard API rates.
- `extra_usage.monthly_limit` is the **user-configured ceiling** on overflow spend (in cents). `used_credits` is the cents already burned against it this month.
- Max 5× ≈ 5× the Pro 5h-window allowance; Max 20× ≈ 20×. They are "more usage" tiers, not feature-richer ones.

**Enterprise plans:**
- Have **no `five_hour` or `seven_day` windows** in the OAuth response — both fields come back as `null`. There is no session-based cap.
- `extra_usage.monthly_limit` is the **primary monthly budget** (in cents, seat-based, negotiated with sales). Enterprise spend is *entirely* pay-as-you-go from $0; `used_credits` accumulates toward that budget all month.
- Enterprise plans are billed per-seat individually — limits are not pooled across the organization.
- 200K context window on most models; 500K on some Enterprise tiers.

**How the statusline distinguishes plans:**
- If `five_hour.utilization` is present → Pro/Max → render §8.2 plan display + (conditionally) §8.3 extra badge.
- If `five_hour.utilization` is absent (null) but `extra_usage.is_enabled == "true"` → Enterprise → render §8.4 monthly segment with workday-pace math and per-window allowances.
- Per-window allowances are **Enterprise-only** because they depend on `(remaining_monthly_budget) / workdays_remaining`, which only makes sense for the Enterprise budgeting model.

**Unit gotchas:**
- `monthly_limit` and `used_credits` are always **cents** (integer or float). Divide by 100 to get USD.
- `utilization` is a **percent** (0–100), not a 0–1 fraction.
- `resets_at` is **UTC ISO 8601** with fractional seconds; convert to local `HH:MM` for display.

(May 2026 note: Anthropic doubled the Pro/Max 5h rate-limit windows and removed peak-hour throttling. Weekly caps unchanged. No change to the OAuth response shape.)

## Code style and performance

This script runs on **every status update** — latency matters. When touching the script, keep these principles:

### Fork reduction (highest impact)
- **Single jq pass** — extract all fields in one `jq` call with `@tsv` + `IFS=$'\t' read -r`, not 11 separate subshells.
- **No `cat file | cmd`** — use `cmd < file` or pass filename as argument.
- **`read` over `$(…)`** — for multi-field output (awk, cut, jq), capture with `IFS=$'\t' read -r` or `<<< "$var"` instead of repeated subshells.
- **Helper for repeated syscalls** — `_mtime()` wraps the BSD/GNU `stat` fallback chain; call it instead of inlining.

### DRY
- **No duplicate rendering blocks** — structurally identical segments (e.g. 5h vs 7d slots) belong in a helper function parameterized by their differences.
- **No repeated env-var normalization** — use `_env_opt VAR default val1 val2…` for all case-fold + validate + default patterns.
- **No repeated file-existence checks** — compute boolean flags once (`_auth_error`, `_DAY_START`) and reuse them.
- **Data-driven over case ladders** — associative arrays for effort-level colors/glyphs instead of 7-branch `case`.

### Clarity
- **Named constants** for magic numbers (`COST_EQ_THRESHOLD`, `LOG_PRUNE_WINDOW`, `BUDGET_WARN_LO`, etc.) at the top of the script with a brief comment.
- **No dead initializations** — don't set a variable only to immediately overwrite it.

### Constraints (never violate)
- Zero behavior change — SPEC.md is authoritative for all outputs and thresholds.
- POSIX-ish bash targeting macOS (BSD tools) + Linux (GNU tools); all fallback chains must remain.
- **Bash 3.2 compatible** — macOS ships bash 3.2 (GPL v2); the script must work on it. Known incompatibilities to avoid:
  - `declare -A` (associative arrays) — not available; use parallel indexed arrays or case ladders
  - `IFS=$'\x01' read -r ... < <(cmd)` — non-printable IFS bytes are silently stripped, not used as delimiters; all fields land in the first variable
  - `IFS=$'\t' read -r ... < <(cmd)` — tab is bash whitespace; consecutive tabs collapse, so empty fields disappear and remaining fields shift
  - **Safe pattern** for multi-field jq extraction: output one value per line, then use a `{ IFS= read -r var1; IFS= read -r var2; ... } < <(jq ...)` block
  - `IFS=$'\t' read -r ... <<< "$var"` is fine when all fields are guaranteed non-empty (e.g. awk-computed numeric output)
- All tests in `tests/` must pass (`bats tests/`) before any change is considered done.
- No new external dependencies beyond the existing set: `jq`, `awk`, `date`, `stat`, `git`, `curl`, `security`.
