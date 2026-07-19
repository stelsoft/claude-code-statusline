#!/bin/bash
input=$(cat)

RESET="\033[0m"

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

# Parse the whole payload in one python pass (no jq dependency). Fields come
# back null-separated in a fixed order; python does the int-truncation and the
# token sum so the bash below stays unchanged.
mapfile -t -d '' _F < <(printf '%s' "$input" | python3 -c '
import sys, json
d = json.load(sys.stdin)
def g(o, *ks):
    for k in ks:
        o = o.get(k) if isinstance(o, dict) else None
    return o
def i(x):
    try: return str(int(float(x)))
    except (TypeError, ValueError): return ""
def raw(x):
    if x is None: return ""
    return str(int(x)) if isinstance(x, (int, float)) else str(x)
cw = lambda *k: g(d, "context_window", *k)
sys.stdout.write("\0".join([
    g(d, "model", "display_name") or "",
    g(d, "effort", "level") or "",
    g(d, "workspace", "current_dir") or "",
    g(d, "session_id") or "default",
    i(cw("used_percentage") or 0),
    str(int(cw("total_input_tokens") or 0) + int(cw("total_output_tokens") or 0)),
    str(int(cw("context_window_size") or 200000)),
    i(g(d, "rate_limits", "five_hour", "used_percentage")),
    raw(g(d, "rate_limits", "five_hour", "resets_at")),
    i(g(d, "rate_limits", "seven_day", "used_percentage")),
]))
')
MODEL=${_F[0]}
EFFORT=${_F[1]}
DIR=${_F[2]}
SESSION_ID=${_F[3]:-default}
PCT=${_F[4]:-0}
USED=${_F[5]:-0}
MAX=${_F[6]:-200000}
DAILY=${_F[7]}
DAILY_RESET=${_F[8]}
WEEKLY=${_F[9]}
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
# `claude -p "/usage"`, cached and refreshed in the background every 5min so the
# statusline never blocks on it. This also backfills 5h/7d for brand-new sessions,
# whose rate_limits JSON is empty until the harness gets a first API response.
FABLE_CACHE="$HOME/.claude/.statusline_fable_cache"
FABLE_MAX_AGE=15
now=$(date +%s)
mtime=0
[ -f "$FABLE_CACHE" ] && mtime=$(stat -c %Y "$FABLE_CACHE" 2>/dev/null || echo 0)
if [ $((now - mtime)) -gt "$FABLE_MAX_AGE" ] && [ ! -f "$FABLE_CACHE.lock" ]; then
  (
    touch "$FABLE_CACHE.lock"
    claude -p "/usage" 2>/dev/null > "$FABLE_CACHE.tmp" && mv "$FABLE_CACHE.tmp" "$FABLE_CACHE"
    rm -f "$FABLE_CACHE.lock"
  ) & disown 2>/dev/null
fi

if [ -f "$FABLE_CACHE" ]; then
  if [ -z "$DAILY" ]; then
    DAILY=$(grep -oP 'Current session: \K[0-9]+' "$FABLE_CACHE")
    DAILY_RESET_TXT=$(grep -oP 'Current session:.*resets \K[^(]*' "$FABLE_CACHE" | sed 's/ *$//; s/,//')
    [ -n "$DAILY_RESET_TXT" ] && DAILY_RESET=$(date -d "$DAILY_RESET_TXT" +%s 2>/dev/null)
  fi
  [ -z "$WEEKLY" ] && WEEKLY=$(grep -oP 'Current week \(all models\): \K[0-9]+' "$FABLE_CACHE")
  FABLE=$(grep -oP 'Current week \(Fable\): \K[0-9]+' "$FABLE_CACHE")
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
      reset_hhmm=$(date -d "@$DAILY_RESET" +%H:%M)
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

# When running inside a herdr pane, mirror the usage numbers onto that pane's
# sidebar row as a $claude_usage token. Fire-and-forget and deduped by last
# reported value so it never blocks the statusline or spams the socket.
# Flip to 1 to re-enable; the herdr sidebar row config is already wired up.
HERDR_SIDEBAR_USAGE=0
if [ "$HERDR_SIDEBAR_USAGE" = "1" ] && [ "$HERDR_ENV" = "1" ] && [ -n "$HERDR_PANE_ID" ]; then
  HERDR_BIN="${HERDR_BIN_PATH:-$(command -v herdr 2>/dev/null)}"
  HERDR_BIN="${HERDR_BIN:-$HOME/Programs/herdr-linux-x86_64}"
  if [ -x "$HERDR_BIN" ] || command -v "$HERDR_BIN" >/dev/null 2>&1; then
    HERDR_VAL=""
    [ -n "$DAILY" ] && HERDR_VAL="5h${DAILY}"
    [ -n "$WEEKLY" ] && HERDR_VAL="${HERDR_VAL}${HERDR_VAL:+ }7d${WEEKLY}"
    [ -n "$FABLE" ] && HERDR_VAL="${HERDR_VAL}${HERDR_VAL:+ }fb${FABLE}"
    HERDR_CACHE="$HOME/.claude/.statusline_herdr_last_${HERDR_PANE_ID//[:\/]/_}"
    LAST_VAL=$(cat "$HERDR_CACHE" 2>/dev/null)
    if [ "$HERDR_VAL" != "$LAST_VAL" ]; then
      (
        "$HERDR_BIN" pane report-metadata "$HERDR_PANE_ID" \
          --source claude-statusline \
          --token "claude_usage=$HERDR_VAL" \
          --ttl-ms 600000 >/dev/null 2>&1 \
        && printf '%s' "$HERDR_VAL" > "$HERDR_CACHE"
      ) & disown 2>/dev/null
    fi
  fi
fi
