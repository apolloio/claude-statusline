#!/usr/bin/env bash
# statusline-command.sh — Claude Code custom statusline
# Phase 1: Line 1 (CWD, git branch, thinking, model, flags, context window)
# Phase 2: Cost badges + log infrastructure

# ── ANSI constants (§6) ────────────────────────────────────────────────────────
RESET=$'\033[0m'
DIM=$'\033[90m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
ORANGE=$'\033[38;5;208m'
RED=$'\033[31m'
BLUE=$'\033[34m'
MAGENTA=$'\033[35m'
BOLD=$'\033[1m'
STRIKETHROUGH=$'\033[9m'
DOT_GREEN=$'\033[38;5;82m'
DOT_YELLOW=$'\033[38;5;220m'
DOT_ORANGE=$'\033[38;5;208m'
DOT_RED=$'\033[38;5;196m'

# Rainbow gradient for the ultracode effort badge — one 256-color step per letter.
UC_RAINBOW=$'\033[38;5;196mu\033[38;5;208ml\033[38;5;220mt\033[38;5;190mr\033[38;5;82ma\033[38;5;51mc\033[38;5;33mo\033[38;5;99md\033[38;5;201me\033[0m'
DOT_GREY=$'\033[38;5;245m'
DIM_GREEN=$'\033[2;32m'          # ↑N ahead-of-upstream marker (§7.3.1)
DIM_ORANGE=$'\033[2;38;5;208m'   # ↓N behind-upstream marker (§7.3.1)
GIT_STAGED_COLOR="$GREEN"        # +N staged marker (§7.3.1)
GIT_UNTRACKED_COLOR="$DIM"       # ?N untracked marker (§7.3.1)

# ── Named thresholds ───────────────────────────────────────────────────────────
LOG_PRUNE_WINDOW=129600   # 36 hours in seconds
BASELINE_TTL=2592000      # 30 days in seconds
BUDGET_WARN_LO=0.925      # green/yellow threshold (within 7.5%)
BUDGET_WARN_HI=1.075      # yellow/red threshold (over 7.5%)
LOG_PRUNE_SIZE_MAX=262144  # ~256 KB; prune only when file exceeds this (§4.1)

SPACE=$'\xe2\x80\x8b'   # U+200B zero-width space — leads line 2
BRANCH_ICON='⎇'         # U+2387

