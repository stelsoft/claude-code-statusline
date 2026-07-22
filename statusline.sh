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
  local filled=$((pct * width / 100))
  local empty=$((width - filled))
  local color="\033[90m"
  local bar="" fill pad
  [ "$filled" -gt 0 ] && printf -v fill "%${filled}s" && bar="${fill// /▓}"
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
SESSION_ID=$(jstr "$input" session_id); SESSION_ID=${SESSION_ID:-default}

cw=$input; [[ $input == *context_window* ]] && cw=${input#*context_window}
PCT=$(jnum "$cw" used_percentage); PCT=${PCT:-0}

in_tok=$(jnum "$input" total_input_tokens)
out_tok=$(jnum "$input" total_output_tokens)
USED=$(( ${in_tok:-0} + ${out_tok:-0} ))
MAX=$(jnum "$input" context_window_size); MAX=${MAX:-200000}

# Guards matter: on a new session (no rate_limits) an unguarded ${input#*five_hour}
# would fall back to the whole blob and pick up the context-window %. Left empty,
# these get backfilled from the fable cache below.
DAILY=""; DAILY_RESET=""
if [[ $input == *five_hour* ]]; then
  DAILY=$(jnum "${input#*five_hour}" used_percentage)
  DAILY_RESET=$(jnum "${input#*five_hour}" resets_at)
fi
WEEKLY=""
[[ $input == *seven_day* ]] && WEEKLY=$(jnum "${input#*seven_day}" used_percentage)

USED_K=$((USED / 1000))
MAX_K=$((MAX / 1000))

# Context tokens only change when a message actually completes, but this script
# re-runs on every refreshInterval tick — so track when USED last changed to
# show how stale the number is.
UPDATED_CACHE="$HOME/.claude/.statusline_updated_${SESSION_ID}"
now_ts=$(date +%s)
last_used="" last_ts="$now_ts"
[ -f "$UPDATED_CACHE" ] && read -r last_used last_ts < "$UPDATED_CACHE"
if [ "$USED" != "$last_used" ]; then
  last_ts="$now_ts"
  printf '%s %s\n' "$USED" "$now_ts" > "$UPDATED_CACHE"
fi
age_s=$((now_ts - last_ts))
if [ "$age_s" -lt 60 ]; then AGE_TXT="${age_s}s ago"
else AGE_TXT="$((age_s / 60))m ago"
fi

CTX_BAR=$(make_bar "$PCT" 4)
LINE1="[$MODEL${EFFORT:+ $EFFORT}] ${DIR##*/} ${CTX_BAR} $(pct_text "$PCT") (${USED_K}k/${MAX_K}k) | updated ${AGE_TXT}"

# rate_limits (and fable, which is never in the JSON at all) are scraped from
# `claude -p "/usage"`, cached and refreshed in the background every 15s so the
# statusline never blocks on it. This also backfills 5h/7d for brand-new sessions,
# whose rate_limits JSON is empty until the harness gets a first API response.
FABLE_CACHE="$HOME/.claude/.statusline_fable_cache"
FABLE_MAX_AGE=15
now=$(date +%s)
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
  ) & disown 2>/dev/null
fi

if [ -f "$FABLE_CACHE" ]; then
  # Regexes held in vars: a literal ( inside [[ =~ ]] confuses the [[ tokenizer.
  re_daily='Current session: ([0-9]+)'
  re_reset='resets ([^(]*)'
  re_week='Current week \(all models\): ([0-9]+)'
  re_fable='Current week \(Fable\): ([0-9]+)'
  while IFS= read -r line; do
    if [ -z "$DAILY" ] && [[ $line =~ $re_daily ]]; then
      DAILY=${BASH_REMATCH[1]}
      if [[ $line =~ $re_reset ]]; then
        DAILY_RESET_TXT=${BASH_REMATCH[1]%,}
        DAILY_RESET_TXT=${DAILY_RESET_TXT%"${DAILY_RESET_TXT##*[![:space:]]}"}  # rtrim
        # ponytail: reset-text to epoch is GNU-only (date -d free text); BSD date
        # cannot parse it. Only fires for a new session before the JSON rate_limits
        # arrive, so on macOS the 5h bar shows and the reset text waits for JSON.
        [ "$DATE_GNU" = 1 ] && [ -n "$DAILY_RESET_TXT" ] && DAILY_RESET=$(date -d "$DAILY_RESET_TXT" +%s 2>/dev/null)
      fi
    fi
    [ -z "$WEEKLY" ] && [[ $line =~ $re_week ]] && WEEKLY=${BASH_REMATCH[1]}
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
[ -n "$FABLE" ] && LINE2="${LINE2}${LINE2:+ | }fable $(make_bar "$FABLE" 4) $(pct_text "$FABLE")"

printf "%b\n" "$LINE1"
[ -n "$LINE2" ] && printf "%b\n" "$LINE2"
