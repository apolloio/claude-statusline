#!/usr/bin/env bats
# Todo/task progress segment on line 2 (CLAUDE_STATUSLINE_TODOS, opt-in)

load test_helper

@test "todos: default (unset) shows no segment, line2 byte-identical to explicit off" {
  make_tasks "sess-default" "1:completed:Stage scripts:Staging scripts" \
                             "2:in_progress:Run build:Building the bundle"
  run_statusline "$(make_json session=sess-default)"
  local with_default
  with_default="$(raw_line2)"
  assert_line2_not_contains "☑"

  export CLAUDE_STATUSLINE_TODOS=off
  run_statusline "$(make_json session=sess-default)"
  [ "$(raw_line2)" = "$with_default" ]
}

@test "todos: =on with no task directory shows no segment" {
  export CLAUDE_STATUSLINE_TODOS=on
  run_statusline "$(make_json session=sess-notasks)"
  assert_line2_not_contains "☑"
}

@test "todos: =on shows completed/total count and in-progress activeForm" {
  export CLAUDE_STATUSLINE_TODOS=on
  make_tasks "sess-progress" \
    "1:completed:Stage scripts:Staging scripts" \
    "2:completed:Wire config:Wiring config" \
    "3:in_progress:Run build:Building the bundle" \
    "4:pending:Ship it:Shipping it" \
    "5:pending:Cleanup:Cleaning up"
  run_statusline "$(make_json session=sess-progress)"
  assert_line2_contains "☑ 2/5"
  assert_line2_contains "Building the bundle"
}

@test "todos: =on with all tasks completed hides the segment" {
  export CLAUDE_STATUSLINE_TODOS=on
  make_tasks "sess-alldone" \
    "1:completed:Stage scripts:Staging scripts" \
    "2:completed:Run build:Building the bundle"
  run_statusline "$(make_json session=sess-alldone)"
  assert_line2_not_contains "☑"
}

@test "todos: =on with no in-progress task falls back to first pending item" {
  export CLAUDE_STATUSLINE_TODOS=on
  make_tasks "sess-pending" \
    "1:completed:Stage scripts:Staging scripts" \
    "2:pending:Run build:Building the bundle" \
    "3:pending:Ship it:Shipping it"
  run_statusline "$(make_json session=sess-pending)"
  assert_line2_contains "☑ 1/3"
  assert_line2_contains "Building the bundle"
}

@test "todos: task missing activeForm falls back to subject" {
  export CLAUDE_STATUSLINE_TODOS=on
  make_tasks "sess-nosubject" "1:in_progress:Run the build"
  run_statusline "$(make_json session=sess-nosubject)"
  assert_line2_contains "☑ 0/1"
  assert_line2_contains "Run the build"
}

@test "todos: malformed JSON in a task file hides segment but rest of line2 intact" {
  export CLAUDE_STATUSLINE_TODOS=on
  local dir="$HOME/.claude/tasks/sess-malformed"
  mkdir -p "$dir"
  printf '{not valid json' > "$dir/1.json"
  run_statusline "$(make_json session=sess-malformed cost=0.10)"
  assert_line2_not_contains "☑"
  assert_line2_contains "∑ˢ"
}

@test "todos: =counts mode never shows item text even on a wide terminal" {
  export CLAUDE_STATUSLINE_TODOS=counts
  export COLUMNS=200
  make_tasks "sess-counts" \
    "1:completed:Stage scripts:Staging scripts" \
    "2:in_progress:Run build:Building the bundle"
  run_statusline "$(make_json session=sess-counts)"
  assert_line2_contains "☑ 1/2"
  assert_line2_not_contains "Building the bundle"
}

@test "todos: TODO_MAXLEN truncates item text with an ellipsis" {
  export CLAUDE_STATUSLINE_TODOS=on
  export CLAUDE_STATUSLINE_TODO_MAXLEN=12
  make_tasks "sess-maxlen" "1:in_progress:Build:Building the converter bundle"
  run_statusline "$(make_json session=sess-maxlen)"
  assert_line2_contains "…"
  assert_line2_not_contains "Building the converter bundle"
}

@test "todos: invalid TODO_MAXLEN falls back to default of 32" {
  export CLAUDE_STATUSLINE_TODOS=on
  export CLAUDE_STATUSLINE_TODO_MAXLEN=abc
  make_tasks "sess-badmaxlen" "1:in_progress:Build:Short activeform"
  run_statusline "$(make_json session=sess-badmaxlen)"
  assert_line2_contains "Short activeform"
}

@test "todos: narrow terminal drops item text before dropping spend segment" {
  export CLAUDE_STATUSLINE_TODOS=on
  export COLUMNS=80
  make_tasks "sess-narrow1" "1:in_progress:Build:Building the converter bundle"
  inject_log_entry "/tmp" 0.10 5 "sess-narrow1"
  run_statusline "$(make_json session=sess-narrow1 cost=0.10)"
  assert_line2_contains "☑ 0/1"
  assert_line2_not_contains "Building the converter bundle"
  assert_line2_contains "💸"
}

@test "todos: very narrow terminal keeps counts and drops spend segment" {
  export CLAUDE_STATUSLINE_TODOS=on
  export COLUMNS=55
  make_tasks "sess-narrow2" "1:in_progress:Build:Building the converter bundle"
  inject_log_entry "/tmp" 0.10 5 "sess-narrow2"
  run_statusline "$(make_json session=sess-narrow2 cost=0.10)"
  assert_line2_contains "☑ 0/1"
  assert_line2_not_contains "💸"
}

@test "todos: segment appears after the perf dots and before the cost badge" {
  export CLAUDE_STATUSLINE_TODOS=on
  make_tasks "sess-position" "1:in_progress:Build:Building the bundle"
  run_statusline "$(make_json session=sess-position cost=0.42)"
  local stripped before_todo before_cost
  stripped="$(line2)"
  before_todo="${stripped%%☑*}"
  before_cost="${stripped%%∑ˢ*}"
  [ "${#before_todo}" -lt "${#before_cost}" ]
}

@test "todos: empty session_id hides the segment" {
  export CLAUDE_STATUSLINE_TODOS=on
  run_statusline "$(make_json session="")"
  assert_line2_not_contains "☑"
}
