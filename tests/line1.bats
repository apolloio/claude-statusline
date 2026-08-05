#!/usr/bin/env bats
# Line 1 tests: CWD, git branch, model, thinking, fast mode, effort, context window

load test_helper

# ── CWD display ───────────────────────────────────────────────────────────────

@test "line1: shows cwd from workspace.current_dir" {
  run_statusline "$(make_json cwd=/tmp/myproject)"
  assert_line1_contains "/tmp/myproject"
}

@test "line1: shows cwd from .cwd fallback field" {
  run_statusline '{"cwd":"/tmp/fallback","model":{"display_name":"Sonnet 4.6"},"context_window":{"used_percentage":5,"context_window_size":200000},"cost":{"total_cost_usd":0}}'
  assert_line1_contains "/tmp/fallback"
}

@test "line1: substitutes HOME with tilde" {
  run_statusline "$(make_json cwd="$HOME/Projects/foo")"
  assert_line1_contains "~/Projects/foo"
  assert_line1_not_contains "$HOME/Projects/foo"
}

@test "line1: shows exact HOME path as tilde only" {
  run_statusline "$(make_json cwd="$HOME")"
  assert_line1_contains "~"
}

@test "line1: no cwd when field missing" {
  run_statusline '{"model":{"display_name":"Sonnet 4.6"},"context_window":{"used_percentage":5,"context_window_size":200000},"cost":{"total_cost_usd":0}}'
  # Should still produce two lines without crashing
  [ "$status" -eq 0 ]
}

# ── Git branch ────────────────────────────────────────────────────────────────

@test "line1: shows git branch with ⎇ icon" {
  local repo="$BATS_TEST_TMPDIR/myrepo"
  make_git_repo "$repo" main
  run_statusline "$(make_json cwd="$repo")"
  assert_line1_contains "⎇"
  assert_line1_contains "main"
}

@test "line1: shows custom branch name" {
  local repo="$BATS_TEST_TMPDIR/repo2"
  make_git_repo "$repo" feature/my-branch
  run_statusline "$(make_json cwd="$repo")"
  assert_line1_contains "feature/my-branch"
}

@test "line1: no git indicator when cwd is not a git repo" {
  run_statusline "$(make_json cwd="$NO_GIT_DIR")"
  assert_line1_not_contains "⎇"
}

@test "line1: detached HEAD shows short hash instead of branch name" {
  local repo="$BATS_TEST_TMPDIR/detached"
  make_git_repo "$repo" main
  git -C "$repo" checkout --detach HEAD --quiet 2>/dev/null
  run_statusline "$(make_json cwd="$repo")"
  # Should show a short hash (7 hex chars) since no branch name
  assert_line1_not_contains "main"
  # Still shows ⎇ icon
  assert_line1_contains "⎇"
}

# ── Model name ────────────────────────────────────────────────────────────────

@test "line1: shows model display name" {
  run_statusline "$(make_json model="Sonnet 4.6")"
  assert_line1_contains "Sonnet 4.6"
}

@test "line1: shows different model name" {
  run_statusline "$(make_json model="Opus 4.7")"
  assert_line1_contains "Opus 4.7"
}

@test "line1: model absent when field missing" {
  run_statusline '{"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":5,"context_window_size":200000},"cost":{"total_cost_usd":0}}'
  [ "$status" -eq 0 ]
}

# ── Thinking indicator ────────────────────────────────────────────────────────

@test "line1: shows 🧠 when thinking.enabled is true" {
  run_statusline "$(make_json thinking=true)"
  assert_line1_contains "🧠"
}

@test "line1: no 🧠 when thinking.enabled is false" {
  run_statusline "$(make_json thinking=false)"
  assert_line1_not_contains "🧠"
}

@test "line1: no 🧠 when thinking field absent" {
  run_statusline "$(make_json)"
  assert_line1_not_contains "🧠"
}

# ── Fast mode ─────────────────────────────────────────────────────────────────

@test "line1: shows ↯ when fast_mode is true" {
  run_statusline "$(make_json fast=true)"
  assert_line1_contains "↯"
}

@test "line1: no ↯ when fast_mode is false" {
  run_statusline "$(make_json fast=false)"
  assert_line1_not_contains "↯"
}

