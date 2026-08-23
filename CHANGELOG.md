# Changelog

## Unreleased

- **Faster statusline refreshes:** Repeated renders now avoid rescanning unchanged transcript history and skip duplicate state-file writes. Large transcripts, Git workspaces, and plan/budget displays respond substantially faster. Response timing also now accepts every documented role and timestamp form, including fractional ISO timestamps and timezone offsets.
- **Burned 5h/7d window keeps label and reset time:** The `🪫100%` badge (shown when your Pro/Max 5h or 7d window is fully burned) now keeps its `5h:`/`7d:` label and still shows the `↻HH:MM` reset time when available, instead of dropping both.
- **Git status markers:** Set CLAUDE_STATUSLINE_GIT_STATUS to dirty or on to show working-tree state next to the branch name — `+N` (green) for files with staged changes, `!N` (yellow) for files with unstaged changes, `?N` (dimmed) for untracked files, and dimmed `↑`/`↓` counts (green/orange) for commits ahead of or behind your upstream. Off by default. CLAUDE_STATUSLINE_GIT_UNTRACKED=off hides the `?N` marker.
- **Ultracode indicator:** `/effort ultracode` now shows as a rainbow-colored `ultracode` badge on line 1 instead of being indistinguishable from `xhigh`. Claude Code reports ultracode as plain `xhigh` in the statusline data, so the level is inferred from the transcript instead. Two caveats: a freshly switched level shows up one prompt late, and the badge only ever appears while the effort level is `xhigh`. Set `CLAUDE_STATUSLINE_ULTRACODE=off` to disable.
- **∑ⁱ scoped per instance:** Fixed a bug where a newly opened Claude Code instance could show a large, unexpected ∑ⁱ total inherited from another instance's accumulated cost. ∑ⁱ now starts at zero for each new instance and only accumulates its own pre-/clear cost.
- **∑ⁱ restored after `/clear`:** Claude Code 2.1.211 fixed `/clear` to properly reset `cost.total_cost_usd` to zero, which had the side-effect of breaking the ∑ⁱ instance-total badge (it disappeared after every `/clear`). The statusline now carries the pre-/clear cost forward in a small cache file, so ∑ⁱ correctly shows the full cost since the current Claude Code process started. The fix is backward-compatible with older Claude Code versions.
- **Accurate shared daily spend across instances:** The 💸 1d window now reliably reflects combined spend across all running Claude sessions, even when several instances write at once. Previously concurrent instances could corrupt the shared spend log and cause 1d to under-report (sometimes toward $0).
- **Accurate daily spend with multiple sessions:** The 💸 1d window now reports a session's full spend even when early usage samples were dropped or pruned (e.g. running several Claude instances at once). Previously a busy session could under-report today's spend toward $0.
- **Fix wrong Enterprise daily allowance after stale usage data:** The 💸 1d allowance (the `/$N` suffix) could be pinned for a whole day from a stale monthly-spend snapshot — e.g. after the machine slept across a monthly budget reset — showing a much smaller daily budget than correct until the next calendar day corrected it. The allowance is now only pinned for the day from usage data that was actually freshly fetched.
- **Terminal width via `$COLUMNS`:** Claude Code ≥ 2.1.153 now sets `COLUMNS` (and `LINES`) when spawning the statusline subprocess, making terminal-width detection reliable without the ancestor PTY walk. The script uses `$COLUMNS` first; the PTY walk remains as a fallback for older Claude Code versions.

## 2026-05-15

