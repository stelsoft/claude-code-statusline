#!/bin/bash
input=$(cat)

RESET="\033[0m"

# Portable command shims — statusline must run install-free on Linux, macOS, and
# Windows (Git Bash/WSL), so only bash + tools that exist on both GNU and BSD.
# Probe date once: only GNU date accepts -d.
if date -d @0 >/dev/null 2>&1; then DATE_GNU=1; else DATE_GNU=0; fi
epoch_hhmm() { [ "$DATE_GNU" = 1 ] && date -d "@$1" +%H:%M || date -r "$1" +%H:%M; }
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# make_bar <pct> <width> -> prints a colored unicode bar for that percentage
make_bar() {
  local pct=$1 width=$2
  # Half-blocks double the resolution of a 4-cell bar (8 steps, not 4), and the
  # ceil means any nonzero usage shows something — at whole cells 1-24% all
  # rendered as an empty bar, which read as a broken statusline.
  local halves=$(((pct * width * 2 + 99) / 100))
  # A full bar means 100%, nothing less: without this, ceil made 88% look maxed.
  [ "$halves" -ge $((width * 2)) ] && [ "$pct" -lt 100 ] && halves=$((width * 2 - 1))
  [ "$halves" -gt $((width * 2)) ] && halves=$((width * 2))
  local full=$((halves / 2)) half=$((halves % 2))
  local empty=$((width - full - half))
  local color="\033[90m"
  local bar="" fill pad
  [ "$full" -gt 0 ] && printf -v fill "%${full}s" && bar="${fill// /▓}"
  [ "$half" -gt 0 ] && bar="${bar}▒"
  [ "$empty" -gt 0 ] && printf -v pad "%${empty}s" && bar="${bar}${pad// /░}"
  printf "${color}%s${RESET}" "$bar"
}

# pct_text <pct> -> prints "<pct>%" colored by usage threshold
pct_text() {
  local pct=$1 color
  if [ "$pct" -ge 80 ]; then color="\033[31m"
  elif [ "$pct" -ge 50 ]; then color="\033[33m"
  else color="\033[0m"
  fi
  printf "${color}%s%%${RESET}" "$pct"
}

