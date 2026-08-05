# ROADMAP

Forward-looking plan and "we know about it, not changing it" list. SPEC.md is the authoritative behavioral spec; this file is for things that are *not yet* in SPEC.md or are intentionally left as-is.

---

## Next version (prioritized)

Ordered by priority — top item first.

### 1. Windows support

Lower priority; only relevant if Claude Code itself runs on Windows outside WSL.

- WSL passes through cleanly (Linux under the hood) — handled by the Linux item above.
- Native Windows would require: PowerShell equivalents for `mkdir`-lock, a credential-manager call for the OAuth token, and Windows-flavoured `date` parsing. Probably not worth the engineering cost.

---

## Some day

Lower-priority improvements without a target version.

- **Emoji-free mode env var:** today emoji is always on. If a user opens an issue about terminals that can't render them, add `CLAUDE_STATUSLINE_EMOJI=off` and a fallback glyph table.
- **Configurable rolling-window set:** today we hard-code `{15m, 1h, 1d}`. Could expose `CLAUDE_STATUSLINE_ROLLING_WINDOWS="5m,15m,1h,4h,1d"` if a user asks.
- **Stricter monotonicity check on the global log:** the log is append-only by epoch but cost can decrease (e.g. if Claude Code resets `total_cost_usd` mid-instance). Today we clamp `spent < 0 → 0`. A more elegant approach would be to detect resets and start a new segment.
- **Remove instance-carry compatibility shim (post-2.1.211 only):** `statusline-instance-carry.cache` and the carry accumulation logic in `statusline-command.sh` exist solely to bridge the gap between old (cost continues across `/clear`) and new (cost resets at `/clear`, since 2.1.211) Claude Code behavior. Once support for Claude Code < 2.1.211 can be dropped, the carry file can be deleted and ∑ⁱ simplified back to `session_cost` (since after a reset, session_cost and instance_cost are always equal anyway — ∑ⁱ would only show when carry > 0, which is the only interesting case).
- **Per-machine vs per-user log split:** the global usage log is per-`$HOME`. Users with multiple machines sharing `~/.claude` over NFS could double-count. Probably solve with a `$HOSTNAME` partition column if it ever bites someone.
- **Pluggable plan detection:** the Pro/Max vs Enterprise discriminator is implicit (`five_hour.utilization` absent ⇒ Enterprise). If a third plan shape appears, generalize.

---

## Known quirks (accepted, not changing)

Behaviors that look like magic numbers but are intentional. Document them here so future implementers don't "fix" them.

| Quirk | Value | Why it's fine |
|---|---|---|
| Win/anc reference must be ≥ 5 s old | `5 seconds` | Prevents the row just appended *this same invocation* from being its own reference (which would yield `spent = 0` forever). 5 s is well below the human-noticeable update cadence of the statusline. |
| Global log prune window | `36 hours` | Long enough that the "last sample before local midnight" anchor for 1d calendar windows survives an evening of inactivity; short enough that the log stays small (a few KB). Tuned empirically. |
| Baseline GC probability | `1 / 100` per invocation (`RANDOM % 100 == 0`) | Cheap probabilistic GC. Idle rows clear out within ~100 statusline renders without paying the I/O cost every tick. |
| `mkdir`-lock timeout budget | `25 × 50 ms = ~1.25 s` | Long enough to ride out the normal contention window; short enough that a stuck lock skips the append (display continues with stale spend) rather than blocking the statusline render. |
| Last-resort midnight fallback | `NOW - 86400` | Only triggers when both BSD and GNU `date(1)` are broken. Degrades the calendar-1d window to rolling-24h rather than crashing. |
| `USAGE_REFRESH_SLOW_SECS` | `30 s` | Threshold for showing the dim `↻` "fetch in progress" indicator. Calibrated against the median curl duration when the cache is warm. |
| `2 × CACHE_TTL` stale threshold | `600 s` (10 min) | After this point we no longer trust the displayed value enough to suppress the staleness glyph. Twice the refresh TTL gives one full TTL of "should-have-refreshed-by-now" grace. |
| Sparse-log "win-first" 1d preference | structural | When the log has multi-day gaps, anc-first attributes the gap to "today." Win-first only treats today's spend as today's, falling back to anc only if no in-day row exists yet. |
