#!/usr/bin/env bats
# Unit tests for _visible_len: ANSI-stripped display column measurement.
# The function is extracted from the main script so it can be tested in isolation.

load test_helper

# Call _visible_len from the main script in a subprocess.
vlen() {
  local func
  func=$(awk '/^# _visible_len str/,/^}$/' "$SCRIPT")
  bash -c "${func}"$'\n'"_visible_len \"\$1\"" -- "$1"
}

@test "visible_len: empty string returns 0" {
  result=$(vlen "")
  [ "$result" -eq 0 ]
}

@test "visible_len: plain ASCII counts one column per character" {
  result=$(vlen "hello")
  [ "$result" -eq 5 ]
}

@test "visible_len: 4-byte emoji counts as 2 columns" {
  result=$(vlen "💸")
  [ "$result" -eq 2 ]
}

@test "visible_len: multiple 4-byte emoji each count as 2 columns" {
  result=$(vlen "💸💰🔥")
  [ "$result" -eq 6 ]
}

@test "visible_len: 3-byte BMP symbol counts as 1 column" {
  # U+25CF BLACK CIRCLE — 3-byte UTF-8, BMP, single-wide
  result=$(vlen "●")
  [ "$result" -eq 1 ]
}

@test "visible_len: superscript letters count as 1 column each" {
  # ∑ˢ: U+2211 (3-byte) + U+02E2 (2-byte) — both single-wide BMP
  result=$(vlen "∑ˢ")
  [ "$result" -eq 2 ]
}

@test "visible_len: ANSI SGR escape sequences are stripped and not counted" {
  result=$(vlen $'\033[32mhello\033[0m')
  [ "$result" -eq 5 ]
}

@test "visible_len: ANSI bold + emoji combination" {
  # \033[1m = bold, 💸 = 2 cols, \033[0m = reset, ' hello' = 6 cols
  result=$(vlen $'\033[1m💸\033[0m hello')
  [ "$result" -eq 8 ]
}

@test "visible_len: mixed ASCII, BMP symbols, and emoji" {
  # ●(1) + A(1) + 💸(2) + B(1) = 5
  result=$(vlen "●A💸B")
  [ "$result" -eq 5 ]
}