# Pull fields straight out of the JSON with bash string ops — no jq/python,
# nothing to install, runs on any bash incl. macOS 3.2. jstr/jnum match a key
# anywhere; for the repeated "used_percentage"/"resets_at" keys we first chop to
# just after the parent key so the first match is the right one (order- and
# whitespace-independent). jnum keeps the integer part, matching the old truncation.
jstr() { [[ $1 =~ \"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && printf '%s' "${BASH_REMATCH[1]}"; }
jnum() { [[ $1 =~ \"$2\"[[:space:]]*:[[:space:]]*(-?[0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"; }

MODEL=$(jstr "$input" display_name)
EFFORT=$(jstr "$input" level)
DIR=$(jstr "$input" current_dir)

# Chop to the object's own braces before matching: "used_percentage" also lives
# under rate_limits, so an unbounded search would show the 5h number as context.
obj() { local s=${1#*$2}; [[ $1 == *$2* ]] && printf '%s' "${s%%\}*}"; }

in_tok=$(jnum "$input" total_input_tokens)
out_tok=$(jnum "$input" total_output_tokens)
USED=$(( ${in_tok:-0} + ${out_tok:-0} ))
MAX=$(jnum "$input" context_window_size); MAX=${MAX:-200000}

# Computed, not parsed: context_window.used_percentage sits *after* the nested
# current_usage object, so obj()'s cut-at-first-brace lands before it and yielded
# 0%. Rounding (not truncating) reproduces the JSON's own figure exactly.
PCT=$(((USED * 100 + MAX / 2) / MAX))

# Source of truth for 5h/7d. These come from the last API response's rate-limit
# headers and match what interactive /usage shows to the point (28.000000000000004
# vs "28% used"). The `claude -p "/usage"` scrape below does NOT: a fresh headless
# session reports 2%/0% for the same window, so it must never override these.
five=$(obj "$input" five_hour)
DAILY=$(jnum "$five" used_percentage)
DAILY_RESET=$(jnum "$five" resets_at)
WEEKLY=$(jnum "$(obj "$input" seven_day)" used_percentage)

USED_K=$((USED / 1000))
MAX_K=$((MAX / 1000))

# Session-average output speed: every assistant message's output tokens over the
# API time that produced them. The payload's total_output_tokens is NOT a session
# total — it is just the last response (it feeds the context bar above), so
# dividing it by cumulative API time gave a number that jumped around and hit 0
# whenever the last reply was short. The transcript is the only cumulative source.
# It writes one line per content block, so the same message id repeats and is
# counted once; the second "output_tokens" inside usage.iterations never wins
# because only the first match on a line is read.
api_ms=$(jnum "$input" total_api_duration_ms)
transcript=$(jstr "$input" transcript_path)
transcript=${transcript//\\\\/\/}   # Git Bash: JSON carries C:\\Users\\... escaped
if [ "${api_ms:-0}" -gt 0 ] && [ -s "$transcript" ]; then
  # clears counts only real /clear invocations: the marker is the whole user
  # message, so anchoring at "content":" keeps a chat *about* /clear from counting.
  read -r out_total clears <<< "$(awk '
    index($0, "\"content\":\"<command-name>/clear<") { clears++ }
    /"output_tokens":/{
      if (!match($0, /"id":"msg_[^"]*"/)) next
      id = substr($0, RSTART + 6, RLENGTH - 7)
      if (id in seen) next
      seen[id] = 1
      if (match($0, /"output_tokens":[0-9]+/)) sum += substr($0, RSTART + 16, RLENGTH - 16)
    } END { print sum + 0, clears + 0 }' "$transcript")"
  # /clear and a model switch each start a conversation the running average no
  # longer describes, but every counter here is a session total that survives
  # both — so the totals at the reset are cached and subtracted from then on.
  # Keyed by session id: concurrent sessions would otherwise reset each other.
  TPS_STATE="$HOME/.claude/.statusline_tps_$(jstr "$input" session_id)"
  mark="$clears $MODEL"   # mark last: read gives it the rest of the line, spaces and all
  base_out=0 base_ms=0 base_mark=""
  [ -f "$TPS_STATE" ] && read -r base_out base_ms base_mark < "$TPS_STATE"
  if [ "$mark" != "$base_mark" ] || [ "$api_ms" -lt "${base_ms:-0}" ]; then
    # Empty base_mark is the first frame of a session, not a reset — keep the
    # whole history there, or every session would start by throwing itself away.
    [ -n "$base_mark" ] && { base_out=$out_total; base_ms=$api_ms; }
    printf '%s %s %s\n' "$base_out" "$base_ms" "$mark" > "$TPS_STATE"
    # One file per session, so sweep the dead ones — on this rare write, not per frame.
    find "$HOME/.claude" -maxdepth 1 -name '.statusline_tps_*' -mtime +7 -delete 2>/dev/null
  fi
  d_ms=$((api_ms - base_ms)) d_out=$((out_total - base_out))
  [ "$d_ms" -gt 0 ] && [ "$d_out" -gt 0 ] && TPS=$((d_out * 1000 / d_ms))
fi

# fable is never in the JSON at all, so it is scraped from `claude -p "/usage"`,
# cached and refreshed in the background every 15s so the statusline never blocks.
# ponytail: that source reads a local snapshot that can lag by hours (see above),
# so fable trails reality. Drop this block if the JSON ever grows a per-model bucket.
FABLE_CACHE="$HOME/.claude/.statusline_fable_cache"
FABLE_MAX_AGE=15
now=$(date +%s)

# One age for the whole statusline plus the last known 5h reset. Deliberately not
# per-session — the 5h window is account-wide, so any session seeing a new value
# refreshes it for all of them.
USAGE_TS="$HOME/.claude/.statusline_usage_ts"
last_pct="" last_ts="$now" last_reset=""
[ -f "$USAGE_TS" ] && read -r last_pct last_ts last_reset < "$USAGE_TS"
# A brand-new session has no rate_limits in the JSON yet, and the background
# scrape below cannot land before this first frame draws — so the reset time was
# blank exactly when it is looked at most. The cached epoch stays valid until the
# window rolls, so reuse it; JSON always wins when it does arrive.
[ -z "$DAILY_RESET" ] && [ "${last_reset:-0}" -gt "$now" ] && DAILY_RESET=$last_reset

mtime=0
[ -f "$FABLE_CACHE" ] && mtime=$(file_mtime "$FABLE_CACHE" || echo 0)
# The background refresh can be killed before its `rm -f` runs (session exit,
# SIGKILL), leaving a lock that would block every future refresh forever and
# freeze the numbers. Anything older than a minute is a corpse, not a holder.
if [ -f "$FABLE_CACHE.lock" ]; then
  lock_mtime=$(file_mtime "$FABLE_CACHE.lock" || echo 0)
  [ $((now - ${lock_mtime:-0})) -gt 60 ] && rm -f "$FABLE_CACHE.lock" "$FABLE_CACHE.tmp"
fi
if [ $((now - mtime)) -gt "$FABLE_MAX_AGE" ] && [ ! -f "$FABLE_CACHE.lock" ]; then
  (
    touch "$FABLE_CACHE.lock"
    claude -p "/usage" 2>/dev/null > "$FABLE_CACHE.tmp" && mv "$FABLE_CACHE.tmp" "$FABLE_CACHE"
    rm -f "$FABLE_CACHE.lock"
  # stdout closed too: Claude Code reads the statusline until EOF, and the child
  # would otherwise hold that fd open for the whole `claude -p` run, stalling the
  # frame. Nothing in here prints, so nothing is lost.
  ) >/dev/null 2>&1 & disown 2>/dev/null
fi

if [ -f "$FABLE_CACHE" ]; then
  # Regexes held in vars: a literal ( inside [[ =~ ]] confuses the [[ tokenizer.
  re_daily='Current session: ([0-9]+)'
  re_reset='resets ([^(]*)'
  re_week='Current week \(all models\): ([0-9]+)'
  re_fable='Current week \(Fable\): ([0-9]+)'
  while IFS= read -r line; do
    # Only fill what the JSON left empty (brand-new session, no API response yet).
    # Never overwrite a JSON value — the scrape is the lower-quality source.
    if [[ $line =~ $re_daily ]]; then
      DAILY=${DAILY:-${BASH_REMATCH[1]}}
      if [ -z "$DAILY_RESET" ] && [[ $line =~ $re_reset ]]; then
        DAILY_RESET_TXT=${BASH_REMATCH[1]//,/}   # "Jul 25, 3pm" — the comma alone makes date -d reject it
        DAILY_RESET_TXT=${DAILY_RESET_TXT%"${DAILY_RESET_TXT##*[![:space:]]}"}  # rtrim
        # ponytail: reset-text to epoch is GNU-only (date -d free text); BSD date
        # cannot parse it. Only fires for a new session before the JSON rate_limits
        # arrive, so on macOS the 5h bar shows and the reset text waits for JSON.
        [ "$DATE_GNU" = 1 ] && [ -n "$DAILY_RESET_TXT" ] && DAILY_RESET=$(date -d "$DAILY_RESET_TXT" +%s 2>/dev/null)
      fi
    fi
    [[ $line =~ $re_week ]] && WEEKLY=${WEEKLY:-${BASH_REMATCH[1]}}
    [[ $line =~ $re_fable ]] && FABLE=${BASH_REMATCH[1]}
  done < "$FABLE_CACHE"
fi

LINE2=""
if [ -n "$DAILY" ]; then
  LINE2="${LINE2}5h $(make_bar "$DAILY" 4) $(pct_text "$DAILY")"
  if [ -n "$DAILY_RESET" ]; then
    now_s=$(date +%s)
    diff_s=$((DAILY_RESET - now_s))
    if [ "$diff_s" -lt 0 ]; then
      LINE2="${LINE2} (resets now)"
    else
      dh=$((diff_s / 3600))
      dm=$(((diff_s % 3600) / 60))
      if [ "$diff_s" -le 3600 ]; then reset_color="\033[31m"
      elif [ "$diff_s" -le 7200 ]; then reset_color="\033[33m"
      else reset_color="\033[32m"
      fi
      reset_hhmm=$(epoch_hhmm "$DAILY_RESET")
      if [ "$dh" -gt 0 ]; then
        reset_txt="resets in ${dh}h$(printf '%02d' "$dm")m (${reset_hhmm})"
      else
        reset_txt="resets in ${dm}m (${reset_hhmm})"
      fi
      LINE2="${LINE2} (${reset_color}${reset_txt}${RESET})"
    fi
  fi
fi
[ -n "$WEEKLY" ] && LINE2="${LINE2}${LINE2:+ | }7d $(make_bar "$WEEKLY" 4) $(pct_text "$WEEKLY")"
# Hidden at 0 rather than shown as 0%. The scrape is the only source for fable
# (no per-model bucket in the JSON, no local file has percentages), and headless
# /usage currently returns ~0 for every percentage while printing correct reset
# times — so 0 here means "source broken", not "no fable usage". The bar comes
# back on its own if that source starts reporting again.
[ -n "$FABLE" ] && [ "$FABLE" -gt 0 ] &&
  LINE2="${LINE2}${LINE2:+ | }fable $(make_bar "$FABLE" 4) $(pct_text "$FABLE")"

# Only the percentage moving means new usage, so only that resets the age. The
# reset epoch rides along in the same file and is written whenever it is learned.
if [ "${DAILY:-}" != "$last_pct" ]; then last_ts="$now"; fi
if [ "${DAILY:-}" != "$last_pct" ] || [ "${DAILY_RESET:-}" != "$last_reset" ]; then
  printf '%s %s %s\n' "${DAILY:-}" "$last_ts" "${DAILY_RESET:-$last_reset}" > "$USAGE_TS"
fi
age_s=$((now - last_ts))
if [ "$age_s" -lt 60 ]; then AGE_TXT="${age_s}s ago"
else AGE_TXT="$((age_s / 60))m ago"
fi

LINE1="[$MODEL${EFFORT:+ $EFFORT}${TPS:+ ${TPS}tps}] ${DIR##*/} $(make_bar "$PCT" 4) $(pct_text "$PCT") (${USED_K}k/${MAX_K}k) | updated ${AGE_TXT}"

printf "%b\n" "$LINE1"
[ -n "$LINE2" ] && printf "%b\n" "$LINE2"
exit 0