@test "line1: no ↯ when fast_mode absent" {
  run_statusline "$(make_json)"
  assert_line1_not_contains "↯"
}

# ── Effort level glyphs ───────────────────────────────────────────────────────

@test "line1: effort none shows ∅" {
  run_statusline "$(make_json effort=none)"
  assert_line1_contains "∅"
}

@test "line1: effort low shows ○" {
  run_statusline "$(make_json effort=low)"
  assert_line1_contains "○"
}

@test "line1: effort medium shows ◑" {
  run_statusline "$(make_json effort=medium)"
  assert_line1_contains "◑"
}

@test "line1: effort auto shows 🅐" {
  run_statusline "$(make_json effort=auto)"
  assert_line1_contains "🅐"
}

@test "line1: effort high shows ●" {
  run_statusline "$(make_json effort=high)"
  assert_line1_contains "●"
}

@test "line1: effort xhigh shows ◉" {
  run_statusline "$(make_json effort=xhigh)"
  assert_line1_contains "◉"
}

@test "line1: effort max shows ◈" {
  run_statusline "$(make_json effort=max)"
  assert_line1_contains "◈"
}

@test "line1: no effort glyph when effort field absent" {
  run_statusline "$(make_json)"
  assert_line1_not_contains "∅"
  assert_line1_not_contains "◑"
  assert_line1_not_contains "◈"
}

# ── Effort colors ─────────────────────────────────────────────────────────────

@test "line1: effort none is dim colored" {
  run_statusline "$(make_json effort=none)"
  assert_raw_line1_contains "${ANSI_DIM}"
}

@test "line1: effort low is green colored" {
  run_statusline "$(make_json effort=low)"
  assert_raw_line1_contains "${ANSI_GREEN}"
}

@test "line1: effort high is orange colored" {
  run_statusline "$(make_json effort=high)"
  assert_raw_line1_contains "${ANSI_ORANGE}"
}

@test "line1: effort max is red colored" {
  run_statusline "$(make_json effort=max)"
  assert_raw_line1_contains "${ANSI_RED}"
}

# ── Context window display ────────────────────────────────────────────────────

@test "line1: shows ctx segment with used% and window size" {
  run_statusline "$(make_json used=12 window=200000)"
  assert_line1_contains "ctx:"
  assert_line1_contains "12%"
}

@test "line1: formats used tokens in k notation" {
  # 12% of 200000 = 24000 → 24k
  run_statusline "$(make_json used=12 window=200000)"
  assert_line1_contains "24k"
}

@test "line1: formats window size in k notation" {
  run_statusline "$(make_json used=12 window=200000)"
  assert_line1_contains "200k"
}

@test "line1: ctx dim color at low usage" {
  run_statusline "$(make_json used=10 window=200000)"
  assert_raw_line1_contains "${ANSI_DIM}"
}

@test "line1: ctx orange color above 75%" {
  run_statusline "$(make_json used=80 window=200000)"
  assert_raw_line1_contains "${ANSI_ORANGE}"
}

@test "line1: ctx red color at 95% or above" {
  run_statusline "$(make_json used=95 window=200000)"
  assert_raw_line1_contains "${ANSI_RED}"
}

@test "line1: ctx blue caution color above 150k tokens" {
  # 76% of 200000 = 152000 > 150000 tokens, but 76% < 75% threshold (orange)
  # Actually 76% > 75% so it'd be orange. Use 74% of 210k = 155400 tokens
  # 74% of 210000 = 155400 > 150000 but 74% < 75% → caution (blue)
  run_statusline "$(make_json used=74 window=210000)"
  assert_raw_line1_contains "${ANSI_BLUE}"
}

@test "line1: shows dash when context_window field missing" {
  run_statusline '{"session_id":"s1","model":{"display_name":"Sonnet 4.6"},"cost":{"total_cost_usd":0},"workspace":{"current_dir":"/tmp"}}'
  assert_line1_contains "ctx:—"
}

@test "line1: small token count without k suffix" {
  # 1% of 200000 = 2000 → shown as 2000 not 2k (below 1000 threshold)
  # Actually 1% of 200k = 2000 → 2k (>= 1000, so shows k)
  # Use 0% of 200000 = 0 → 0 (no k)
  run_statusline "$(make_json used=0 window=200000)"
  assert_line1_contains "ctx:0/"
}

