#!/bin/bash
# Claude limits for the herdr tab bar. Self-contained: scrapes `claude -p /usage`
# in the background (takes ~4s, herdr timeout is 2s) and prints the last cache.
CACHE="$HOME/.config/herdr/.claude-usage-cache"
MAX_AGE=5   # scrape ~every 10s with herdr interval 5s: shown data at most ~10s old
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
rdot() { if [ "$1" -le 3600 ]; then printf '🔴'; elif [ "$1" -le 7200 ]; then printf '🟡'; else printf '🟢'; fi; }

c=$(cat "$CACHE" 2>/dev/null) || exit 0
# Regexes in vars: a literal ( inside [[ =~ ]] confuses the [[ tokenizer.
re_day='Current session: ([0-9]+)% used · resets ([^(]*)'
re_week='Current week \(all models\): ([0-9]+)'
re_fable='Current week \(Fable\): ([0-9]+)'
[[ $c =~ $re_day ]] || exit 0
d=${BASH_REMATCH[1]} rtxt=${BASH_REMATCH[2]//,/}
[[ $c =~ $re_week ]] && w=${BASH_REMATCH[1]}
[[ $c =~ $re_fable ]] && f=${BASH_REMATCH[1]}

out="$(dot "$d") 5h $(bar "$d") $d%"
reset=$(date -d "$rtxt" +%s 2>/dev/null)
s=$(( ${reset:-0} - now ))
[ "$s" -gt 0 ] && out+=" ($(rdot "$s") resets in $((s/3600))h$(printf %02d $((s%3600/60)))m ($(date -d "@$reset" +%H:%M)))"
[ -n "$w" ] && out+=" | $(dot "$w") 7d $(bar "$w") $w%"
[ -n "$f" ] && out+=" | $(dot "$f") fable $(bar "$f") $f%"
echo "$out"