- **Performance:** Reduced fork count per render by ~30–50, lowering statusline latency. No visible behavior changes.
- **Adaptive line 2 truncation:** On narrow terminals, the 💸 rolling-spend segment (15m/1h/1d) is silently omitted when it would cause line 2 to wrap. Other segments are unaffected.
- **Adaptive CWD and branch shortening:** Line 1 stays within the terminal width. Paths shorten by abbreviating intermediate segments to two characters and ellipsizing the last segment with `…` when needed (e.g. `~/Pr/ap/claud…line`); strings only a few characters over budget pass through unchanged. `CLAUDE_STATUSLINE_CWD_MAXLEN` (default 64) and `CLAUDE_STATUSLINE_BRANCH_MAXLEN` (default 64) cap the maximum length; actual budgets are computed dynamically with branch given priority.
- **Locale-aware dollar amounts:** all cost and budget figures now consistently use the active locale's decimal separator — e.g. `$328,70` in pl_PL, `$328.70` in en_US. Previously some amounts followed the locale and others did not, producing mixed `,` and `.` on the same line.
- **Fix bash 3.2 compatibility in field parsing**

## 2026-05-14

- **Model status:** Shows fast mode (`↯`), effort level, and extended thinking (`🧠`) in the status line.
- **Monthly 🔥 pace:** Monthly spend is colored against workday progress (not plain calendar days). The line can show an optional `🔥` pace number: how your spend lines up with the work month so far (~1.00× means even). Use `CLAUDE_STATUSLINE_SHOW_PACE_RATIO=off` to hide it.
- **Configurable work days:** `CLAUDE_STATUSLINE_BUDGET_WORK_DAYS` sets which weekdays count toward pacing and runway (e.g. `12345` Mon–Fri, `1234567` every day). Per-window allowances and badge color both respect this.
- **Public holidays:** `CLAUDE_STATUSLINE_BUDGET_HOLIDAYS` lists `YYYY-MM-DD` dates (comma-separated) to treat as non-working in the current month when they fall on a configured work weekday. Per-window allowances divide remaining budget by fewer work days; monthly pacing and the fractional "elapsed workday" math subtract them. A holiday on today skips the partial-day bucket. The allowance cache keys include a holiday fingerprint so edits to the list invalidate stale entries.
- **Per-window allowances:** the 1h and 1d slots display a dim `/$X` suffix (e.g. `1h:$0.45/$3`) on Enterprise plans. The allowance is the per-window slice of remaining monthly budget — *if* you spent that much every window, you'd exactly use up the budget over the remaining workdays. Computed once at local midnight (or the first invocation of the day) and cached so the suffix does not drift mid-day. The 15m slot never shows an allowance.
- **Rolling spend 💸:** `CLAUDE_STATUSLINE_COST_LOADAVG` toggles the rolling 15m/1h/1d segment. `on` (default) keeps spend plus `/$X` allowance suffix where Enterprise allowances exist; `spent_only` shows spend only and skips allowance cache work; `off` hides 💸 entirely and skips all rolling-window computation. Windows are **global across all sessions and instances** for the workspace — they reflect total workspace spend, not just the current session.
- **Perf / cache dots:** `CLAUDE_STATUSLINE_PERF_BADGE` controls the leading transcript-driven dot cluster (cache hit % vs response time). `on` (default) uses both; `cache_only` skips the latency scan; `latency_only` skips the cache-token scan; `off` hides the dots and skips all transcript I/O.
- **Usage sync states:** the plan/budget segments distinguish three states:
  - 💰 fresh — last fetch succeeded, data current. Utilization shown bold.
  - ⚠️ stale — cache older than 15 min, no refresh in flight. Utilization shown with strikethrough (no bold); color and 🔥 pace still render from last-known data.
  - 🔑 auth-broken — last fetch failed (curl error or no keychain token). Shows `$used/$limit` struck through together, no color, no percent, no pace — signals re-authentication rather than "wait." Tracked via `~/.claude/statusline-usage-fetch.error`; cleared on next successful fetch.
- **🪫 budget burned:** when Enterprise `used_credits ≥ monthly_limit`, the monthly segment switches to `🪫$<used>/$<limit>` (red, bold) and drops the percent and 🔥 pace indicators — both are meaningless past 100%. Same glyph applies to Pro/Max 5h slots that reach 100%.
- **Dual cost counters:** Line 2 shows session spend (`∑ˢ`, resets on `/clear`) and instance total (`∑ⁱ`, dimmer). `CLAUDE_STATUSLINE_COST_CURRENT`:
  - `on` (default) shows both, deduplicating to ∑ˢ alone when within $0.01.
  - `session` always shows only ∑ˢ.
  - `instance` always shows only ∑ⁱ.
  - `off` hides cost badges entirely.