# ── Combined flags ────────────────────────────────────────────────────────────

@test "line1: fast mode and thinking together" {
  run_statusline "$(make_json fast=true thinking=true)"
  assert_line1_contains "🧠"
  assert_line1_contains "↯"
}

@test "line1: fast mode and effort together" {
  run_statusline "$(make_json fast=true effort=high)"
  assert_line1_contains "↯"
  assert_line1_contains "●"
}

# ── CWD shortening ────────────────────────────────────────────────────────────

# ── Minimum-savings guard ─────────────────────────────────────────────────────
# "…" is 1 char. If shortening would save only a handful of characters,
# it's worse than just letting the string be slightly over budget.
# The exact threshold is left to the implementer (suggested: skip if savings < 5),
# but these tests establish the outer bounds.

@test "line1: cwd 1 char over maxlen passes through without ellipsis" {
  # "/tmp/abcdefghijklmnoX" = 21 chars, MAXLEN=20 → net saving=1 → no ellipsis
  CLAUDE_STATUSLINE_CWD_MAXLEN=20 \
    run_statusline "$(make_json cwd="/tmp/abcdefghijklmnoX")"
  assert_line1_not_contains "…"
  assert_line1_contains "/tmp/abcdefghijklmnoX"
}

@test "line1: cwd 2 chars over maxlen passes through without ellipsis" {
  # "/tmp/abcdefghijklmnoXY" = 22 chars, MAXLEN=20 → net saving=2 → no ellipsis
  CLAUDE_STATUSLINE_CWD_MAXLEN=20 \
    run_statusline "$(make_json cwd="/tmp/abcdefghijklmnoXY")"
  assert_line1_not_contains "…"
  assert_line1_contains "/tmp/abcdefghijklmnoXY"
}

@test "line1: cwd 10 chars over maxlen does get ellipsized" {
  # "/tmp/abcdefghijklmnoXYZABCDEFG" = 30 chars, MAXLEN=20 → saving=10 ≥ 5 → ellipsis fires.
  # parts[0]="" (root) preserved verbatim, intermediate "tmp" → "tm", last gets mid-ellipsis:
  # prefix="/tm" (3), last_budget=20-3-1=16, _mid_ellipsis(25,16): budget=15, head=6, tail=9
  CLAUDE_STATUSLINE_CWD_MAXLEN=20 \
    run_statusline "$(make_json cwd="/tmp/abcdefghijklmnoXYZABCDEFG")"
  assert_line1_contains "/tm/abcdef…YZABCDEFG"
}

@test "line1: branch 1 char over maxlen passes through without ellipsis" {
  local repo="$BATS_TEST_TMPDIR/br-minsav-1"
  # "a-branch-name-21chars" = 21 chars, MAXLEN=20 → saving=1 → no ellipsis
  make_git_repo "$repo" "a-branch-name-21chars"
  CLAUDE_STATUSLINE_BRANCH_MAXLEN=20 \
    run_statusline "$(make_json cwd="$repo")"
  assert_line1_not_contains "…"
  assert_line1_contains "a-branch-name-21chars"
}

@test "line1: branch 2 chars over maxlen passes through without ellipsis" {
  local repo="$BATS_TEST_TMPDIR/br-minsav-2"
  # "a-branch-name-21charsx" = 22 chars, MAXLEN=20 → saving=2 → no ellipsis
  make_git_repo "$repo" "a-branch-name-21charsx"
  CLAUDE_STATUSLINE_BRANCH_MAXLEN=20 \
    run_statusline "$(make_json cwd="$repo")"
  assert_line1_not_contains "…"
  assert_line1_contains "a-branch-name-21charsx"
}

@test "line1: branch 10 chars over maxlen does get ellipsized" {
  local repo="$BATS_TEST_TMPDIR/br-minsav-10"
  # "a-branch-name-21chars1234567" = 28 chars, MAXLEN=20 → saving=8 → ellipsis
  # _mid_ellipsis(28, 20): budget=19, head=7, tail=12 → "a-branc…chars1234567"
  make_git_repo "$repo" "a-branch-name-21chars1234567"
  CLAUDE_STATUSLINE_BRANCH_MAXLEN=20 \
    run_statusline "$(make_json cwd="$repo")"
  assert_line1_contains "a-branc…chars1234567"
}

