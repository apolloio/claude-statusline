#!/usr/bin/env bats
# Installation helper tests. These run under a temporary HOME and never touch
# the developer's real ~/.claude directory.

setup() {
  export REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export INSTALL_HELPER="$REPO_ROOT/install.sh"
  export HOME="$BATS_TEST_TMPDIR/home"
  export MOCK_BIN="$BATS_TEST_TMPDIR/bin"
  export MOCK_DOWNLOAD="$BATS_TEST_TMPDIR/statusline-download.sh"
  export CLAUDE_STATUSLINE_INSTALL_URL="https://example.test/statusline-command.sh"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"

  cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      shift
      out="$1"
      ;;
  esac
  shift || true
done

[ -n "$out" ] || exit 2

if [ "${MOCK_CURL_EXIT:-0}" -ne 0 ]; then
  exit "$MOCK_CURL_EXIT"
fi

if [ "${MOCK_CURL_EMPTY:-0}" -eq 1 ]; then
  : > "$out"
else
  cp "$MOCK_DOWNLOAD" "$out"
fi
EOF
  chmod +x "$MOCK_BIN/curl"

  write_valid_download
}

write_valid_download() {
  cat > "$MOCK_DOWNLOAD" <<'EOF'
#!/usr/bin/env bash
printf 'statusline ok\n'
EOF
}

write_invalid_download() {
  cat > "$MOCK_DOWNLOAD" <<'EOF'
#!/usr/bin/env bash
if then
EOF
}

settings_value() {
  jq -r "$1" "$HOME/.claude/settings.json"
}

backup_count() {
  find "$HOME/.claude" -name 'settings.json.bak.*' -type f 2>/dev/null | wc -l | tr -d ' '
}

@test "install: missing claude directory and settings are created safely" {
  run bash "$INSTALL_HELPER"

  [ "$status" -eq 0 ]
  [ -x "$HOME/.claude/statusline-command.sh" ]
  [ "$(settings_value '.statusLine.type')" = "command" ]
  [ "$(settings_value '.statusLine.command')" = "bash ~/.claude/statusline-command.sh" ]
  [ "$(find "$HOME/.claude" -name '*.tmp.*' -type f | wc -l | tr -d ' ')" = "0" ]
}

@test "install: preserves unrelated settings keys and creates backup" {
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'EOF'
{
  "env": {
    "CLAUDE_STATUSLINE_COST_CURRENT": "off"
  },
  "permissions": {
    "allow": ["Bash(git status:*)"]
  }
}
EOF

  run bash "$INSTALL_HELPER"

  [ "$status" -eq 0 ]
  [ "$(settings_value '.env.CLAUDE_STATUSLINE_COST_CURRENT')" = "off" ]
  [ "$(settings_value '.permissions.allow[0]')" = "Bash(git status:*)" ]
  [ "$(backup_count)" = "1" ]
}

@test "install: rerun is idempotent with the same statusLine" {
  run bash "$INSTALL_HELPER"
  [ "$status" -eq 0 ]

  run bash "$INSTALL_HELPER"

  [ "$status" -eq 0 ]
  [ "$(settings_value '.statusLine.command')" = "bash ~/.claude/statusline-command.sh" ]
  [ "$(backup_count)" = "1" ]
}

@test "install: malformed existing settings JSON is rejected" {
  mkdir -p "$HOME/.claude"
  printf 'old script\n' > "$HOME/.claude/statusline-command.sh"
  printf '{not-json\n' > "$HOME/.claude/settings.json"

  run bash "$INSTALL_HELPER"

  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/.claude/statusline-command.sh")" = "old script" ]
  [ "$(cat "$HOME/.claude/settings.json")" = "{not-json" ]
}

@test "install: conflicting statusLine is refused without backup or overwrite" {
  mkdir -p "$HOME/.claude"
  printf 'old script\n' > "$HOME/.claude/statusline-command.sh"
  cat > "$HOME/.claude/settings.json" <<'EOF'
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/custom-statusline.sh"
  },
  "env": {
    "KEEP": "yes"
  }
}
EOF

  run bash "$INSTALL_HELPER"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to overwrite existing settings.json statusLine"* ]]
  [ "$(cat "$HOME/.claude/statusline-command.sh")" = "old script" ]
  [ "$(settings_value '.statusLine.command')" = "bash ~/.claude/custom-statusline.sh" ]
  [ "$(settings_value '.env.KEEP')" = "yes" ]
  [ "$(backup_count)" = "0" ]
}

@test "install: empty download does not replace existing script or settings" {
  mkdir -p "$HOME/.claude"
  printf 'old script\n' > "$HOME/.claude/statusline-command.sh"
  export MOCK_CURL_EMPTY=1

  run bash "$INSTALL_HELPER"

  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/.claude/statusline-command.sh")" = "old script" ]
  [ ! -e "$HOME/.claude/settings.json" ]
  [ "$(find "$HOME/.claude" -name '*.tmp.*' -type f | wc -l | tr -d ' ')" = "0" ]
}

@test "install: syntactically invalid download does not replace existing script or settings" {
  mkdir -p "$HOME/.claude"
  printf 'old script\n' > "$HOME/.claude/statusline-command.sh"
  write_invalid_download

  run bash "$INSTALL_HELPER"

  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/.claude/statusline-command.sh")" = "old script" ]
  [ ! -e "$HOME/.claude/settings.json" ]
  [ "$(find "$HOME/.claude" -name '*.tmp.*' -type f | wc -l | tr -d ' ')" = "0" ]
}