- **Budget sign modes:** `CLAUDE_STATUSLINE_BUDGET_SIGN_MODE` controls how rolling $ amounts are shown — `neutral` (default), `used_minus` (`-` for spent), `remaining_plus` (`+` for remaining), or `both`.
- **API error resilience:** When Anthropic returns a rate-limit or server error (valid JSON with an `"error"` key), the fetch no longer silently replaces a good cache with the error body. The previous cache is preserved and `🔑` auth-broken is shown instead of a blank plan segment.
- **Wake-from-sleep resilience:** No more false ⚠️ stale warning after the laptop wakes up or reboots.
- **Environment variables:**
  - `CLAUDE_STATUSLINE_BUDGET_SIGN_MODE` — `neutral` | `used_minus` | `remaining_plus` | `both` (default `neutral`).
  - `CLAUDE_STATUSLINE_BUDGET_HOURS_PER_DAY` — coding hours per work day for hourly allowance (default `6`).
  - `CLAUDE_STATUSLINE_BUDGET_WORK_DAYS` — weekday digits 1–7 (1=Mon) that count as work; default `12345`.
  - `CLAUDE_STATUSLINE_BUDGET_HOLIDAYS` — comma-separated `YYYY-MM-DD` public holidays; ignored on non-work weekdays.
  - `CLAUDE_STATUSLINE_COST_CURRENT` — `on` | `session` | `instance` | `off` (default `on`).
  - `CLAUDE_STATUSLINE_COST_LOADAVG` — `on` | `spent_only` | `off` (default `on`).
  - `CLAUDE_STATUSLINE_PERF_BADGE` — `on` | `cache_only` | `latency_only` | `off` (default `on`).
  - `CLAUDE_STATUSLINE_SHOW_PACE_RATIO` — `on` | `off` (default `on`).
  - `CLAUDE_STATUSLINE_EXTRA_PREVIEW_PCT` — integer 0–100 (default `75`). On Pro/Max, the extra-credits balance appears whenever `five_hour.utilization` reaches this threshold (default 75%) even if `used_credits == 0`, giving advance warning before spending spills into pay-as-you-go.

### 2026-04-21#2

- **Cleanup:** Dropped leftover debug output (`echo` of stdin to `/tmp/input.json`) and related blank lines.

### 2026-04-21

- **Context line:** Reworked how context is shown (e.g. **used/limit tokens in k** plus **%**, aligned with `context_window_size` from JSON).
- **Tuning:** Added support for **`CLAUDE_STATUSLINE_CTX_WARN_PCT`**, **`CLAUDE_STATUSLINE_CTX_CAUTION_TOKENS`**, and **`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`** for warn/caution/red coloring vs. default thresholds.
- **Parsing:** Pulled **`context_window_size`** through the same **`jq`** read block as other fields; added helpers like **`fmt_ctx_k`** for compact token counts.

### 2026-04-20

- **Large refactor:** Replaced many per-field **`echo | jq`** calls with **one `jq` process** and **`read`** into shell variables (fewer forks, clearer pipeline).
- **Transcript metrics:** Reworked token aggregation from the transcript ( **`jq` over the file + `awk`*** instead of a bash line loop).
- **Timestamps / perf:** Expanded **`jq`** logic for message timestamps (epoch scaling, ISO with fractional seconds, object wrappers like `.seconds` / `.unix`, ignoring boolean timestamps) for more reliable response-time stats.

### 2026-04-15

- **Initial publish:** Bash **Claude Code status line** (Powerlevel10k-style layout, cost/session display, **`jq`** on status JSON, transcript-derived cache hit rate and response-time style metrics, global cost log, etc.).
