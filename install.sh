#!/usr/bin/env bash
set -euo pipefail

INSTALL_URL="${CLAUDE_STATUSLINE_INSTALL_URL:-https://raw.githubusercontent.com/apolloio/claude-statusline/main/statusline-command.sh}"
CLAUDE_DIR="${HOME}/.claude"
SCRIPT_DEST="${CLAUDE_DIR}/statusline-command.sh"
SETTINGS_DEST="${CLAUDE_DIR}/settings.json"
STATUSLINE_COMMAND='bash ~/.claude/statusline-command.sh'

tmp_script=""
tmp_settings=""

cleanup() {
  [ -n "$tmp_script" ] && [ -f "$tmp_script" ] && rm -f "$tmp_script"
  [ -n "$tmp_settings" ] && [ -f "$tmp_settings" ] && rm -f "$tmp_settings"
  return 0
}
trap cleanup EXIT HUP INT TERM

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required tool: %s\n' "$1" >&2
    exit 1
  fi
}

download_script() {
  tmp_script=$(mktemp "${SCRIPT_DEST}.tmp.XXXXXX")

  curl -fsSL -o "$tmp_script" "$INSTALL_URL"

  if [ ! -s "$tmp_script" ]; then
    printf 'Downloaded statusline script is empty: %s\n' "$INSTALL_URL" >&2
    exit 1
  fi

  bash -n "$tmp_script"
  chmod 755 "$tmp_script"
  mv -f "$tmp_script" "$SCRIPT_DEST"
  tmp_script=""
}

preflight_settings() {
  if [ -f "$SETTINGS_DEST" ]; then
    jq -e . "$SETTINGS_DEST" >/dev/null

    if ! jq -e --arg command "$STATUSLINE_COMMAND" \
      '(.statusLine == null) or (.statusLine == {"type":"command","command":$command})' \
      "$SETTINGS_DEST" >/dev/null; then
      printf 'Refusing to overwrite existing settings.json statusLine. Merge it manually.\n' >&2
      exit 1
    fi
  fi
}

update_settings() {
  local existing_source backup_path

  if [ -f "$SETTINGS_DEST" ]; then
    jq -e . "$SETTINGS_DEST" >/dev/null
    existing_source="$SETTINGS_DEST"
  else
    existing_source="/dev/null"
  fi

  tmp_settings=$(mktemp "${SETTINGS_DEST}.tmp.XXXXXX")
  if [ "$existing_source" = "/dev/null" ]; then
    printf '{}\n' | jq --arg command "$STATUSLINE_COMMAND" \
      '.statusLine = {"type":"command","command":$command}' > "$tmp_settings"
  else
    jq --arg command "$STATUSLINE_COMMAND" \
      '.statusLine = {"type":"command","command":$command}' \
      "$existing_source" > "$tmp_settings"
  fi

  jq -e . "$tmp_settings" >/dev/null

  if [ -f "$SETTINGS_DEST" ]; then
    backup_path="${SETTINGS_DEST}.bak.$(date +%Y%m%d%H%M%S).$$"
    cp -p "$SETTINGS_DEST" "$backup_path"
    printf 'Backed up existing settings to %s\n' "$backup_path"
  fi

  mv -f "$tmp_settings" "$SETTINGS_DEST"
  tmp_settings=""
}

main() {
  require_tool curl
  require_tool jq

  mkdir -p "$CLAUDE_DIR"
  preflight_settings
  download_script
  update_settings

  printf 'Installed %s\n' "$SCRIPT_DEST"
  printf 'Updated %s\n' "$SETTINGS_DEST"
}

main "$@"