@test "line1: slash-segmented branch 1 char over maxlen passes through" {
  local repo="$BATS_TEST_TMPDIR/br-minsav-slash"
  # "feature/my-branch-end" = 21 chars, MAXLEN=20 → even after prefix shortening
  # fe/my-branch-end = 16 chars (fits), so no ellipsis in last segment either
  make_git_repo "$repo" "feature/my-branch-end"
  CLAUDE_STATUSLINE_BRANCH_MAXLEN=20 \
    run_statusline "$(make_json cwd="$repo")"
  assert_line1_not_contains "…"
}

@test "line1: home-relative cwd 2 chars over maxlen passes through" {
  # "~/abcdefghijklmnopqrs" = 21 chars (tilde = 1), MAXLEN=20 → saving=1 (display) → no ellipsis
  # The actual path is $HOME/abcdefghijklmnopqrs but displayed as ~/abcdefghijklmnopqrs = 21 chars
  CLAUDE_STATUSLINE_CWD_MAXLEN=20 \
    run_statusline "$(make_json cwd="$HOME/abcdefghijklmnopqrs")"
  assert_line1_not_contains "…"
  assert_line1_contains "~/abcdefghijklmnopqrs"
}

@test "line1: short cwd passes through unchanged" {
  run_statusline "$(make_json cwd=/tmp/myproject)"
  assert_line1_contains "/tmp/myproject"
}

@test "line1: long cwd intermediates shrink to first char" {
  # MAXLEN=20 forces shortening on ~/workspaces/sample-service (27 chars)
  CLAUDE_STATUSLINE_CWD_MAXLEN=20 \
    run_statusline "$(make_json cwd="$HOME/workspaces/sample-service")"
  # Intermediate "workspaces" → "wo"
  assert_line1_contains "~/wo/sample-service"
}

@test "line1: long last segment gets middle-ellipsis when intermediates not enough" {
  # prefix="~/wo" (4), candidate (29) > MAXLEN=25; last_budget=25-4-1=20 >= 3
  # → _mid_ellipsis("averylonglastsegmentname", 20): budget=19, head=7, tail=12
  CLAUDE_STATUSLINE_CWD_MAXLEN=25 \
    run_statusline "$(make_json cwd="$HOME/workspaces/averylonglastsegmentname")"
  assert_line1_contains "~/wo/averylo…tsegmentname"
}

@test "line1: deeply nested path collapses middle intermediates" {
  # 7 intermediates at MAXLEN=20: prefix = "~/aa/bb/cc/dd/ee/ff/gg" (22 chars),
  # last_budget=20-22-1=-3 <3 → step 3: collapsed_prefix="~/aa/…/gg" (9), budget=20-9-1=10
  # → _mid_ellipsis("target", 10) = "target" (6<=10, passthrough) → ~/aa/…/gg/target
  CLAUDE_STATUSLINE_CWD_MAXLEN=20 \
    run_statusline "$(make_json cwd="$HOME/aaa/bbb/ccc/ddd/eee/fff/ggg/target")"
  assert_line1_contains "~/aa/…/gg/target"
}

@test "line1: env var ceiling honored even on wide terminal" {
  # tput mock returns 200 cols; MAXLEN=15 forces shortening of ~/workspaces/sample-service
  # prefix="~/wo" (4), last_budget=15-4-1=10 >= 3
  # Change B: (10-1)*2=18 < 14? NO → skip; _mid_ellipsis("sample-service", 10): budget=9, head=3, tail=6
  CLAUDE_STATUSLINE_CWD_MAXLEN=15 \
    run_statusline "$(make_json cwd="$HOME/workspaces/sample-service")"
  assert_line1_contains "~/wo/sam…ervice"
}

@test "line1: absolute path with long last segment" {
  # /tmp/a-very-long-project-name-here: prefix="/tm" (3), last_budget=20-3-1=16 >= 3
  # → _mid_ellipsis("a-very-long-project-name-here", 16): budget=15, head=6, tail=9
  CLAUDE_STATUSLINE_CWD_MAXLEN=20 \
    run_statusline "$(make_json cwd="/tmp/a-very-long-project-name-here")"
  assert_line1_contains "/tm/a-very…name-here"
}

