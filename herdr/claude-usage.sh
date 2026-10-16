#!/bin/bash
# Claude limits for the herdr tab bar. Self-contained: scrapes `claude -p /usage`
# in the background (takes ~4s, herdr timeout is 2s) and prints the last cache.
CACHE="$HOME/.config/herdr/.claude-usage-cache"
MAX_AGE=10  # scrape ~every 15s with herdr interval 5s: shown data at most ~15s old
now=$(date +%s)
mtime=$(stat -c %Y "$CACHE" 2>/dev/null || echo 0)
lock_mtime=$(stat -c %Y "$CACHE.lock" 2>/dev/null || echo 0)
[ -f "$CACHE.lock" ] && [ $((now - lock_mtime)) -gt 60 ] && rm -f "$CACHE.lock" "$CACHE.tmp"
if [ $((now - mtime)) -gt "$MAX_AGE" ] && [ ! -f "$CACHE.lock" ]; then
  # setsid: herdr kills the command's process group once it exits, which took
  # the background scrape with it. A new session survives that kill.
  touch "$CACHE.lock"
  setsid -f bash -c 'cd "$HOME" && claude -p "/usage" > "$1.tmp" 2>/dev/null && mv "$1.tmp" "$1"; rm -f "$1.lock"' \
    _ "$CACHE" >/dev/null 2>&1 </dev/null
fi

bar() { local h=$(( ($1*8+99)/100 )) b="" p; [ "$h" -gt 8 ] && h=8; [ "$h" -eq 8 ] && [ "$1" -lt 100 ] && h=7
  local f=$((h/2)) x=$((h%2))
  [ "$f" -gt 0 ] && printf -v p '%*s' "$f" '' && b=${p// /▓}
  [ "$x" = 1 ] && b+=▒
  [ $((4-f-x)) -gt 0 ] && printf -v p '%*s' $((4-f-x)) '' && b+=${p// /░}
  printf '%s' "$b"; }
# Same thresholds as ~/.claude/statusline.sh: percent 80 red / 50 yellow / else plain,
# reset countdown 1h red / 2h yellow / else green.
dot() { if [ "$1" -ge 80 ]; then printf '🔴'; elif [ "$1" -ge 50 ]; then printf '🟡'; else printf '⚫'; fi; }
pdot() { if [ "$1" -ge 100 ]; then printf '🔴'; elif [ "$1" -ge 95 ]; then printf '🟡'; elif [ "$1" -ge 90 ]; then printf '🟢'; else printf '⚫'; fi; }
rdot() { if [ "$1" -le 3600 ]; then printf '🔴'; elif [ "$1" -le 7200 ]; then printf '🟡'; else printf '🟢'; fi; }

c=$(cat "$CACHE" 2>/dev/null) || exit 0
# Regexes in vars: a literal ( inside [[ =~ ]] confuses the [[ tokenizer.
re_day='Current session: ([0-9]+)% used( · resets ([^(]*))?'
re_week='Current week \(all models\): ([0-9]+)'
re_fable='Current week \(Fable\): ([0-9]+)'
[[ $c == *"% used"* ]] || exit 0
# After the 5h limit resets, until the next message opens a new window, /usage
# drops the session line (or its "resets" part): that is 0% with no countdown.
d=0 rtxt=""
[[ $c =~ $re_day ]] && d=${BASH_REMATCH[1]} rtxt=${BASH_REMATCH[3]//,/}
[[ $c =~ $re_week ]] && w=${BASH_REMATCH[1]}
[[ $c =~ $re_fable ]] && f=${BASH_REMATCH[1]}
reset=$([ -n "$rtxt" ] && date -d "$rtxt" +%s 2>/dev/null)
# The headless scrape lags the real 5h number badly (52% vs 75%). statusline.sh
# writes the true one from rate-limit headers: "<pct> <ts> <resets_at>". Within a
# window usage only grows, so both are lower bounds and the higher one is nearer
# the truth; after a roll the scrape can sit on the old window for minutes.
UTS="$HOME/.claude/.statusline_usage_ts"
if read -r up _ ur < "$UTS" 2>/dev/null && [ "${ur:-0}" -gt "$now" ]; then
  up=${up%.*} gap=$((ur - ${reset:-0}))
  if [ "$gap" -gt 3600 ]; then d=$up reset=$ur           # scrape still on the rolled window
  elif [ "${gap#-}" -le 3600 ]; then                     # same window (scrape rounds the minute)
    reset=$ur; [ "${up:-0}" -gt "$d" ] && d=$up
  fi                                                     # else the scrape saw a newer window
fi
[ "${reset:-0}" -le "$now" ] && d=0 reset=""             # rolled, nothing fresher known yet

out="$(dot "$d") 5h $(bar "$d") $d%"
s=$(( ${reset:-0} - now ))
if [ "$s" -gt 0 ]; then
  [ "$s" -ge 3600 ] && left="$((s/3600))h$(printf %02d $((s%3600/60)))m" || left="$((s/60))m"
  out+=" $(rdot "$s") $left $(date -d "@$reset" +%H:%M)"
  # Forecast from the last 30 min of samples: pct moves in steps as workflows
  # start and stop, so the whole-window average lags the current burn. Samples
  # live in "<ts> <pct>" lines; older ones and the previous window are dropped.
  HIST="$CACHE.hist" keep="" t0="" p0="" lp=""
  while read -r ts pct; do
    [ "$ts" -ge $((now - 1800)) ] && [ "$ts" -ge $((reset - 18000)) ] || continue
    [ -z "$t0" ] && t0=$ts p0=$pct
    keep+="$ts $pct"$'\n' lp=$pct
  done < "$HIST" 2>/dev/null
  [ "$lp" != "$d" ] && keep+="$now $d"$'\n'
  printf '%s' "$keep" > "$HIST"
  if [ -n "$t0" ] && [ $((now - t0)) -ge 300 ]; then el=$((now - t0)) dp=$((d - p0))
  elif [ -z "$t0" ] || [ "$p0" -gt 0 ]; then el=$((18000 - s)) dp=$d  # too few samples: window average
  else el=0 dp=0                                         # burn just started from 0%: average over idle hours would read ~1%
  fi
  p=""
  if [ "$el" -ge 300 ] && [ "$dp" -gt 0 ]; then
    p=$((d + dp * s / el))
    t=$((el * (100 - d) / dp))
    [ "$t" -ge 3600 ] && hit="$((t/3600))h$(printf %02d $((t%3600/60)))m" || hit="$((t/60))m"
    if [ "$p" -ge 100 ]; then out+=" → 🔴 100% in$hit"
    else out+=" → $(pdot "$p") $p%"
    fi
  fi
  # Append-only stats: "<ts> <reset> <pct> <predicted>" per change, to check
  # forecasts against the last pct of each window.
  [ "$lp" != "$d" ] && echo "$now $reset $d $p" >> "$CACHE.log"
fi
[ -n "$w" ] && out+=" | $(dot "$w") 7d $(bar "$w") $w%"
[ -n "$f" ] && out+=" | $(dot "$f") fable $(bar "$f") $f%"
echo "$out"