# Detect the user's decimal separator with one locale process.
DECIMAL_POINT=.
while IFS= read -r _locale_line; do
  case "$_locale_line" in
    decimal_point=*)
      DECIMAL_POINT=${_locale_line#*=}
      DECIMAL_POINT=${DECIMAL_POINT#\"}; DECIMAL_POINT=${DECIMAL_POINT%\"}
      break ;;
  esac
done < <(locale -k LC_NUMERIC 2>/dev/null)
: "${DECIMAL_POINT:=.}"

# ── State file paths (§4) ──────────────────────────────────────────────────────
_CLAUDE_DIR="${CLAUDE_STATUSLINE_STATE_DIR:-$HOME/.claude}"
LOG_FILE="$_CLAUDE_DIR/statusline-global-usage-log.cache"
BASELINE_FILE="$_CLAUDE_DIR/statusline-session-baselines.tsv"

# Key ∑ⁱ's carry file to the owning `claude` process (walk the ppid chain, same
# idiom as _term_width_from_ancestor_pty) so a fresh instance never inherits
# another instance's accumulated carry. Key = <pid>-<lstart digits>; the start
# time guards against a recycled pid reattaching to a dead instance's file.
_instance_key() {
  if [ -n "$CLAUDE_STATUSLINE_INSTANCE_ID" ]; then
    _INSTANCE_KEY_RESULT="$CLAUDE_STATUSLINE_INSTANCE_ID"
    return
  fi
  local pid=$PPID ppid hop l1 l2 l3 l4 l5 comm key fallback="" stamp ch digits i
  for hop in 1 2 3 4; do
    read -r ppid l1 l2 l3 l4 l5 comm < <(ps -o ppid=,lstart=,comm= -p "$pid" 2>/dev/null)
    [ -z "$pid" ] || [ "$pid" = "0" ] && break
    stamp="$l1$l2$l3$l4$l5"; digits=""
    for ((i=0; i<${#stamp}; i++)); do ch=${stamp:i:1}; case "$ch" in [0-9]) digits+="$ch" ;; esac; done
    key="${pid}-${digits}"
    [ "$hop" = "1" ] && fallback="$key"
    [ "${comm##*/}" = "claude" ] && { _INSTANCE_KEY_RESULT="$key"; return; }
    pid=$ppid
  done
  _INSTANCE_KEY_RESULT="${fallback:-shared}"
}
_instance_key
CARRY_FILE="$_CLAUDE_DIR/statusline-instance-carry.${_INSTANCE_KEY_RESULT}.cache"
LOCK_DIR="$_CLAUDE_DIR/statusline-log.lock"
USAGE_CACHE_FILE="$_CLAUDE_DIR/statusline-usage-cache.json"
USAGE_FIELDS_FILE="$_CLAUDE_DIR/statusline-usage-fields.cache"
USAGE_RENDER_FILE="$_CLAUDE_DIR/statusline-usage-render.cache"
USAGE_FETCH_LOCK="$_CLAUDE_DIR/statusline-usage-fetch.lock"
RUNWAY_CACHE_FILE="$_CLAUDE_DIR/statusline-runway-allowances.cache"
SPEND_METRICS_FILE="$_CLAUDE_DIR/statusline-spend-metrics.cache"
AUTH_ERROR_FILE="$_CLAUDE_DIR/statusline-usage-fetch.error"
CACHE_TTL=300
LOCK_INFLIGHT_GRACE=60    # lock_age < this → fetch in flight → suppress ⚠️
FETCH_RETRY_COOLDOWN=120  # don't spawn a new fetch more often than this
LOCK_LEAK_TIMEOUT=600     # lock_age >= this → abandoned (sleep/reboot) → suppress ⚠️

# ── Read stdin with a Bash builtin ────────────────────────────────────────────
input=""
IFS= read -r -d '' input || :

# ── Field extraction (§2) — single jq pass, one field per line (bash 3.2 safe) ─
{
  IFS= read -r cwd
  IFS= read -r model_name
  IFS= read -r used_pct
  IFS= read -r window_size
  IFS= read -r fast_mode
  IFS= read -r effort_level
  IFS= read -r thinking_enabled
  IFS= read -r cost
  IFS= read -r session_id
  IFS= read -r transcript_path
  IFS= read -r version
} < <(jq -r '
    (.workspace.current_dir // .cwd // ""),
    (.model.display_name // ""),
    ((.context_window.used_percentage // "") | tostring),
    ((.context_window.context_window_size // "") | tostring),
    ((.fast_mode // "") | tostring),
    (.effort.level // ""),
    ((.thinking.enabled // "") | tostring),
    ((.cost.total_cost_usd // 0) | tostring),
    (.session_id // ""),
    (.transcript_path // ""),
    (.version // "2.1.76")
  ' <<< "$input" 2>/dev/null)
cost="${cost:-0}"
# awk-normalized cost: always "." decimal, 6dp — safe for bash printf %.6f in any locale
cost_6f=$(awk -v c="$cost" 'BEGIN{printf "%.6f", c+0}')

# ── Helpers ────────────────────────────────────────────────────────────────────

# workspace_hash(cwd) — SHA-256 of cwd, fallback cksum, fallback "empty" (§4.1)
workspace_hash() {
  local d="$1"
  if [ -z "$d" ]; then
    printf 'empty'; return
  fi
  local h
  if command -v shasum >/dev/null 2>&1; then
    read -r h _ < <(shasum -a 256 <<< "$d" 2>/dev/null)
  elif command -v sha256sum >/dev/null 2>&1; then
    read -r h _ < <(sha256sum <<< "$d" 2>/dev/null)
  fi
  if [ -z "$h" ] && command -v cksum >/dev/null 2>&1; then
    read -r h _ < <(cksum <<< "$d" 2>/dev/null)
  fi
  [ -n "$h" ] || h="empty"
  printf '%s' "$h"
}

# Stable, dependency-free hash for internal transcript cache filenames.
_path_hash() {
  local value=$1 hash=5381 i ch code
  for ((i=0; i<${#value}; i++)); do
    ch=${value:i:1}; printf -v code '%d' "'$ch"
    hash=$(( hash * 33 + code ))
  done
  if (( hash < 0 )); then _PATH_HASH_RESULT="n$(( -hash ))"; else _PATH_HASH_RESULT="p${hash}"; fi
}

# _mtime(path) — file mtime epoch (GNU stat first: -f on Linux means filesystem stat and exits 0
# with garbage output, so GNU -c %Y must come before BSD -f %m)
_mtime() {
  if [[ "$OSTYPE" == darwin* || "$OSTYPE" == *bsd* ]]; then stat -f %m "$1" 2>/dev/null || echo 0
  else stat -c %Y "$1" 2>/dev/null || echo 0
  fi
}

# _fsize(path) — file size in bytes (GNU -c %s first, BSD -f %z fallback)
_fsize() {
  if [[ "$OSTYPE" == darwin* || "$OSTYPE" == *bsd* ]]; then stat -f %z "$1" 2>/dev/null || echo 0
  else stat -c %s "$1" 2>/dev/null || echo 0
  fi
}

# _file_identity path → inode|high-resolution-mtime|size|epoch-mtime. Keep
# this together so cache keys need only one metadata snapshot and one stat.
_file_identity() {
  if [[ "$OSTYPE" == darwin* || "$OSTYPE" == *bsd* ]]; then
    stat -f '%i|%Fm|%z|%m' "$1" 2>/dev/null || printf '0|0|0|0\n'
  else
    stat -c '%i|%y|%s|%Y' "$1" 2>/dev/null || printf '0|0|0|0\n'
  fi
}

_pair_identity() {
  if [[ "$OSTYPE" == darwin* || "$OSTYPE" == *bsd* ]]; then
    stat -f '%i|%Fm|%z' "$1" "$2" 2>/dev/null
  else
    stat -c '%i|%y|%s' "$1" "$2" 2>/dev/null
  fi
}

# _transcript_raw_metrics reads complete JSONL records from stdin and prints
# hits, total, latency sum/count, final event and raw-substring ultracode state.
# The raw matching is intentional: it preserves the documented last-event-wins
# behaviour for attachment text without changing existing ultracode semantics.
_transcript_raw_metrics() {
  jq -Rrs '
    def role:
      if (.type == "user" or .type == "human") then "user"
      elif .type == "assistant" then "assistant"
      elif ((.message.role // .role // "") == "user" or (.message.role // .role // "") == "human") then "user"
      elif ((.message.role // .role // "") == "assistant") then "assistant"
      else null end;
    def number_ts:
      if type == "number" then .
      elif type == "string" then tonumber? else null end
      | if . == null then null else until(. <= 9999999999; . / 1000) end;
    def iso_ts:
      sub("\\.[0-9]+(?=(Z|[+-][0-9]{2}:[0-9]{2})$)"; "")
      | capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<zone>Z|(?<sign>[+-])(?<oh>[0-9]{2}):(?<om>[0-9]{2}))$")?
      | if . == null then null else
          (.base | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $base
          | if .zone == "Z" then $base else
              ((.oh|tonumber) * 3600 + (.om|tonumber) * 60) as $off
              | $base + (if .sign == "+" then -$off else $off end)
            end
        end;
    def ts:
      .timestamp as $t |
      if ($t == null or ($t|type) == "boolean") then null
      elif ($t|type) == "number" then ($t|number_ts)
      elif ($t|type) == "string" then
        (($t | iso_ts) // ($t|number_ts))
      elif ($t|type) == "object" then
        ($t.unix // $t.seconds // $t.sec // $t.time // $t.milliseconds // $t.ms // null | number_ts)
      else null end;
    . as $raw |
    ($raw | rindex("\n")) as $nl |
    (if $nl == null then "" else $raw[0:$nl + 1] end) as $complete |
    ($complete | split("\n")[:-1]) as $lines |
    [$lines[] | {raw: ., o: fromjson?} | select(.o != null)] as $rows |
    (reduce $rows[] as $r ({h:0,t:0};
      ($r.o.message.usage // $r.o.toolUseResult.usage // null) as $u |
      if $u == null then . else .h += ($u.cache_read_input_tokens // 0) | .t += (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)) end)) as $tokens |
    [$rows | to_entries[] | . as $e | ($e.value.o | role) as $r | ($e.value.o | ts) as $t | select($r != null and $t != null) | {r:$r,t:$t,i:$e.key}] | sort_by(.t,.i) as $events |
    (reduce $events[] as $e ({sum:0,n:0,prev:null};
      if (.prev != null and .prev.r == "user" and $e.r == "assistant") then
        ($e.t - .prev.t) as $d | if $d > 0 and $d < 86400 then .sum += $d | .n += 1 else . end
      else . end | .prev = $e)) as $lat |
    (reduce $rows[] as $r ({seen:0,state:0};
      if ($r.raw|contains("\"type\":\"ultra_effort_enter\"")) then {seen:1,state:1}
      elif ($r.raw|contains("\"type\":\"ultra_effort_exit\"")) then {seen:1,state:0}
      else . end)) as $uc |
    [ $tokens.h, $tokens.t, $lat.sum, $lat.n,
      ($events[0].t // "-"), ($events[0].r // "-"),
      ($lat.prev.t // "-"), ($lat.prev.r // "-"),
      $uc.seen, $uc.state, ($complete|utf8bytelength),
      (if $complete == "" then "-" else ($complete[-128:] | @base64) end),
      ($complete[-128:] | utf8bytelength) ] | @tsv
  ' 2>/dev/null
}

_base64_nowrap() {
  if [[ "$OSTYPE" == darwin* || "$OSTYPE" == *bsd* ]]; then base64 -b 0
  else base64 -w 0
  fi
}

# Shared, incremental transcript cache.  Cache payload is deliberately plain
# TSV for Bash 3.2 portability; line 1 is a schema/version guard.
_transcript_metrics() {
  local path="$1" need_cache="$2" need_latency="$3" inode mtime size key cache lock
  local v ci cm cs offset cv lv hits total lsum lcount last_ts last_role uc used
  local sh st ss sn first_ts first_role slast_ts slast_role useen suc consumed sig siglen old_sig old_siglen
  local rebuild=0 append=0 locked=0
  IFS='|' read -r inode mtime size _identity_epoch < <(_file_identity "$path")
  _path_hash "$path"; key=$_PATH_HASH_RESULT
  cache="$_CLAUDE_DIR/statusline-transcript-metrics.${key}.cache"
  lock="${cache}.lock"
  if [ -f "$cache" ]; then
    {
      IFS= read -r v; IFS= read -r ci; IFS= read -r cm; IFS= read -r cs; IFS= read -r offset
      IFS= read -r cv; IFS= read -r lv; IFS= read -r hits; IFS= read -r total
      IFS= read -r lsum; IFS= read -r lcount; IFS= read -r last_ts; IFS= read -r last_role
      IFS= read -r uc; IFS= read -r used; IFS= read -r sig; IFS= read -r siglen
    } < "$cache"
    if [ "$v" != "4" ] || [ "$ci" != "$inode" ] ||
       ! [[ "$cs" =~ ^[0-9]+$ && "$offset" =~ ^[0-9]+$ && "$hits" =~ ^[0-9]+([.][0-9]+)?$ && "$total" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
       ! [[ "$used" =~ ^[0-9]+$ ]] ||
       [ "$size" -lt "$offset" ] 2>/dev/null; then
      rebuild=1
    elif [ "$size" -eq "$cs" ] 2>/dev/null; then
      [ "$mtime" = "$cm" ] || rebuild=1
    else
      append=1
    fi
  else
    rebuild=1
  fi

  [ "$need_cache" = 1 ] && [ "${cv:-0}" != 1 ] && rebuild=1
  [ "$need_latency" = 1 ] && [ "${lv:-0}" != 1 ] && rebuild=1

  if [ "$rebuild" = 0 ] && [ "$append" = 0 ]; then
    if [ $(( NOW - used )) -ge 86400 ] 2>/dev/null && mkdir "$lock" 2>/dev/null; then
      _tm_tmp="$cache.$_TMP_TAG.tmp"
      printf '4\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$inode" "$mtime" "$size" "$offset" "$cv" "$lv" "$hits" "$total" "$lsum" "$lcount" "$last_ts" "$last_role" "$uc" "$NOW" "$sig" "$siglen" > "$_tm_tmp" && mv "$_tm_tmp" "$cache"
      rmdir "$lock" 2>/dev/null
    fi
    _TM_RESULT="$hits"$'\t'"$total"$'\t'"$lsum"$'\t'"$lcount"$'\t'"$uc"
    return
  fi

  if [ "$append" = 1 ] && [ "${siglen:-0}" -gt 0 ] 2>/dev/null; then
    _source_sig=$(dd if="$path" bs=1 skip=$(( offset - siglen )) count="$siglen" 2>/dev/null | _base64_nowrap)
    [ "$_source_sig" = "$sig" ] || { rebuild=1; append=0; }
  fi

  # Serialize updates briefly.  Contention never blocks the prompt: after two
  # attempts, compute a correct uncached result and leave the winner's cache alone.
  mkdir "$lock" 2>/dev/null && locked=1
  if [ "$locked" = 0 ]; then
    sleep 0.02
    mkdir "$lock" 2>/dev/null && locked=1
  fi
  if [ "$locked" = 0 ]; then
    IFS=$'\t' read -r hits total lsum lcount first_ts first_role last_ts last_role useen uc consumed sig siglen < <(_transcript_raw_metrics < "$path")
    _TM_RESULT="${hits:-0}"$'\t'"${total:-0}"$'\t'"${lsum:-0}"$'\t'"${lcount:-0}"$'\t'"${uc:-0}"
    return
  fi

  if [ "$append" = 1 ]; then
    old_sig=$sig; old_siglen=$siglen
    IFS=$'\t' read -r sh st ss sn first_ts first_role slast_ts slast_role useen suc consumed sig siglen < <(tail -c "+$(( offset + 1 ))" "$path" 2>/dev/null | _transcript_raw_metrics)
    : "${sh:=0}" "${st:=0}" "${ss:=0}" "${sn:=0}" "${useen:=0}" "${consumed:=0}"
    [ "$consumed" -gt 0 ] 2>/dev/null || { sig=$old_sig; siglen=$old_siglen; }
    if [ "$first_ts" != - ] && [ "$last_ts" != - ] && awk -v a="$first_ts" -v b="$last_ts" 'BEGIN{exit(a<b?0:1)}'; then
      rebuild=1
    else
      hits=$(awk -v a="$hits" -v b="$sh" 'BEGIN{print a+b}')
      total=$(awk -v a="$total" -v b="$st" 'BEGIN{print a+b}')
      lsum=$(awk -v a="$lsum" -v b="$ss" 'BEGIN{print a+b}')
      lcount=$(( ${lcount:-0} + ${sn:-0} ))
      if [ "$last_role" = user ] && [ "$first_role" = assistant ]; then
        _boundary=$(awk -v a="$first_ts" -v b="$last_ts" 'BEGIN{d=a-b; if(d>0&&d<86400) print d}')
        if [ -n "$_boundary" ]; then
          lsum=$(awk -v a="$lsum" -v b="$_boundary" 'BEGIN{print a+b}')
          lcount=$(( lcount + 1 ))
        fi
      fi
      [ "$slast_ts" != - ] && { last_ts="$slast_ts"; last_role="$slast_role"; }
      [ "$useen" = 1 ] && uc="$suc"
      offset=$(( offset + consumed ))
    fi
  fi
  if [ "$rebuild" = 1 ]; then
    IFS=$'\t' read -r hits total lsum lcount first_ts first_role last_ts last_role useen uc consumed sig siglen < <(_transcript_raw_metrics < "$path")
    offset=${consumed:-0}
  fi
  : "${hits:=0}" "${total:=0}" "${lsum:=0}" "${lcount:=0}" "${uc:=0}"
  cv=$(( ${cv:-0} || need_cache )); lv=$(( ${lv:-0} || need_latency ))
  _tm_tmp="$cache.$_TMP_TAG.tmp"
  printf '4\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$inode" "$mtime" "$size" "$offset" "$cv" "$lv" "$hits" "$total" "$lsum" "$lcount" "$last_ts" "$last_role" "$uc" "$NOW" "$sig" "$siglen" > "$_tm_tmp" && mv "$_tm_tmp" "$cache"
  rmdir "$lock" 2>/dev/null
  if [ "$need_cache" = 0 ]; then hits=0; total=0; fi
  if [ "$need_latency" = 0 ]; then lsum=0; lcount=0; fi
  _TM_RESULT="$hits"$'\t'"$total"$'\t'"$lsum"$'\t'"$lcount"$'\t'"$uc"
}

# _env_opt VAR_NAME default val1 val2 … — case-fold + validate env var (bash 3.2 safe)
_env_opt() {
  local _var="$1" _def="$2"; shift 2
  local val="${!_var:-$_def}" v
  shopt -s nocasematch
  for v in "$@"; do [[ "$val" == "$v" ]] && { _ENV_OPT_RESULT="$v"; return; }; done
  _ENV_OPT_RESULT="$_def"
}

# _fmt_money value [decimals=2] — locale-aware monetary format via integer math.
# Always emits $DECIMAL_POINT as separator; never calls locale-sensitive printf.
_fmt_money() {
  local v=$1 d=${2:-2}
  awk -v x="$v" -v d="$d" -v dp="$DECIMAL_POINT" 'BEGIN{
    mult = 1; for (i=0;i<d;i++) mult *= 10
    c = int(x*mult + (x>=0 ? 0.5 : -0.5))
    sign=""; if (c<0) { sign="-"; c=-c }
    if (d==0) { printf "%s%d", sign, c }
    else      { fmt = "%s%d%s%0" d "d"; printf fmt, sign, int(c/mult), dp, c%mult }
  }'
}

_fmt_money_pair() {
  awk -v a="$1" -v b="$2" -v dp="$DECIMAL_POINT" 'BEGIN {
    printf "%s\n%s\n", money(a), money(b)
  }
  function money(x, c) {
    c=int(x*100+0.5)
    return sprintf("%d%s%02d", int(c/100), dp, c%100)
  }'
}

# Fast formatter for non-negative, normalized rolling-window values.
_fmt_fixed_money() {
  local value=${1/,/.} decimals=${2:-2} whole frac round n
  whole=${value%%.*}; frac=${value#*.}
  [ "$frac" = "$value" ] && frac=""
  frac="${frac}000000"
  if [ "$decimals" = 0 ]; then
    n=$((10#${whole:-0})); [ "${frac:0:1}" -ge 5 ] && n=$((n+1))
    _MONEY_RESULT=$n
  else
    n=$((10#${frac:0:2})); [ "${frac:2:1}" -ge 5 ] && n=$((n+1))
    if [ "$n" -ge 100 ]; then whole=$((10#${whole:-0}+1)); n=0; fi
    printf -v round '%02d' "$n"
    _MONEY_RESULT="${whole:-0}${DECIMAL_POINT}${round}"
  fi
}

# _fmt_cents cents [decimals=2] — convert integer cents to USD string, locale-aware decimal point
_fmt_cents() {
  local c=$1 d=${2:-2}
  awk -v c="$c" -v d="$d" -v dp="$DECIMAL_POINT" 'BEGIN{
    sign=""; if (c<0){sign="-";c=-c}
    if (d==0) { printf "%s%d", sign, int(c/100 + 0.5) }
    else      { printf "%s%d%s%02d", sign, int(c/100), dp, c%100 }
  }'
}

# _cost_same(a, b) — exit 0 when |a-b| <= COST_EQ_THRESHOLD (§8.6 equality test)
_cost_same() {
  local a=${1/./} b=${2/./} d
  a=$((10#$a)); b=$((10#$b)); d=$(( a - b )); (( d < 0 )) && d=$(( -d ))
  [ "$d" -le 10000 ]
}

# _mid_ellipsis(str, target_len) — middle-ellipsis, tail-weighted 40/60 split
_mid_ellipsis() {
  local str="$1" target="$2"
  local slen="${#str}"
  if (( slen <= target )); then _FORMAT_RESULT="$str"; return; fi
  if (( target < 3 )); then _FORMAT_RESULT="${str:0:$target}"; return; fi
  local budget=$(( target - 1 ))   # 1 char for "…"
  local head=$(( budget * 4 / 10 ))
  (( head < 1 )) && head=1
  local tail=$(( budget - head ))
  local tail_start=$(( slen - tail ))
  _FORMAT_RESULT="${str:0:$head}…${str:$tail_start}"
}

# _shorten_path(str, max) — slash-aware shortener for CWD and branch names
_shorten_path() {
  local str="$1" max="$2"
  if (( ${#str} <= max )); then _FORMAT_RESULT="$str"; return; fi

  # Min-savings guard: a "…" insertion costs 1 char; if the string is
  # only a few chars over budget the ellipsized form is not worthwhile.
  if (( ${#str} - max < 5 )); then _FORMAT_RESULT="$str"; return; fi

  # Tokenize on '/'. Bash 3.2: read each segment individually.
  local IFS='/'
  local parts
  # shellcheck disable=SC2206
  parts=( $str )
  local n="${#parts[@]}"

  # Single segment (no slash): pure middle-ellipsis
  if (( n <= 1 )); then
    _mid_ellipsis "$str" "$max"
    return
  fi

  # Step 1: reduce all leading segments to 2 chars. Absolute paths (parts[0]="")
  # and home-relative paths (parts[0]="~") keep their root token verbatim;
  # branch-style prefixes ("feature", "sample-user", etc.) are always abbreviated.
  local i prefix
  if [[ -n "${parts[0]}" && "${parts[0]}" != "~" ]]; then
    prefix="${parts[0]:0:2}"
  else
    prefix="${parts[0]}"
  fi
  for (( i=1; i<n-1; i++ )); do
    prefix+="/${parts[$i]:0:2}"
  done
  local last="${parts[$((n-1))]}"
  local candidate="${prefix}/${last}"

  if (( ${#candidate} <= max )); then
    _FORMAT_RESULT="$candidate"
    return
  fi

  # Step 2: budget remaining space for last segment
  local prefix_len="${#prefix}"
  local last_budget=$(( max - prefix_len - 1 ))  # 1 for '/'

  # Step 2a: prefix-collapse fallback. If the last segment is short enough
  # to render almost in full with a collapsed "…/" prefix, and the
  # alternative mid-ellipsis would retain less than half of it, prefer the
  # cleaner form. May exceed max by up to 1 char.
  if (( last_budget >= 3 && ${#last} <= max - 1 && n <= 4 && (last_budget - 1) * 2 < ${#last} )); then
    _FORMAT_RESULT="…/${last}"
    return
  fi

  if (( last_budget >= 3 )); then
    _mid_ellipsis "$last" "$last_budget"
    _FORMAT_RESULT="${prefix}/${_FORMAT_RESULT}"
    return
  fi

  # Step 3: collapse middle intermediates to a single '…' token,
  # keeping the first and second-to-last intermediates visible (if there are enough)
  if (( n >= 4 )); then
    local first_inter="${parts[1]:0:2}"
    local second_to_last_inter="${parts[$((n-2))]:0:2}"
    local collapsed_prefix="${parts[0]}/${first_inter}/…/${second_to_last_inter}"
    local collapsed_budget=$(( max - ${#collapsed_prefix} - 1 ))
    if (( collapsed_budget >= 3 )); then
      _mid_ellipsis "$last" "$collapsed_budget"
      _FORMAT_RESULT="${collapsed_prefix}/${_FORMAT_RESULT}"
      return
    fi
    if (( collapsed_budget > 0 && ${#last} <= collapsed_budget )); then
      _FORMAT_RESULT="${collapsed_prefix}/${last}"
      return
    fi
  fi

  # Step 4: fallback — middle-ellipsis the whole string
  _mid_ellipsis "$str" "$max"
}

# Per-process temp file nonce — unique to this PID + random, prevents overlapping
# prune writes from corrupting the shared files (§4.1, §9).
_TMP_TAG="$$.$RANDOM"

# _acquire_lock / _release_lock — mkdir-based POSIX lock (§9)
LOCK_HELD=0
_acquire_lock() {
  local i=0 pid age mtime now
  while [ $i -lt 25 ]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%d' $$ > "$LOCK_DIR/pid"
      LOCK_HELD=1
      return 0
    fi
    if [ -f "$LOCK_DIR/pid" ]; then
      IFS= read -r pid < "$LOCK_DIR/pid" 2>/dev/null || pid=""
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        sleep 0.05
      else
        rm -rf "$LOCK_DIR" 2>/dev/null
      fi
    else
      now=$(date +%s)
      mtime=$(_mtime "$LOCK_DIR")
      age=$(( now - mtime ))
      if [ "$age" -gt 20 ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null
      else
        sleep 0.05
      fi
    fi
    i=$(( i + 1 ))
  done
  return 1
}

_release_lock() {
  if [ "$LOCK_HELD" -eq 1 ]; then
    rm -f "$LOCK_DIR/pid" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null
    LOCK_HELD=0
  fi
  # Clean up any stray per-process temp files from an aborted render
  rm -f "$_CLAUDE_DIR"/*."$_TMP_TAG".tmp 2>/dev/null
}

# §11: fmt_ctx_k(n) — format token count with optional k suffix
fmt_ctx_k() {
  local n=$1
  if [ "$n" -ge 1000 ] 2>/dev/null; then _FMT_CTX_RESULT="$(( (n + 500) / 1000 ))k"
  else _FMT_CTX_RESULT="${n:-0}"
  fi
}

# ── Persistent state (§4.1, §4.2) ─────────────────────────────────────────────
NOW=$(date +%s)
[ -z "$session_id" ] && session_id="anon"
mkdir -p "$_CLAUDE_DIR"

# Carry lines 1-3 are the original public format.  Lines 4-8 are a lazy,
# backward-compatible hot-path cache for the baseline and log metadata.
_cf_sid="" _cf_pcost="" _cf_carry="0" _cf_baseline="" _cf_touch="0"
_cf_log_time="0" _cf_cwd="" _cf_ws_hash=""
_first_instance_render=0
if [ -f "$CARRY_FILE" ]; then
  {
    IFS= read -r _cf_sid; IFS= read -r _cf_pcost; IFS= read -r _cf_carry
    IFS= read -r _cf_baseline; IFS= read -r _cf_touch; IFS= read -r _cf_log_time
    IFS= read -r _cf_cwd; IFS= read -r _cf_ws_hash
  } < "$CARRY_FILE"
else
  _first_instance_render=1
fi
: "${_cf_carry:=0}" "${_cf_touch:=0}" "${_cf_log_time:=0}"

baseline_cost="$cost"
_baseline_due=1
if [ "$_cf_sid" = "$session_id" ] && [ -n "$_cf_baseline" ]; then
  baseline_cost="$_cf_baseline"
  _baseline_due=0
  [ $(( NOW - _cf_touch )) -ge 86400 ] 2>/dev/null && _baseline_due=1
fi

_log_due=0
[ "$_cf_sid" != "$session_id" ] && _log_due=1
[ "$_cf_pcost" != "$cost_6f" ] && _log_due=1
[ "$_cf_cwd" != "$cwd" ] && _log_due=1
[ $(( NOW - _cf_log_time )) -ge 300 ] 2>/dev/null && _log_due=1
ws_hash="$_cf_ws_hash"

if { [ "$_baseline_due" = 1 ] || [ "$_log_due" = 1 ]; } && _acquire_lock; then
  trap _release_lock EXIT

  # ── Session baseline upsert (§4.2) ─────────────────────────────────────────
  if [ "$_baseline_due" = 1 ]; then
    existing_baseline=""
    [ -f "$BASELINE_FILE" ] && existing_baseline=$(awk -F'\t' -v sid="$session_id" '$1==sid{print $2;exit}' "$BASELINE_FILE")
    cutoff_30d=$(( NOW - BASELINE_TTL ))
    _bt="$BASELINE_FILE.$_TMP_TAG.tmp"
    if [ -n "$existing_baseline" ]; then
      baseline_cost="$existing_baseline"
      if awk -F'\t' -v OFS='\t' -v sid="$session_id" -v now="$NOW" -v cutoff="$cutoff_30d" '
        $1==sid { $4=now }
        $4+0 >= cutoff { print }
      ' "$BASELINE_FILE" > "$_bt" && [ -s "$_bt" ]; then mv "$_bt" "$BASELINE_FILE"; else rm -f "$_bt"; fi
    else
      baseline_cost="$cost"
      if [ -f "$BASELINE_FILE" ]; then
        awk -F'\t' -v cutoff="$cutoff_30d" '$4+0 >= cutoff' "$BASELINE_FILE" > "$_bt" || :
        printf '%s\t%s\t%d\t%d\n' "$session_id" "$cost_6f" "$NOW" "$NOW" >> "$_bt"
        mv "$_bt" "$BASELINE_FILE"
      else
        printf '%s\t%s\t%d\t%d\n' "$session_id" "$cost_6f" "$NOW" "$NOW" > "$BASELINE_FILE"
      fi
    fi
    _cf_touch="$NOW"
  fi

  # ── Global usage log append + prune (§4.1) ─────────────────────────────────
  if [ "$_log_due" = 1 ]; then
    if [ "$cwd" != "$_cf_cwd" ] || [ -z "$ws_hash" ]; then
      ws_hash=$(workspace_hash "$cwd")
    fi
    printf '%d %s %s %s\n' "$NOW" "$session_id" "$cost_6f" "$ws_hash" >> "$LOG_FILE"
    _cf_log_time="$NOW"
  fi

  if [ "$_log_due" = 1 ] && [ "$(_fsize "$LOG_FILE")" -gt "$LOG_PRUNE_SIZE_MAX" ]; then
    _lt="$LOG_FILE.$_TMP_TAG.tmp"
    cutoff_36h=$(( NOW - LOG_PRUNE_WINDOW ))
    if awk -v cutoff="$cutoff_36h" '
      NF >= 4 {
        t = $1 + 0; sid = $2
        if (t >= cutoff) {
          recent[++nr] = $0
        } else if (!(sid in anc_t) || t > anc_t[sid]) {
          anc_t[sid] = t; anc_row[sid] = $0
        }
      }
      END {
        for (sid in anc_row) print anc_row[sid]
        for (i = 1; i <= nr; i++) print recent[i]
      }
    ' "$LOG_FILE" | sort -n > "$_lt" && [ -s "$_lt" ]; then mv "$_lt" "$LOG_FILE"; else rm -f "$_lt"; fi
  fi

  _release_lock
fi

# ── Cost pair computation (§8.6) ──────────────────────────────────────────────
session_cost=$(awk -v inst="$cost" -v base="$baseline_cost" \
  'BEGIN { s = inst - base; printf "%.6f", (s > 0 ? s : 0) }')

# ── Instance carry (∑ⁱ across /clear resets) ──────────────────────────────────
# Claude Code resets cost.total_cost_usd to 0 at /clear while generating a new
# session_id. We detect this (session change or cost decrease) and accumulate the
# pre-/clear cost so ∑ⁱ reflects total spend across all /clears this process.
instance_carry=0
if [ "$_first_instance_render" = 0 ]; then
  if [ "$_cf_sid" = "$session_id" ] && \
     awk -v c="$cost_6f" -v p="${_cf_pcost:-0}" 'BEGIN{exit (c+0 >= p+0 - 0.001 ? 0 : 1)}'; then
    instance_carry="${_cf_carry:-0}"
  else
    instance_carry=$(awk -v carry="${_cf_carry:-0}" -v pcost="${_cf_pcost:-0}" \
      'BEGIN{printf "%.6f", carry+0 + pcost+0}')
  fi
else
  # First render for this instance: reap dead instances' carry files and the
  # pre-fix global one (which caused stale carry to leak across instances).
  find "$_CLAUDE_DIR" -maxdepth 1 -name 'statusline-instance-carry.*.cache' -mtime +1 -delete 2>/dev/null
  find "$_CLAUDE_DIR" -maxdepth 1 -name 'statusline-transcript-metrics.*.cache' -mtime +7 -delete 2>/dev/null
  rm -f "$_CLAUDE_DIR/statusline-instance-carry.cache"
fi
printf -v _carry_new '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' "$session_id" "$cost_6f" "$instance_carry" "$baseline_cost" "$_cf_touch" "$_cf_log_time" "$cwd" "$ws_hash"
_carry_old=""
[ -f "$CARRY_FILE" ] && _carry_old=$(<"$CARRY_FILE")
[ "$_carry_new" = "$_carry_old" ] || printf '%s\n' "$_carry_new" > "$CARRY_FILE"
instance_cost=$(awk -v carry="$instance_carry" -v sess="$session_cost" \
  'BEGIN{printf "%.6f", carry+0 + sess+0}')

_env_opt CLAUDE_STATUSLINE_COST_CURRENT on on session instance off; cost_mode=$_ENV_OPT_RESULT
_env_opt CLAUDE_STATUSLINE_COST_LOADAVG on on spent_only off; loadavg_mode=$_ENV_OPT_RESULT
_env_opt CLAUDE_STATUSLINE_ULTRACODE on on off; ultracode_mode=$_ENV_OPT_RESULT
_env_opt CLAUDE_STATUSLINE_BUDGET_SIGN_MODE neutral neutral used_minus remaining_plus both; sign_mode=$_ENV_OPT_RESULT
_env_opt CLAUDE_STATUSLINE_SHOW_PACE_RATIO on on off; show_pace_ratio=$_ENV_OPT_RESULT
_env_opt CLAUDE_STATUSLINE_GIT_STATUS off off dirty on; git_status_mode=$_ENV_OPT_RESULT
_env_opt CLAUDE_STATUSLINE_GIT_UNTRACKED on on off; git_untracked_mode=$_ENV_OPT_RESULT
_env_opt CLAUDE_STATUSLINE_PERF_BADGE on on off cache_only latency_only; perf_mode=$_ENV_OPT_RESULT

hours_per_day="${CLAUDE_STATUSLINE_BUDGET_HOURS_PER_DAY:-6}"
awk -v h="$hours_per_day" 'BEGIN { exit (h+0 > 0 ? 0 : 1) }' </dev/null 2>/dev/null || hours_per_day=6

work_days_str=""
_work_days_raw=${CLAUDE_STATUSLINE_BUDGET_WORK_DAYS:-12345}
for (( _wd_i=0; _wd_i<${#_work_days_raw}; _wd_i++ )); do
  _wd_ch=${_work_days_raw:_wd_i:1}
  case "$_wd_ch" in [1-7]) work_days_str+="$_wd_ch" ;; esac
done
[ -z "$work_days_str" ] && work_days_str="12345"

holidays_raw="${CLAUDE_STATUSLINE_BUDGET_HOLIDAYS:-}"
extra_preview_pct="${CLAUDE_STATUSLINE_EXTRA_PREVIEW_PCT:-75}"

cost_seg=""
if [ "$cost_mode" != "off" ]; then
  { IFS= read -r inst_fmt; IFS= read -r sess_fmt; } < <(_fmt_money_pair "$instance_cost" "$session_cost")
  if [ "$cost_mode" = "instance" ]; then
    cost_seg="${RESET}${BLUE}${BOLD}∑ⁱ\$${inst_fmt}${RESET}"
  else
    cost_seg="${RESET}${BLUE}${BOLD}∑ˢ\$${sess_fmt}${RESET}"
    if [ "$cost_mode" = "on" ] && ! _cost_same "$session_cost" "$instance_cost"; then
      cost_seg+=" ${DIM}∑ⁱ\$${inst_fmt}${RESET}"
    fi
  fi
fi

# ── Rolling window helpers (§8.7) ─────────────────────────────────────────────

# _local_day_start — epoch of local 00:00 today (SPEC §8.7 fallback chain)
# _DAY_START is computed once below after function definition and reused throughout.
_local_day_start() {
  local ymd ds
  ymd=$(date +%F)
  ds=$(date -jf "%Y-%m-%d %H:%M:%S" "$ymd 00:00:00" +%s 2>/dev/null)
  [ -n "$ds" ] && { printf '%s' "$ds"; return; }
  ds=$(date -d "$ymd 00:00:00" +%s 2>/dev/null)
  [ -n "$ds" ] && { printf '%s' "$ds"; return; }
  ds=$(date -r "$NOW" -v0H -v0M -v0S +%s 2>/dev/null)
  [ -n "$ds" ] && { printf '%s' "$ds"; return; }
  printf '%d' $(( NOW - 86400 ))
}

# _DAY_START — epoch of local midnight, computed once and reused
_DAY_START=$(_local_day_start)

# calc_spent_all — emit: s15 s1h s1d nd15 nd1h nd1d  (SPEC §8.7 + §4.1 filtering)
calc_spent_all() {
  local day_start="${_DAY_START:-$(_local_day_start)}"
  local day_gated=0
  [ $(( NOW - 3600 )) -ge "$day_start" ] && day_gated=1
  local bfile="$BASELINE_FILE"
  [ -f "$bfile" ] || bfile=/dev/null
  awk -v now="$NOW" -v cur_sid="$session_id" -v cost_now="$cost" -v day_start="$day_start" -v day_gated="$day_gated" -v bfile="$bfile" '
    BEGIN {
      cut15 = now - 900
      cut1h = now - 3600
      cut1d = day_start
      split("15m 1h 1d", wins, " ")
      nsess = 0
    }
    FILENAME == bfile { if (NF >= 3) { bbase[$1] = $2 + 0; bfirst[$1] = $3 + 0 } next }
    NF < 4 { next }
    {
      t = $1 + 0; sid = $2; c = $3 + 0
      age = now - t; elig = (age >= 5)
      if (!(sid in sess_seen)) { sessions[++nsess] = sid; sess_seen[sid] = 1 }
      if (t > sess_latest_t[sid]) { sess_latest_t[sid] = t; sess_cur[sid] = c }
      if (elig) total_rows++
      for (i = 1; i <= 3; i++) {
        k = wins[i]
        cutoff = (k == "15m") ? cut15 : (k == "1h") ? cut1h : cut1d
        key = sid SUBSEP k
        if (t >= cutoff) {
          if (elig) {
            rows[k]++
            if (!(key in win_t) || t < win_t[key]) { win_t[key] = t; win_c[key] = c }
          }
        } else {
          if (elig && (!(key in anc_t) || t > anc_t[key])) { anc_t[key] = t; anc_c[key] = c; has_anc[k] = 1 }
        }
      }
    }
    END {
      if (!(cur_sid in sess_seen)) { sessions[++nsess] = cur_sid; sess_seen[cur_sid] = 1 }
      sess_cur[cur_sid] = cost_now
      for (i = 1; i <= 3; i++) {
        k = wins[i]; total = 0
        for (s = 1; s <= nsess; s++) {
          sid = sessions[s]; scur = sess_cur[sid]; key = sid SUBSEP k
          if (key in win_t) ref = win_c[key]
          else if (key in anc_t) ref = anc_c[key]
          else ref = scur
          if (k == "1d" && (sid in bfirst) && bfirst[sid] >= day_start \
              && (sid in bbase) && bbase[sid] < ref) ref = bbase[sid]
          delta = scur - ref; if (delta < 0) delta = 0
          total += delta
        }
        spent[k] = total
        nodata[k] = (rows[k] == 0 && !has_anc[k] && cost_now == 0) ? 1 : 0
      }
      s15 = spent["15m"]; s1h = spent["1h"]; s1d = spent["1d"]
      if (s1h < s15) s1h = s15
      if (day_gated && s1d < s1h) s1d = s1h
      printf "%.6f %.6f %.6f %d %d %d\n", s15, s1h, s1d, nodata["15m"], nodata["1h"], nodata["1d"]
    }
  ' "$bfile" "$LOG_FILE" 2>/dev/null || printf '0.000000 0.000000 0.000000 0 0 0\n'
}

# _roll_slot label spent nodata [sign_mode] [allowance] [budget_color]
# Renders one rolling-window slot with optional sign mode and allowance suffix.
# allowance="" means no suffix; budget_color defaults to no color when empty.
_roll_slot() {
  local label="$1" spent="$2" nodata="$3"
  local smode="${4:-neutral}" allowance="${5:-}" bcolor="${6:-}"
  local allow_sfx=""
  if [ -n "$allowance" ]; then
    _fmt_fixed_money "$allowance" 0
    allow_sfx="/${DIM}\$${_MONEY_RESULT}${RESET}"
  fi
  if [ "$nodata" = "1" ]; then
    _ROLL_SLOT_RESULT="${label}:${DIM}—${RESET}${allow_sfx}"
    return
  fi
  local remaining=""
  [ -n "$allowance" ] && remaining=$(_fmt_money \
    "$(awk -v a="$allowance" -v s="$spent" 'BEGIN{ r=a-s; print (r>0?r:0) }')")
  local out="${label}:" spent_fmt
  _fmt_fixed_money "$spent"; spent_fmt=$_MONEY_RESULT
  case "$smode" in
    used_minus)
      if [ "$spent" != 0 ] && [ "$spent" != 0.000000 ]; then
        out+="${bcolor}-\$${spent_fmt}${RESET}"
      else
        out+="\$${spent_fmt}"
      fi
      out+="${allow_sfx}" ;;
    remaining_plus)
      if [ -n "$remaining" ]; then
        out+="${bcolor}+\$${remaining}${RESET}${allow_sfx}"
      else
        out+="\$${spent_fmt}"
      fi ;;
    both)
      out+="${bcolor}-\$${spent_fmt}${RESET}"
      if [ -n "$remaining" ]; then
        out+="/${bcolor}+\$${remaining}${RESET}"
      fi
      out+="${allow_sfx}" ;;
    *)
      if [ -n "$bcolor" ]; then
        out+="${bcolor}\$${spent_fmt}${RESET}${allow_sfx}"
      else
        out+="${DIM}\$${spent_fmt}${RESET}${allow_sfx}"
      fi ;;
  esac
  _ROLL_SLOT_RESULT="$out"
}

# ── Line 1 display budget (§7.2, §7.3) ───────────────────────────────────────
_DEFAULT_CWD_MAXLEN=64
_DEFAULT_BRANCH_MAXLEN=64
_MAXLEN_MIN=8        # minimum accepted env var value; below this falls back to default
_TERM_W_MIN=88       # floor: narrower terminals are treated as this wide
_TERM_W_FALLBACK=220 # used when no tty is detectable; wide assumption avoids false compression

# Env var ceilings for CWD and branch display lengths (validated: integer >= _MAXLEN_MIN)
_CWD_MAXLEN_raw="${CLAUDE_STATUSLINE_CWD_MAXLEN:-$_DEFAULT_CWD_MAXLEN}"
_BRANCH_MAXLEN_raw="${CLAUDE_STATUSLINE_BRANCH_MAXLEN:-$_DEFAULT_BRANCH_MAXLEN}"
case "$_CWD_MAXLEN_raw" in (*[!0-9]*|'') _CWD_MAXLEN=$_DEFAULT_CWD_MAXLEN ;; (*) _CWD_MAXLEN=$_CWD_MAXLEN_raw ;; esac
[ "$_CWD_MAXLEN" -ge "$_MAXLEN_MIN" ] || _CWD_MAXLEN=$_DEFAULT_CWD_MAXLEN
case "$_BRANCH_MAXLEN_raw" in (*[!0-9]*|'') _BRANCH_MAXLEN=$_DEFAULT_BRANCH_MAXLEN ;; (*) _BRANCH_MAXLEN=$_BRANCH_MAXLEN_raw ;; esac
[ "$_BRANCH_MAXLEN" -ge "$_MAXLEN_MIN" ] || _BRANCH_MAXLEN=$_DEFAULT_BRANCH_MAXLEN

# Terminal width with floor. stdin is the JSON payload (not a tty).
# Detection chain:
#   1. $COLUMNS — set by Claude Code ≥ 2.1.153 when spawning the statusline subprocess.
#      Also honored when set by the user's shell or a wrapper (manual override).
#   2. /dev/tty  — the controlling terminal; fails in Claude Code (no controlling tty).
#   3. stderr fd — only if [ -t 2 ] confirms it's a real tty; tput returns 80 as its
#      own fallback when given a non-tty fd, indistinguishable from a real 80-col terminal.
#   4. Ancestor PTY walk — fallback for Claude Code < 2.1.153: walks up the ppid chain
#      (max 8 hops) to find an ancestor with a real PTY, then queries it via
#      `stty -f /dev/$tty size` (macOS) or `stty -F /dev/$tty size` (Linux). The -f/-F
#      flag is required — `stty size < /dev/$tty` returns ENOTTY under Claude Code ≥ 2.1.139.
#   5. _TERM_W_FALLBACK — wide value so undetected width does not cause false compression.
_term_width_from_ancestor_pty() {
  local pid=$$ ppid
  local tty w _rows _depth
  for _depth in 1 2 3 4 5 6 7 8; do
    read -r ppid tty < <(ps -o ppid=,tty= -p "$pid" 2>/dev/null)
    pid=$ppid
    [ -z "$pid" ] || [ "$pid" = "0" ] || [ "$pid" = "1" ] && return 1
    [ -z "$tty" ] || [ "$tty" = "??" ] || [ "$tty" = "?" ] && continue
    # Try macOS BSD stty (-f), then Linux GNU stty (-F), then redirect fallback
    read -r _rows w < <(stty -f "/dev/$tty" size 2>/dev/null) \
      || read -r _rows w < <(stty -F "/dev/$tty" size 2>/dev/null) \
      || read -r _rows w < <(stty size < "/dev/$tty" 2>/dev/null)
    if [ -n "$w" ] && [ "$w" -gt 0 ] 2>/dev/null; then
      printf '%s' "$w"; return 0
    fi
  done
  return 1
}

_TERM_W=${COLUMNS:-}
if [ -z "$_TERM_W" ]; then
  if _w=$( (tput cols </dev/tty) 2>/dev/null ) && [ -n "$_w" ]; then
    _TERM_W=$_w
  elif [ -t 2 ] && _w=$(tput cols <&2 2>/dev/null) && [ -n "$_w" ]; then
    _TERM_W=$_w
  elif _w=$(_term_width_from_ancestor_pty) && [ -n "$_w" ]; then
    _TERM_W=$_w
  else
    _TERM_W=$_TERM_W_FALLBACK
  fi
fi


_TERM_W_RAW=$_TERM_W   # save pre-floor value for line 2 adaptive truncation
(( _TERM_W < _TERM_W_MIN )) && _TERM_W=$_TERM_W_MIN

# Ultracode detection. `/effort ultracode` never reaches us as its own value: Claude Code
# normalizes it internally ({ultracode:"xhigh"}), so effort.level arrives as plain "xhigh".
# The only observable signal is the ultra_effort_enter / ultra_effort_exit attachment pair
# in the transcript — an enter/exit state machine where the last event wins.
# Ultracode implies xhigh, so a non-xhigh level rules it out — that guard both kills false
# positives (attachments lag a prompt behind a level change) and skips the scan entirely for
# every other effort level.
# ponytail: raw substring match, not a JSON parse — awk over the file is far cheaper than jq
# and this runs on every render. Two known ceilings: (1) a message quoting the literal
# attachment-type text is a false positive, (2) attachments are only written when the next
# user prompt is built, so a fresh toggle shows up one prompt late. Switch to a jq pass on
# .attachment.type if either bites.
_ultracode=0
_tm_cache=0 _tm_latency=0 _tm_need_uc=0
case "$perf_mode" in on) _tm_cache=1; _tm_latency=1 ;; cache_only) _tm_cache=1 ;; latency_only) _tm_latency=1 ;; esac
[ "$ultracode_mode" != "off" ] && [ "$effort_level" = "xhigh" ] && _tm_need_uc=1
if { [ "$_tm_cache" = 1 ] || [ "$_tm_latency" = 1 ] || [ "$_tm_need_uc" = 1 ]; } && [ -r "$transcript_path" ]; then
  _transcript_metrics "$transcript_path" "$_tm_cache" "$_tm_latency"
  IFS=$'\t' read -r _tm_hits _tm_total _tm_sum _tm_count _tm_uc <<< "$_TM_RESULT"
  [ "$_tm_need_uc" = 1 ] && [ "$_tm_uc" = 1 ] && _ultracode=1
fi

# Estimate chars consumed by fixed elements (model, effort, fast, thinking, ctx, leading space).
# Branch separator " ⎇ " (3 chars) is excluded here — it's subtracted separately in the cwd budget.
_thinking_chars=0; [ "$thinking_enabled" = "true" ] && _thinking_chars=3
_effort_chars=0;   [ -n "$effort_level" ] && _effort_chars=2
# Ultracode renders as the rainbow word "ultracode" rather than a single glyph.
[ "$_ultracode" = "1" ] && _effort_chars=10
_fast_chars=0;     [ "$fast_mode" = "true" ] && _fast_chars=2
_model_chars=0;    [ -n "$model_name" ] && _model_chars=$(( 1 + ${#model_name} ))
# 1=leading space, 20=ctx segment worst-case " ctx:200k/200k≈100%"
_fixed_overhead=$(( 1 + _thinking_chars + _model_chars + _effort_chars + _fast_chars + 20 ))

_combined_budget=$(( _TERM_W - _fixed_overhead ))
(( _combined_budget < 20 )) && _combined_budget=20

# Branch gets priority: ~55% of combined, capped by ceiling
_branch_budget=$(( _combined_budget * 55 / 100 ))
(( _branch_budget > _BRANCH_MAXLEN )) && _branch_budget=$_BRANCH_MAXLEN
(( _branch_budget < 8 )) && _branch_budget=8

# Resolve branch early so CWD gets the actual remaining space, not a worst-case proxy.
_branch_disp=""
if [ -n "$cwd" ]; then
  _branch_raw=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ "$_branch_raw" = HEAD ] && _branch_raw=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  if [ -n "$_branch_raw" ]; then _shorten_path "$_branch_raw" "$_branch_budget"; _branch_disp=$_FORMAT_RESULT; fi
fi

# §7.3.1 Git status markers (opt-in via CLAUDE_STATUSLINE_GIT_STATUS, off by default —
# adds a `git status` + awk fork only when enabled).
_git_status_suffix=""
_git_status_suffix_width=0
if [ -n "$_branch_disp" ] && [ "$git_status_mode" != "off" ]; then
  _ut_flag="--untracked-files=normal"
  [ "$git_untracked_mode" = "off" ] && _ut_flag="--untracked-files=no"
  _gs_out=$(git -C "$cwd" --no-optional-locks status --porcelain=v1 --branch $_ut_flag 2>/dev/null)
  if [ -n "$_gs_out" ]; then
    { IFS= read -r _gs_staged; IFS= read -r _gs_unstaged; IFS= read -r _gs_untracked; IFS= read -r _gs_ahead; IFS= read -r _gs_behind; } < <(
      awk '
        /^## / {
          if (match($0, /ahead [0-9]+/))  { a = substr($0, RSTART + 6, RLENGTH - 6) }
          if (match($0, /behind [0-9]+/)) { b = substr($0, RSTART + 7, RLENGTH - 7) }
          next
        }
        /^\?\? / { u++; next }
        { if (substr($0, 1, 1) != " ") s++; if (substr($0, 2, 1) != " ") m++ }
        END { print s+0; print m+0; print u+0; print a+0; print b+0 }
      ' <<< "$_gs_out"
    )
    _dirty_mark=""
    if [ "${_gs_staged:-0}" -gt 0 ]; then
      _dirty_mark+="${GIT_STAGED_COLOR}+${_gs_staged}${RESET}"
      _git_status_suffix_width=$(( _git_status_suffix_width + 1 + ${#_gs_staged} ))
    fi
    if [ "${_gs_unstaged:-0}" -gt 0 ]; then
      [ -n "$_dirty_mark" ] && { _dirty_mark+=" "; _git_status_suffix_width=$(( _git_status_suffix_width + 1 )); }
      _dirty_mark+="${YELLOW}!${_gs_unstaged}${RESET}"
      _git_status_suffix_width=$(( _git_status_suffix_width + 1 + ${#_gs_unstaged} ))
    fi
    if [ "$git_untracked_mode" != "off" ] && [ "${_gs_untracked:-0}" -gt 0 ]; then
      [ -n "$_dirty_mark" ] && { _dirty_mark+=" "; _git_status_suffix_width=$(( _git_status_suffix_width + 1 )); }
      _dirty_mark+="${GIT_UNTRACKED_COLOR}?${_gs_untracked}${RESET}"
      _git_status_suffix_width=$(( _git_status_suffix_width + 1 + ${#_gs_untracked} ))
    fi
    if [ -n "$_dirty_mark" ]; then
      _git_status_suffix+=" ${_dirty_mark}"
      _git_status_suffix_width=$(( _git_status_suffix_width + 1 ))
    fi
    if [ "$git_status_mode" = "on" ]; then
      _git_arrows=""
      if [ "${_gs_ahead:-0}" -gt 0 ]; then
        _git_arrows+="${DIM_GREEN}↑${_gs_ahead}${RESET}"
        _git_status_suffix_width=$(( _git_status_suffix_width + 1 + ${#_gs_ahead} ))
      fi
      if [ "${_gs_behind:-0}" -gt 0 ]; then
        _git_arrows+="${DIM_ORANGE}↓${_gs_behind}${RESET}"
        _git_status_suffix_width=$(( _git_status_suffix_width + 1 + ${#_gs_behind} ))
      fi
      if [ -n "$_git_arrows" ]; then
        _git_status_suffix+=" ${_git_arrows}"
        _git_status_suffix_width=$(( _git_status_suffix_width + 1 ))
      fi
    fi
  fi
fi

# CWD budget: subtract actual branch display length (not its ceiling) + 3 for " ⎇ " separator,
# plus the visible width of any git status marker suffix.
if [ -n "$_branch_disp" ]; then
  _cwd_budget=$(( _combined_budget - ${#_branch_disp} - 3 - _git_status_suffix_width ))
else
  _cwd_budget=$_combined_budget
fi
(( _cwd_budget < 8 )) && _cwd_budget=8
(( _cwd_budget > _CWD_MAXLEN )) && _cwd_budget=$_CWD_MAXLEN

# ── Line 1 assembly ────────────────────────────────────────────────────────────
line1=" ${RESET}"

# §7.2 CWD segment (yellow)
if [ -n "$cwd" ]; then
  cwd_disp="${cwd/#$HOME/\~}"
  _shorten_path "$cwd_disp" "$_cwd_budget"; cwd_disp=$_FORMAT_RESULT
  line1+="${YELLOW}${cwd_disp}${RESET}"
fi

# §7.3 Git branch segment (green, optional)
if [ -n "$_branch_disp" ]; then
  line1+=" ${GREEN}${BRANCH_ICON} ${_branch_disp}${RESET}${_git_status_suffix}"
fi

# §7.4 Thinking indicator
if [ "$thinking_enabled" = "true" ]; then
  line1+=" 🧠"
fi

# §7.5 Model segment (magenta)
if [ -n "$model_name" ]; then
  line1+=" ${MAGENTA}${model_name}${RESET}"
fi

# §7.6 Model flags
if [ "$fast_mode" = "true" ]; then
  line1+=" ${ORANGE}↯${RESET}"
fi

if [ "$_ultracode" = "1" ]; then
  line1+=" ${UC_RAINBOW}"
elif [ -n "$effort_level" ]; then
  case "$effort_level" in
    none)  line1+=" ${DIM}∅${RESET}" ;;
    low)   line1+=" ${GREEN}○${RESET}" ;;
    medium)line1+=" ${MAGENTA}◑${RESET}" ;;
    auto)  line1+=" ${MAGENTA}🅐${RESET}" ;;
    high)  line1+=" ${ORANGE}●${RESET}" ;;
    xhigh) line1+=" ${ORANGE}◉${RESET}" ;;
    max)   line1+=" ${RED}◈${RESET}" ;;
  esac
fi

# §7.7 Context window segment
if [ -z "$used_pct" ]; then
  line1+=" ${DIM}ctx:—${RESET}"
else
  used_int="${used_pct%%.*}"

  # Window size fallback
  W="$window_size"
  if [ -z "$W" ] || [ "$W" -eq 0 ] 2>/dev/null; then
    W=200000
  fi

  # Token counts
  used_tokens=$(( (W * used_int + 50) / 100 ))
  fmt_ctx_k "$used_tokens"; used_k=$_FMT_CTX_RESULT
  fmt_ctx_k "$W"; win_k=$_FMT_CTX_RESULT

  # Effective ceiling E
  E=95
  if [ -n "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" ] && \
     [ "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" -ge 1 ] 2>/dev/null && \
     [ "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" -le 100 ] 2>/dev/null; then
    E=$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
    [ "$E" -gt 95 ] && E=95
  fi

  # Warn percentage (default 75)
  warn_pct=75
  if [ -n "$CLAUDE_STATUSLINE_CTX_WARN_PCT" ] && \
     [ "$CLAUDE_STATUSLINE_CTX_WARN_PCT" -ge 1 ] 2>/dev/null && \
     [ "$CLAUDE_STATUSLINE_CTX_WARN_PCT" -le 99 ] 2>/dev/null; then
    warn_pct=$CLAUDE_STATUSLINE_CTX_WARN_PCT
  fi

  # Caution tokens (default 150000; 0 = disabled)
  caution_tokens=150000
  if [ -n "$CLAUDE_STATUSLINE_CTX_CAUTION_TOKENS" ]; then
    caution_tokens=$CLAUDE_STATUSLINE_CTX_CAUTION_TOKENS
  fi

  # warn_at: orange starts above this threshold
  if [ -n "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" ] && \
     [ "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" -ge 1 ] 2>/dev/null && \
     [ "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" -le 100 ] 2>/dev/null; then
    warn_at=$(( E * warn_pct / 100 ))
  else
    warn_at=$warn_pct
  fi

  # Color selection
  ctx_color="$DIM"
  if [ "$used_int" -ge "$E" ] 2>/dev/null; then
    ctx_color="$RED"
  elif [ "$used_int" -gt "$warn_at" ] 2>/dev/null; then
    ctx_color="$ORANGE"
  elif [ "$caution_tokens" -gt 0 ] 2>/dev/null && [ "$used_tokens" -gt "$caution_tokens" ] 2>/dev/null; then
    ctx_color="$BLUE"
  fi

  line1+=" ${ctx_color}ctx:${used_k}/${win_k}${RESET}≈${used_int}%"
fi

# ── Performance badge computation (§8.1, §3.1) ────────────────────────────────
_perf_level_for_cache() {
  awk -v r="$1" 'BEGIN {
    if (r == "") { print -1; exit }
    r += 0
    if      (r >= 95) print 0
    else if (r >= 90) print 1
    else if (r >= 75) print 2
    else              print 3
  }'
}

_perf_level_for_latency() {
  awk -v d="$1" 'BEGIN {
    if (d == "") { print -1; exit }
    d += 0
    if      (d <= 10) print 0
    else if (d <= 30) print 1
    else if (d <= 60) print 2
    else              print 3
  }'
}

_perf_levels() {
  awk -v r="$1" -v d="$2" 'BEGIN {
    if (r == "") c=-1; else if (r+0 >= 95) c=0; else if (r+0 >= 90) c=1; else if (r+0 >= 75) c=2; else c=3
    if (d == "") l=-1; else if (d+0 <= 10) l=0; else if (d+0 <= 30) l=1; else if (d+0 <= 60) l=2; else l=3
    printf "%d\t%d\n", c, l
  }'
}

_perf_levels_from_metrics() {
  awk -v h="$1" -v t="$2" -v s="$3" -v n="$4" 'BEGIN {
    if (t+0 <= 0) c=-1
    else { r=h*100/t; c=(r>=95?0:r>=90?1:r>=75?2:3) }
    if (n+0 <= 0) l=-1
    else { d=s/n; l=(d<=10?0:d<=30?1:d<=60?2:3) }
    printf "%d\t%d\n", c, l
  }'
}

_decimal_millis() {
  local value=$1 whole=${1%%.*} frac
  frac=${value#*.}; [ "$frac" = "$value" ] && frac=""
  frac="${frac}000"; _MILLIS_RESULT=$(( 10#${whole:-0} * 1000 + 10#${frac:0:3} ))
}

_build_perf_badge() {
  local level="$1"
  local cols=("$DOT_GREEN" "$DOT_YELLOW" "$DOT_ORANGE" "$DOT_RED")
  local out="" i
  for i in 0 1 2 3; do
    if [ "$level" -ge 0 ] 2>/dev/null && [ "$i" -eq "$level" ] 2>/dev/null; then
      out+="${cols[$i]}●${RESET}"
    else
      out+="${DOT_GREY}●${RESET}"
    fi
  done
  _FORMAT_RESULT="$out"
}

perf_badge=""
if [ "$perf_mode" != "off" ]; then
  cache_level=-1 latency_level=-1
  if [ -n "$transcript_path" ] && [ -r "$transcript_path" ] && [ -n "${_tm_total:-}" ]; then
    if [ "$_tm_total" -gt 0 ] 2>/dev/null; then
      if (( _tm_hits * 100 >= _tm_total * 95 )); then cache_level=0
      elif (( _tm_hits * 100 >= _tm_total * 90 )); then cache_level=1
      elif (( _tm_hits * 100 >= _tm_total * 75 )); then cache_level=2
      else cache_level=3
      fi
    fi
    if [ "$_tm_count" -gt 0 ] 2>/dev/null; then
      _decimal_millis "$_tm_sum"
      if (( _MILLIS_RESULT <= _tm_count * 10000 )); then latency_level=0
      elif (( _MILLIS_RESULT <= _tm_count * 30000 )); then latency_level=1
      elif (( _MILLIS_RESULT <= _tm_count * 60000 )); then latency_level=2
      else latency_level=3
      fi
    fi
  fi
  if false; then
    signals=$(jq -rs '
      def usage: (.message.usage // .toolUseResult.usage // null);
      def ts:
        .timestamp as $t |
        if   ($t | type) == "number" then (if $t > 1e12 then $t/1000 else $t end)
        elif ($t | type) == "string" then ($t | fromdateiso8601? // null)
        elif ($t | type) == "object" then ($t.epoch // $t.seconds // null)
        else null end;
      . as $rows
      | ([$rows[] | usage | select(. != null)]) as $u
      | ([$u[] | (.cache_read_input_tokens // 0)] | add // 0) as $hits
      | ([$u[] | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)] | add // 0) as $total
      | (if $total > 0 then ($hits * 100.0 / $total) else null end) as $hit_rate
      | (reduce range(0; $rows|length) as $i ([];
           ($rows[$i]) as $row |
           if $row.type == "assistant" then
             ([range(0; $i) | . as $j | $rows[$j] | select(.type == "user") | ts | select(. != null)]) as $uts
             | ($row | ts) as $a_ts
             | (if ($uts|length) > 0 then ($uts | last) else null end) as $u_ts
             | if $u_ts != null and $a_ts != null and ($a_ts - $u_ts) > 0 and ($a_ts - $u_ts) < 86400
               then . + [$a_ts - $u_ts]
               else . end
           else . end
        )) as $deltas
      | (if ($deltas|length) > 0 then ($deltas | add / length) else null end) as $avg_resp
      | "\($hit_rate // "")\t\($avg_resp // "")"
    ' "$transcript_path" 2>/dev/null)
    : "${signals%%	*}" "${signals#*	}"
  fi

  case "$perf_mode" in
    cache_only)   overall_level="$cache_level" ;;
    latency_only) overall_level="$latency_level" ;;
    *)
      if [ "$cache_level" -lt 0 ] && [ "$latency_level" -lt 0 ]; then
        overall_level=-1
      elif [ "$cache_level" -lt 0 ]; then
        overall_level="$latency_level"
      elif [ "$latency_level" -lt 0 ]; then
        overall_level="$cache_level"
      else
        overall_level=$(( cache_level > latency_level ? cache_level : latency_level ))
      fi ;;
  esac

  _build_perf_badge "$overall_level"; perf_badge=$_FORMAT_RESULT
fi

# ── Utility: visible-length measurement ──────────────────────────────────────

# _visible_len str — ANSI-stripped display column count; emoji (4-byte UTF-8) count as 2
_visible_len() {
  LC_ALL=C awk -v ESC='\033' -v s="$1" -v s2="${2-}" -v two="${2+x}" '
    BEGIN {
      pat = ESC "\\[[0-9;]*[A-Za-z]"
      print _visible(s)
      if (two != "") print _visible(s2)
    }
    function _visible(s, n) {
      n = 0
      while (match(s, pat)) {
        n += _cols(substr(s, 1, RSTART - 1))
        s  = substr(s, RSTART + RLENGTH)
      }
      n += _cols(s)
      return n
    }
    function _cols(t,    i, b, c) {
      c = 0; i = 1
      while (i <= length(t)) {
        b = substr(t, i, 1)
        if      (b >= "\360") { c += 2; i += 4 }
        else if (b >= "\340") { c += 1; i += 3 }
        else if (b >= "\300") { c += 1; i += 2 }
        else if (b >= "\200") {         i += 1 }
        else                  { c += 1; i += 1 }
      }
      return c
    }
  '
}

# ── Utility: level/budget color helpers ───────────────────────────────────────

# _level_color v yt rt → ANSI escape (SPEC §11)
_level_color() {
  local v="$1" yt="$2" rt="$3"
  awk -v v="$v" -v yt="$yt" -v rt="$rt" \
      -v red="$RED" -v yel="$YELLOW" -v grn="$GREEN" \
      'BEGIN { if (v+0 >= rt+0) print red; else if (v+0 >= yt+0) print yel; else print grn }'
}

_level_color_int() {
  local v=$1 yt=$2 rt=$3
  if   [ "$v" -ge "$rt" ]; then printf '%s' "$RED"
  elif [ "$v" -ge "$yt" ]; then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"; fi
}

# _budget_color spent allowance → ANSI escape (SPEC §11)
_budget_color() {
  local spent="$1" allowance="$2"
  awk -v s="$spent" -v a="$allowance" \
      -v red="$RED" -v yel="$YELLOW" -v grn="$GREEN" -v rst="$RESET" \
      -v wlo="$BUDGET_WARN_LO" -v whi="$BUDGET_WARN_HI" \
      'BEGIN {
        if (a+0 <= 0) { if (s+0 > 0) print red; else print rst; exit }
        r = s / a
        if (r <= wlo) print grn
        else if (r <= whi) print yel
        else print red
      }'
}

# _iso_reset_hhmm dt → local HH:MM or empty
_iso_reset_hhmm() {
  local dt="$1"
  [ -z "$dt" ] && return
  # Strip fractional seconds and Z/offset, parse to epoch, format local HH:MM
  local epoch
  epoch=$(printf '%s' "$dt" | sed 's/\.[0-9]*//g; s/Z$//' | \
    (date -jf "%Y-%m-%dT%H:%M:%S" "$(cat)" +%s 2>/dev/null || \
     date -d "$(cat | sed 's/T/ /')" +%s 2>/dev/null)) 2>/dev/null
  [ -n "$epoch" ] && (date -d "@$epoch" +%H:%M 2>/dev/null || date -r "$epoch" +%H:%M 2>/dev/null)
}

# count_month_workdays work_days_str [holidays_raw] → "elapsed total remaining"
count_month_workdays() {
  local wds="$1" hols="${2:-}"
  awk -v wds="$wds" -v holidays="$hols" 'BEGIN {
    cmd_ym = "date +%Y-%m"
    cmd_ym | getline ym; close(cmd_ym)
    split(ym, a, "-"); yr=a[1]+0; mo=a[2]+0

    # Days in month
    if (mo==2) { dim=(yr%4==0 && (yr%100!=0||yr%400==0)) ? 29 : 28 }
    else if (index("4 6 9 11", mo"") > 0) { dim=30 }
    else { dim=31 }

    # DOW of 1st (1=Mon..7=Sun, date +%u)
    cmd_dow = "date +%u -d \""yr"-"sprintf("%02d",mo)"-01\" 2>/dev/null"
    if ((cmd_dow | getline dow_str) <= 0 || dow_str+0 == 0) {
      # BSD fallback
      cmd_dow2 = "date -jf \"%Y-%m-%d\" \""yr"-"sprintf("%02d",mo)"-01\" +%u 2>/dev/null"
      close(cmd_dow)
      cmd_dow2 | getline dow_str; close(cmd_dow2)
    } else { close(cmd_dow) }
    dow1 = (dow_str == "" ? 1 : dow_str+0)

    cmd_dom = "date +%-d 2>/dev/null || date +%d"
    cmd_dom | getline dom_str; close(cmd_dom)
    today = dom_str+0; if (today < 1) today=1

    # Count workdays
    el=0; tot=0; rem=0
    for (d=1; d<=dim; d++) {
      # DOW: (dow1-1+d-1)%7 → 0=Mon..6=Sun → convert to 1-7
      dw = ((dow1-1 + d-1) % 7) + 1
      if (index(wds, dw"") > 0) {
        tot++
        if (d <= today) el++
        if (d >= today) rem++
      }
    }
    if (tot < 1) tot=1
    if (rem < 1) rem=1

    # Holiday adjustment — purely awk, no extra date subshells
    if (holidays != "") {
      n = split(holidays, harr, ",")
      for (hi = 1; hi <= n; hi++) {
        h = harr[hi]; gsub(/ /, "", h)
        if (h !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) continue
        h_ym = substr(h, 1, 7)
        if (h_ym != ym) continue
        h_da = substr(h, 9, 2) + 0
        h_dw = ((dow1 - 1 + h_da - 1) % 7) + 1
        if (index(wds, h_dw "") == 0) continue
        if      (h_da < today) { el--; tot-- }
        else if (h_da == today) { el--; tot--; rem-- }
        else                    { tot--; rem-- }
      }
      if (el < 0) el = 0
      if (tot < 1) tot = 1
      if (rem < 1) rem = 1
    }

    print el, tot, rem
  }'
}

# ── OAuth fetch helper (§4.4, §4.6, §5.1, §5.2) ──────────────────────────────

_fetch_usage_cache_bg() {
  printf '%s' "$$" > "$USAGE_FETCH_LOCK"
  # Lock is NOT removed on exit — its mtime serves as the "last fetch attempt" timestamp.

  local _pfx="" _token _header_version
  command -v timeout >/dev/null 2>&1 && _pfx="timeout 5"
  # macOS keychain first; fall back to ~/.claude/.credentials.json on Linux
  if command -v security >/dev/null 2>&1; then
    _token=$($_pfx security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
             | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  fi
  if [ -z "$_token" ] && [ -f "$_CLAUDE_DIR/.credentials.json" ]; then
    _token=$(jq -r '.claudeAiOauth.accessToken // empty' "$_CLAUDE_DIR/.credentials.json" 2>/dev/null)
  fi

  if [ -z "$_token" ]; then
    printf '%s' "$NOW" > "$AUTH_ERROR_FILE"
    return
  fi

  # The input payload is external. Keep its version value within the HTTP
  # product-version character set before interpolating it into a header.
  _header_version=$(printf '%s' "$version" | tr -cd 'A-Za-z0-9._+-')
  _header_version="${_header_version:0:64}"
  : "${_header_version:=2.1.76}"

  local _tmp="${USAGE_CACHE_FILE}.tmp.$$"
  curl --max-time 10 -sS \
    -H "Authorization: Bearer $_token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-code/${_header_version}" \
    "https://api.anthropic.com/api/oauth/usage" \
    -o "$_tmp" 2>/dev/null
  local _ce=$?

  if [ "$_ce" -eq 0 ] && jq -e . "$_tmp" >/dev/null 2>&1 \
     && ! jq -e '.error' "$_tmp" >/dev/null 2>&1; then
    rm -f "$AUTH_ERROR_FILE"
    mv "$_tmp" "$USAGE_CACHE_FILE"
  else
    printf '%s' "$NOW" > "$AUTH_ERROR_FILE"
    rm -f "$_tmp"
  fi
}

# ── OAuth usage cache: stale detection + refresh trigger (§4.4, §4.6) ────────
#
# Phase 1 — read lock state (no mutations yet)
_lock_age=999999
if [ -f "$USAGE_FETCH_LOCK" ]; then
  _lm=$(_mtime "$USAGE_FETCH_LOCK")
  _lock_age=$(( NOW - ${_lm:-0} ))
fi

# Phase 2 — read cache state
cache_age=999999
if [ -f "$USAGE_CACHE_FILE" ]; then
  IFS='|' read -r cache_inode cache_identity_mtime cache_size cache_mtime < <(_file_identity "$USAGE_CACHE_FILE")
  cache_age=$(( NOW - ${cache_mtime:-0} ))
fi

# Phase 3 — stale display decision (must happen BEFORE fetch spawn so the
# brand-new lock created in Phase 5 does not suppress ⚠️ on this render)
plan_seg="" extra_seg="" monthly_seg=""
_usage_cache_stale=0 _usage_fetch_slow=0

if [ "$cache_age" -lt 999999 ] && [ "$cache_age" -ge $(( 3 * CACHE_TTL )) ]; then
  if [ -f "$USAGE_FETCH_LOCK" ]; then
    if [ "$_lock_age" -lt "$LOCK_INFLIGHT_GRACE" ]; then
      _usage_cache_stale=0   # fetch in flight; suppress
    elif [ "$_lock_age" -lt "$LOCK_LEAK_TIMEOUT" ]; then
      _usage_cache_stale=1   # fetch completed but cache not refreshed → failed
    else
      _usage_cache_stale=0   # lock abandoned (sleep/reboot); treat as hopeful
    fi
  fi  # no lock → first render after expiry → hopeful (stale=0, fetch spawned below)
fi

# Slow-fetch spinner: cache overdue but not yet showing ⚠️ (⚠️ supersedes ↻)
[ "$cache_age" -ge $(( CACHE_TTL + 30 )) ] && [ "$_usage_cache_stale" -eq 0 ] && _usage_fetch_slow=1

# Phase 4 — clean up leaked lock (≥ LOCK_LEAK_TIMEOUT old)
if [ -f "$USAGE_FETCH_LOCK" ] && [ "$_lock_age" -ge "$LOCK_LEAK_TIMEOUT" ]; then
  rm -f "$USAGE_FETCH_LOCK"
  _lock_age=999999
fi

# Phase 5 — fetch trigger (rate-limited by FETCH_RETRY_COOLDOWN)
_need_refresh=0
if [ "$cache_age" -ge "$CACHE_TTL" ]; then
  if [ ! -f "$USAGE_FETCH_LOCK" ]; then
    _need_refresh=1
  elif [ "$_lock_age" -ge "$FETCH_RETRY_COOLDOWN" ]; then
    _need_refresh=1
  fi
fi

if [ "$_need_refresh" = "1" ]; then
  : > "$USAGE_FETCH_LOCK"   # touch (sets mtime=NOW); NOT removed on fetch exit
  ( _fetch_usage_cache_bg & ) >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-
fi

# Parse cache fields once per source identity. The JSON is replaced atomically
# by the fetcher, so inode + high-resolution mtime + size is a stable hot key.
_fh_util="" _sd_util="" _fh_resets="" _sd_resets=""
_ex_enabled="" _ex_used="" _ex_limit=""
if [ -f "$USAGE_CACHE_FILE" ]; then
  _usage_fields_hit=0
  if [ -f "$USAGE_FIELDS_FILE" ]; then
    {
      IFS= read -r _uf_version; IFS= read -r _uf_inode; IFS= read -r _uf_mtime; IFS= read -r _uf_size
      IFS= read -r _fh_util; IFS= read -r _sd_util; IFS= read -r _fh_resets; IFS= read -r _sd_resets
      IFS= read -r _ex_enabled; IFS= read -r _ex_used; IFS= read -r _ex_limit
      IFS= read -r _uf_complete
    } < "$USAGE_FIELDS_FILE"
    [ "$_uf_version" = 2 ] && [ "$_uf_complete" = complete ] && [ "$_uf_inode" = "$cache_inode" ] && [ "$_uf_mtime" = "$cache_identity_mtime" ] && [ "$_uf_size" = "$cache_size" ] && _usage_fields_hit=1
  fi
  if [ "$_usage_fields_hit" = 0 ]; then
    {
      IFS= read -r _fh_util; IFS= read -r _sd_util; IFS= read -r _fh_resets; IFS= read -r _sd_resets
      IFS= read -r _ex_enabled; IFS= read -r _ex_used; IFS= read -r _ex_limit
    } < <(jq -r '
      ((.five_hour.utilization // null) | if . then (. + 0.5 | floor | tostring) else "" end),
      ((.seven_day.utilization // null) | if . then (. + 0.5 | floor | tostring) else "" end),
      (.five_hour.resets_at // ""),
      (.seven_day.resets_at // ""),
      (.extra_usage.is_enabled // ""),
      (.extra_usage.used_credits // ""),
      (.extra_usage.monthly_limit // "")
    ' "$USAGE_CACHE_FILE" 2>/dev/null)
    _uf_tmp="$USAGE_FIELDS_FILE.$_TMP_TAG.tmp"
    printf '2\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\ncomplete\n' "$cache_inode" "$cache_identity_mtime" "$cache_size" "$_fh_util" "$_sd_util" "$_fh_resets" "$_sd_resets" "$_ex_enabled" "$_ex_used" "$_ex_limit" > "$_uf_tmp" && mv "$_uf_tmp" "$USAGE_FIELDS_FILE"
  fi
fi

# Auth error flag — computed once, used in multiple sections below
_auth_error=0
[ -f "$AUTH_ERROR_FILE" ] && _auth_error=1

# _plan_slot label int color resets — renders one Pro/Max utilization slot
_plan_slot() {
  local label="$1" int="$2" color="$3" resets="$4"
  local slot
  if [ "$int" -ge 100 ] 2>/dev/null; then
    slot="${RED}${label}:${BOLD}🪫100%${RESET}"
    if [ -n "$resets" ]; then
      local hhmm; hhmm=$(_iso_reset_hhmm "$resets")
      [ -n "$hhmm" ] && slot+=" ${DIM}↻${hhmm}${RESET}"
    fi
  else
    slot="${color}${label}:"
    if [ "$_usage_cache_stale" = "1" ]; then
      slot+="${STRIKETHROUGH}"
    else
      slot+="${BOLD}"
    fi
    slot+="${int}%${RESET}"
    if [ "$int" -ge 75 ] && [ -n "$resets" ]; then
      local hhmm; hhmm=$(_iso_reset_hhmm "$resets")
      [ -n "$hhmm" ] && slot+=" ${DIM}↻${hhmm}${RESET}"
    fi
  fi
  printf '%s' "$slot"
}

# ── Pro/Max plan display (§8.2) ───────────────────────────────────────────────
if [ -n "$_fh_util" ]; then
  _fh_int="${_fh_util:-0}"
  _sd_int="${_sd_util:-0}"
  _fh_color=$(_level_color_int "$_fh_int" 75 90)
  _sd_color=$(_level_color_int "$_sd_int" 75 90)

  _fh_slot=$(_plan_slot "5h" "$_fh_int" "$_fh_color" "$_fh_resets")
  _sd_slot=$(_plan_slot "7d" "$_sd_int" "$_sd_color" "$_sd_resets")
  plan_seg="${_fh_slot}  ${_sd_slot}"

  # Extra badge (§8.3) for Pro/Max
  if [ "$_ex_enabled" = "true" ] && [ -n "$_ex_limit" ] && [ "${_ex_limit:-0}" != "0" ]; then
    _show_extra=0
    [ "${_ex_used:-0}" != "0" ] && _show_extra=1
    if [ "$_fh_int" -ge "${extra_preview_pct:-75}" ] 2>/dev/null; then _show_extra=1; fi
    if [ "$_show_extra" = "1" ]; then
      _used_fmt=$(_fmt_cents "${_ex_used:-0}")
      _lim_fmt="\$$(_fmt_cents "${_ex_limit:-0}" 0)"
      if [ "$_auth_error" = "1" ]; then
        extra_seg="  ${DIM}+🔑${RESET} ${STRIKETHROUGH}\$${_used_fmt}/${_lim_fmt}${RESET}"
      elif [ "$_usage_cache_stale" = "1" ]; then
        extra_seg="  ${DIM}+⚠️${RESET} ${STRIKETHROUGH}\$${_used_fmt}${RESET}${DIM}/${_lim_fmt}${RESET}"
      else
        extra_seg="  ${DIM}+💰${RESET}${BOLD}\$${_used_fmt}${RESET}${DIM}/${_lim_fmt}${RESET}"
      fi
    fi
  fi
fi

# ── Enterprise monthly display (§8.4) ─────────────────────────────────────────
_allow_15m="" _allow_1h="" _allow_1d=""
_oauth_render_hit=0 _oauth_render_enterprise=0 _oauth_render_key=""

# Enterprise rendering includes calendar, pace, runway, and monetary work. Cache
# its final bytes until the OAuth source, local day, or display inputs change.
if [ -z "$_fh_util" ] && [ "$_ex_enabled" = "true" ] && [ -n "$_ex_limit" ]; then
  _oauth_render_enterprise=1
  _oauth_render_key="1|${cache_inode:-}|${cache_identity_mtime:-}|${cache_size:-}|$_auth_error|$_usage_cache_stale|$loadavg_mode|$sign_mode|$show_pace_ratio|$hours_per_day|$work_days_str|$holidays_raw|$DECIMAL_POINT|$_DAY_START"
  if [ -f "$USAGE_RENDER_FILE" ]; then
    {
      IFS= read -r _ur_version; IFS= read -r _ur_key; IFS= read -r _ur_monthly
      IFS= read -r _ur_15m; IFS= read -r _ur_1h; IFS= read -r _ur_1d
      IFS= read -r _ur_complete
    } < "$USAGE_RENDER_FILE"
    if [ "$_ur_version" = 2 ] && [ "$_ur_complete" = complete ] && [ -n "$_ur_monthly" ] && [ "$_ur_key" = "$_oauth_render_key" ]; then
      monthly_seg=$_ur_monthly
      _allow_15m=$_ur_15m _allow_1h=$_ur_1h _allow_1d=$_ur_1d
      _oauth_render_hit=1
    fi
  fi
fi

if [ "$_oauth_render_enterprise" = 1 ] && [ "$_oauth_render_hit" = 0 ]; then
  _ex_used_v="${_ex_used:-0}"
  _ex_limit_v="${_ex_limit:-1}"

  # Determine state glyph
  if [ "$_auth_error" = "1" ]; then
    _ent_glyph="🔑" _ent_stale=1
  elif [ "$_usage_cache_stale" = "1" ]; then
    _ent_glyph="⚠️" _ent_stale=1
  else
    _ent_glyph="💰" _ent_stale=0
    # Check burned
    if awk -v u="$_ex_used_v" -v l="$_ex_limit_v" 'BEGIN{exit (u+0 >= l+0 ? 0 : 1)}'; then
      _ent_glyph="🪫"
    fi
  fi

  # Workday counting (with holidays)
  read -r _wk_elapsed _wk_total _wkdays < <(count_month_workdays "$work_days_str" "$holidays_raw")

  # Fractional elapsed (for pace)
  _midnight="$_DAY_START"
  _secs_since_mid=$(( NOW - _midnight ))
  [ "$_secs_since_mid" -lt 0 ] && _secs_since_mid=0
  _today_dow=$(date +%u)
  _is_workday=0
  [[ "$work_days_str" == *"$_today_dow"* ]] && _is_workday=1
  _today_frac=$(awk -v s="$_secs_since_mid" -v h="${hours_per_day:-6}" \
    'BEGIN{ step=s/(h*3600); if(step>3)step=3; printf "%.6f", step/3 }')
  if [ "$_is_workday" = "1" ] && [ "$_wk_elapsed" -ge 1 ] 2>/dev/null; then
    _wk_elapsed_frac=$(awk -v e="$_wk_elapsed" -v f="$_today_frac" 'BEGIN{printf "%.6f", (e-1)+f}')
  else
    _wk_elapsed_frac=$(awk -v e="$_wk_elapsed" 'BEGIN{printf "%.6f", e+0}')
  fi

  # All monetary calcs in awk
  _ent_calcs=$(awk -v u="$_ex_used_v" -v l="$_ex_limit_v" \
    -v ef="$_wk_elapsed_frac" -v wt="$_wk_total" \
    -v wd="$_wkdays" -v hpd="${hours_per_day:-6}" \
    'BEGIN{
      used=u/100; lim=l/100
      rem_usd=(lim-used > 0 ? lim-used : 0)
      usage_pct = (lim > 0 ? used/lim : 0)
      day_pct   = (wt > 0 ? ef/wt    : 0)
      pct_int   = int(usage_pct * 100 + 0.5)
      if (day_pct < 1e-9) { pace="—" }
      else { pace = sprintf("%.6f", usage_pct / day_pct) }
      if (day_pct < 0.05) {
        if      (usage_pct < 0.05)  m_level=0
        else if (usage_pct <= 0.10) m_level=1
        else                        m_level=2
      } else {
        ratio = usage_pct / day_pct
        if      (ratio < 0.9)  m_level=0
        else if (ratio <= 1.1) m_level=1
        else                   m_level=2
      }
      # per-day allowance
      per_day  = (wd > 0 ? rem_usd/wd : rem_usd)
      allow_1h = per_day / hpd
      allow_15m= allow_1h / 4
      allow_1d = per_day
      printf "%s\t%s\t%d\t%.6f\t%.6f\t%.6f\t%.6f\t%s\t%d\n", \
        sprintf("%.6f",used), sprintf("%.6f",rem_usd), pct_int, \
        allow_15m, allow_1h, allow_1d, per_day, pace, m_level
    }')
  IFS=$'\t' read -r _used_usd _rem_usd _pct_int _allow_15m _allow_1h _allow_1d _per_day _pace _m_level \
    <<< "$_ent_calcs"
  _used_usd=$(_fmt_money "$_used_usd")
  _rem_usd=$(_fmt_money "$_rem_usd")
  [ "$_pace" != "—" ] && _pace=$(_fmt_money "$_pace")

  case "$_m_level" in
    0) _m_color="$GREEN"  ;;
    1) _m_color="$YELLOW" ;;
    2) _m_color="$RED"    ;;
    *) _m_color=""        ;;
  esac

  _lim_usd=$(_fmt_cents "$_ex_limit_v" 0)

  # Runway allowance cache (§4.5) — written only when loadavg=on
  if [ "$loadavg_mode" = "on" ]; then
    _hols_key="${holidays_raw:-none}"
    _ra_today=$(date +%Y-%m-%d)
    # Check if existing cache is still valid
    _write_ra=1
    if [ -f "$RUNWAY_CACHE_FILE" ]; then
      read -r _ra_ep _ra_ymd _ra_lim _ra_hkey _ra_used _ra_15m _ra_1h _ra_1d < "$RUNWAY_CACHE_FILE" 2>/dev/null || true
      _ra_day_start="$_DAY_START"
      if [ "$_ra_ymd" = "$_ra_today" ] && \
         [ "${_ra_ep:-0}" -ge "$_ra_day_start" ] 2>/dev/null && \
         [ "$_ra_lim" = "$_ex_limit_v" ] && \
         [ "$_ra_hkey" = "$_hols_key" ]; then
        _write_ra=0
        _allow_15m=$_ra_15m
        _allow_1h=$_ra_1h
        _allow_1d=$_ra_1d
      fi
    fi
    # Only pin a used_credits snapshot for the whole day if it's actually fresh —
    # the ⚠️ display flag stays 0 ("hopeful") even when cache_age is well past
    # CACHE_TTL whenever no fetch lock is present, which must not be trusted for
    # a 24h-pinned allowance (e.g. laptop asleep across a monthly reset).
    if [ "$_write_ra" = "1" ] && [ "$cache_age" -lt $(( 3 * CACHE_TTL )) ]; then
      printf '%d %s %s %s %s %s %s %s\n' \
        "$NOW" "$_ra_today" "$_ex_limit_v" "$_hols_key" "$_ex_used_v" \
        "$_allow_15m" "$_allow_1h" "$_allow_1d" \
        > "$RUNWAY_CACHE_FILE"
    fi
  else
    # When not loadavg=on, clear allowances so no suffix appears
    _allow_15m="" _allow_1h="" _allow_1d=""
  fi

  # Build monthly_seg — precedence: auth-broken > burned > normal/stale
  if [ "$_ent_glyph" = "🔑" ]; then
    # Auth-broken (§8.4, Example F): no ≈%, no 🔥pace×; amount+limit struck through, no color
    monthly_seg="${DIM}🔑${RESET}${STRIKETHROUGH}\$${_used_usd}/\$${_lim_usd}${RESET}  "
  elif [ "$_ent_glyph" = "🪫" ]; then
    # Burned state
    monthly_seg="${DIM}🪫${RED}${BOLD}\$${_used_usd}/\$${_lim_usd}${RESET}  "
  else
    # Fresh (💰) or stale (⚠️) — glyph already set in _ent_glyph; stale adds STRIKETHROUGH to amount
    if [ "$_ent_stale" = "1" ]; then
      _money="${_m_color}${STRIKETHROUGH}\$${_used_usd}${RESET}"
    else
      case "$sign_mode" in
        used_minus)
          if awk -v u="$_used_usd" 'BEGIN{exit (u+0>0?0:1)}'; then
            _money="${BOLD}${_m_color}-\$${_used_usd}${RESET}"
          else
            _money="${BOLD}\$${_used_usd}${RESET}"
          fi ;;
        remaining_plus)
          _money="${BOLD}${_m_color}+\$${_rem_usd}${RESET}" ;;
        both)
          _money="${BOLD}${_m_color}-\$${_used_usd} +\$${_rem_usd}${RESET}" ;;
        *)
          _money="${BOLD}${_m_color}\$${_used_usd}${RESET}" ;;
      esac
    fi
    monthly_seg="${DIM}${_ent_glyph}${_money}${DIM}/\$${_lim_usd}${RESET}${DIM}≈${BOLD}${_pct_int}%${RESET}  "
    if [ "$show_pace_ratio" = "on" ]; then
      monthly_seg+="${DIM}🔥${BOLD}${_pace}×${RESET}  "
    fi
  fi
fi

# ── Line 2 assembly (§10) ──────────────────────────────────────────────────────
if [ "$_oauth_render_enterprise" = 1 ] && [ "$_oauth_render_hit" = 0 ]; then
  _ur_tmp="$USAGE_RENDER_FILE.$_TMP_TAG.tmp"
  printf '2\n%s\n%s\n%s\n%s\n%s\ncomplete\n' \
    "$_oauth_render_key" "$monthly_seg" "$_allow_15m" "$_allow_1h" "$_allow_1d" \
    > "$_ur_tmp" && mv "$_ur_tmp" "$USAGE_RENDER_FILE"
fi

# §10 item 1: leading ZWSP + two spaces
line2="${SPACE}  "

# §10 item 2: performance badge
if [ -n "$perf_badge" ]; then
  line2+="${perf_badge}"
fi
# §10 item 3: always two spaces
line2+="  "

# §10 items 4–7: slow-fetch + plan/extra/monthly (§8.2–§8.5)
_has_plan_seg=0
[ -n "$plan_seg" ]   && _has_plan_seg=1
[ -n "$extra_seg" ]  && _has_plan_seg=1
[ -n "$monthly_seg" ] && _has_plan_seg=1
# §8.5 slow-fetch ↻ — shown before segments when lock is old and segments non-empty
if [ "$_usage_fetch_slow" = "1" ] && [ "$_has_plan_seg" = "1" ]; then
  line2+="${DIM}↻${RESET}"
fi
[ -n "$plan_seg" ]    && line2+="${plan_seg}"
[ -n "$extra_seg" ]   && line2+="${extra_seg}"
if [ -n "$monthly_seg" ]; then
  line2+="${monthly_seg}"  # monthly_seg already carries trailing "  "
elif [ "$_has_plan_seg" = "1" ]; then
  line2+="  "
fi

# §10 item 8: cost pair + 3 trailing spaces (if non-empty)
if [ -n "$cost_seg" ]; then
  line2+="${cost_seg}   "
fi

# §10 item 9: rolling 💸 windows — built into _spend_seg for adaptive truncation
_spend_seg=""
if [ "$loadavg_mode" != "off" ] && [ -f "$LOG_FILE" ]; then
  _spend_bfile="$BASELINE_FILE"; [ -f "$_spend_bfile" ] || _spend_bfile=/dev/null
  { IFS= read -r _spend_log_id; IFS= read -r _spend_base_id; } < <(_pair_identity "$LOG_FILE" "$_spend_bfile")
  _spend_key="${_spend_log_id}|${_spend_base_id}|${session_id}|${cost_6f}|${_DAY_START}"
  _spend_hit=0
  if [ -f "$SPEND_METRICS_FILE" ]; then
    { IFS= read -r _spend_version; IFS= read -r _spend_cached_key; read -r s15 s1h s1d nd15 nd1h nd1d; IFS= read -r _spend_complete; } < "$SPEND_METRICS_FILE"
    if [ "$_spend_version" = 2 ] && [ "$_spend_complete" = complete ] && [ "$_spend_cached_key" = "$_spend_key" ]; then
      case "$nd15$nd1h$nd1d" in [01][01][01]) _spend_hit=1 ;; esac
    fi
  fi
  if [ "$_spend_hit" = 0 ]; then
    read -r s15 s1h s1d nd15 nd1h nd1d < <(calc_spent_all)
    _spend_tmp="$SPEND_METRICS_FILE.$_TMP_TAG.tmp"
    printf '2\n%s\n%s %s %s %s %s %s\ncomplete\n' "$_spend_key" "$s15" "$s1h" "$s1d" "$nd15" "$nd1h" "$nd1d" > "$_spend_tmp" && mv "$_spend_tmp" "$SPEND_METRICS_FILE"
  fi
  # Allowances for 15m/1h/1d (Enterprise + loadavg=on only)
  _r_allow_15m="" _r_allow_1h="" _r_allow_1d=""
  if [ "$loadavg_mode" = "on" ] && [ -n "$_allow_1h" ] && [ "$_auth_error" != "1" ]; then
    _r_allow_15m=$(_fmt_money "$_allow_15m")
    _r_allow_1h=$(_fmt_money "$_allow_1h")
    _r_allow_1d=$(_fmt_money "$_allow_1d")
  fi
  if [ -n "$_r_allow_1h" ]; then
    IFS=$'\t' read -r _bc_15m _bc_1h _bc_1d <<< "$(awk \
      -v s15="$s15" -v a15="$_r_allow_15m" \
      -v s1h="$s1h" -v a1h="$_r_allow_1h" \
      -v s1d="$s1d" -v a1d="$_r_allow_1d" \
      -v red="$RED" -v yel="$YELLOW" -v grn="$GREEN" -v rst="$RESET" \
      -v wlo="$BUDGET_WARN_LO" -v whi="$BUDGET_WARN_HI" \
      'BEGIN{
        split("", sa); split("", aa)
        sa[1]=s15; sa[2]=s1h; sa[3]=s1d
        aa[1]=a15; aa[2]=a1h; aa[3]=a1d
        for (i=1;i<=3;i++) {
          s=sa[i]+0; a=aa[i]+0
          if (a<=0) { c=(s>0?red:rst) }
          else { r=s/a; c=(r<=wlo?grn:r<=whi?yel:red) }
          printf "%s%s", c, (i<3?"\t":"")
        }
        printf "\n"
      }')"
  else
    _bc_15m="" _bc_1h="" _bc_1d=""
  fi
  # 15m: colored but no allowance suffix (pass empty 5th arg, bcolor as 6th)
  _roll_slot 15m "$s15" "$nd15" "$sign_mode" "" "$_bc_15m"; _slot_15m=$_ROLL_SLOT_RESULT
  _roll_slot 1h "$s1h" "$nd1h" "$sign_mode" "$_r_allow_1h" "$_bc_1h"; _slot_1h=$_ROLL_SLOT_RESULT
  _roll_slot 1d "$s1d" "$nd1d" "$sign_mode" "$_r_allow_1d" "$_bc_1d"; _slot_1d=$_ROLL_SLOT_RESULT
  _spend_seg="${DIM}💸${RESET}  ${_slot_15m}  ${_slot_1h}  ${_slot_1d}"
elif [ "$loadavg_mode" != "off" ]; then
  # log file doesn't exist yet (very first run before lock acquired or log created)
  _spend_seg="${DIM}💸${RESET}  15m:${DIM}—${RESET}  1h:${DIM}—${RESET}  1d:${DIM}—${RESET}"
fi

# Adaptive truncation: suppress spend segment if it would cause line 2 to wrap.
# Uses _TERM_W_RAW (pre-floor) so narrow terminals (<88) still trigger suppression.
if [ -n "$_spend_seg" ]; then
  _line2_available=$(( _TERM_W_RAW - 3 ))
  { IFS= read -r _len_without; IFS= read -r _len_spend; } < <(_visible_len "$line2" "$_spend_seg")
  _len_without=$(( _len_without - 3 ))

  if [ "$_len_without" -le "$_line2_available" ] && \
     [ $(( _len_without + _len_spend )) -gt "$_line2_available" ]; then
    _spend_seg=""
  fi
fi
[ -n "$_spend_seg" ] && line2+="$_spend_seg"

# ── Output (§14) ──────────────────────────────────────────────────────────────
printf '%s\n' "$line1"
printf '%s'   "$line2"