@test "line1: deep absolute path collapses to intermediate chars" {
  # /usr/local/share/data/applications: intermediates → /us/lo/sh/da → prefix="/us/lo/sh/da" (12)
  # candidate="/us/lo/sh/da/applications" (25 > 20), last_budget=20-12-1=7 >= 3
  # → _mid_ellipsis("applications", 7): budget=6, head=2, tail=4 → "ap…ions"
  CLAUDE_STATUSLINE_CWD_MAXLEN=20 \
    run_statusline "$(make_json cwd="/usr/local/share/data/applications")"
  assert_line1_contains "/us/lo/sh/da/ap…ions"
}

@test "line1: invalid CWD_MAXLEN falls back to default (64)" {
  # "abc" is not a valid integer ≥ 8; should use default of 64 (no truncation needed)
  CLAUDE_STATUSLINE_CWD_MAXLEN=abc \
    run_statusline "$(make_json cwd=/tmp/myproject)"
  assert_line1_contains "/tmp/myproject"
}

@test "line1: long cwd shortened while short branch shown in full (in git repo)" {
  # CWD ~/workspaces/sample-service (27 chars) > MAXLEN=20 → shortened to ~/wo/sample-service
  # Branch "main" (4 chars) ≤ BRANCH_MAXLEN=32 → passes through unchanged
  local repo="$HOME/workspaces/sample-service"
  make_git_repo "$repo" main
  CLAUDE_STATUSLINE_CWD_MAXLEN=20 \
    run_statusline "$(make_json cwd="$repo")"
  assert_line1_contains "~/wo/sample-service"
  assert_line1_contains "main"
}

# ── Branch shortening ─────────────────────────────────────────────────────────

@test "line1: short branch passes through unchanged" {
  local repo="$BATS_TEST_TMPDIR/br-short"
  make_git_repo "$repo" main
  run_statusline "$(make_json cwd="$repo")"
  assert_line1_contains "main"
}

@test "line1: long branch shortened while short cwd shown in full" {
  # CWD "$BATS_TEST_TMPDIR/myproject" → short absolute path, well under MAXLEN=64
  # Branch "feature/myteam/a-very-long-ticket-name-for-this-feature" (55 chars) > MAXLEN=32:
  #   parts[0]="feature"→"fe", intermediate "myteam"→"my"; prefix="fe/my" (5)
  #   candidate="fe/my/a-very-long-ticket-name-for-this-feature" (46) > 32
  #   last_budget=32-5-1=26; _mid_ellipsis(40, 26): budget=25, head=10, tail=15
  #   → "fe/my/a-very-lon…or-this-feature"
  local repo="$BATS_TEST_TMPDIR/myproject"
  make_git_repo "$repo" "feature/myteam/a-very-long-ticket-name-for-this-feature"
  CLAUDE_STATUSLINE_BRANCH_MAXLEN=32 \
    run_statusline "$(make_json cwd="$repo")"
  assert_line1_contains "myproject"
  assert_line1_contains "fe/my/a-very-lon…or-this-feature"
}

@test "line1: long single-token branch gets middle-ellipsis" {
  # "a-very-long-branch-name-that-exceeds-the-limit" (46 chars) → MAXLEN=20
  # single token: _mid_ellipsis(str, 20): budget=19, head=7, tail=12
  local repo="$BATS_TEST_TMPDIR/br-long"
  make_git_repo "$repo" "a-very-long-branch-name-that-exceeds-the-limit"
  CLAUDE_STATUSLINE_BRANCH_MAXLEN=20 \
    run_statusline "$(make_json cwd="$repo")"
  assert_line1_contains "a-very-…ds-the-limit"
}

@test "line1: slash-segmented branch shrinks intermediates" {
  # "feature/myteam/my-ticket-number" (31 chars) → MAXLEN=24
  # parts[0]="feature"→"fe", intermediate "myteam"→"my"; prefix="fe/my" (5)
  # candidate="fe/my/my-ticket-number" (22) ≤ 24 → return directly
  local repo="$BATS_TEST_TMPDIR/br-slash"
  make_git_repo "$repo" "feature/myteam/my-ticket-number"
  CLAUDE_STATUSLINE_BRANCH_MAXLEN=24 \
    run_statusline "$(make_json cwd="$repo")"
  assert_line1_contains "fe/my/my-ticket-number"
}

@test "line1: multi-segment branch with deep slash hierarchy" {
  # "features/backend/users/add-oauth-permission-model" (49 chars) → MAXLEN=32
  # parts[0]="features"→"fe", intermediates "ba","us"; prefix="fe/ba/us" (8)
  # candidate="fe/ba/us/add-oauth-permission-model" (35) > 32
  # last_budget=32-8-1=23; Change B: (23-1)*2=44 ≥ 26 → skip
  # _mid_ellipsis("add-oauth-permission-model", 23): budget=22, head=8, tail=14
  # → "fe/ba/us/add-oaut…rmission-model"
  local repo="$BATS_TEST_TMPDIR/br-deep"
  make_git_repo "$repo" "features/backend/users/add-oauth-permission-model"
  CLAUDE_STATUSLINE_BRANCH_MAXLEN=32 \
    run_statusline "$(make_json cwd="$repo")"
  assert_line1_contains "fe/ba/us/add-oaut…rmission-model"
}

@test "line1: branch within maxlen is not ellipsized" {
  local repo="$BATS_TEST_TMPDIR/br-wide"
  # 34-char branch ≤ MAXLEN=40, tput mock gives 200 cols → fits comfortably
  make_git_repo "$repo" "feature/a-descriptive-shorter-name"
  CLAUDE_STATUSLINE_BRANCH_MAXLEN=40 \
    run_statusline "$(make_json cwd="$repo")"
  assert_line1_contains "feature/a-descriptive-shorter-name"
}

@test "line1: invalid BRANCH_MAXLEN falls back to default (32)" {
  local repo="$BATS_TEST_TMPDIR/br-invalid"
  make_git_repo "$repo" main
  CLAUDE_STATUSLINE_BRANCH_MAXLEN=0 \
    run_statusline "$(make_json cwd="$repo")"
  assert_line1_contains "main"
}

@test "line1: synthetic long cwd + long slash-segmented branch both shorten correctly" {
  # Synthetic boundary regression with matching branch and cwd identifiers.
  # COLUMNS=200, CWD_MAXLEN=64, BRANCH_MAXLEN=64 (all defaults).
  #
  # Branch "sample-user/TASK-12345-stale-feature-flag-i18n-portuguese-fully-rolled-release-check" (84 chars),
  # default BRANCH_MAXLEN=64:
  #   parts[0]="sample-user"→"sa" (always shortened); n=2, no intermediates; prefix="sa" (2)
  #   candidate=75 > 64; last_budget=64-2-1=61
  #   _mid_ellipsis(72, 61): budget=60, head=24, tail=36 → "TASK-12345-stale-feature…ortuguese-fully-rolled-release-check"
  #   → "sa/TASK-12345-stale-feature…ortuguese-fully-rolled-release-check"
  #
  # CWD "~/workspaces/sample-service-sample-user-TASK-12345-stale-feature-flag-i18n-portuguese-fully-rolled" (101 chars),
  # default CWD_MAXLEN=64:
  #   intermediates w→wo; prefix="~/wo" (4), last_budget=64-4-1=59, head=23, tail=35
  #   → "~/wo/sample-service-sample-u…e-flag-i18n-portuguese-fully-rolled"
  local branch="sample-user/TASK-12345-stale-feature-flag-i18n-portuguese-fully-rolled-release-check"
  local last_seg="sample-service-sample-user-TASK-12345-stale-feature-flag-i18n-portuguese-fully-rolled"
  local repo="$HOME/workspaces/$last_seg"
  make_git_repo "$repo" "$branch"
  run_statusline "$(make_json cwd="$repo")"
  assert_line1_contains "~/wo/sample-service-sample-u…e-flag-i18n-portuguese-fully-rolled"
  assert_line1_contains "sa/TASK-12345-stale-feature…ortuguese-fully-rolled-release-check"
}
