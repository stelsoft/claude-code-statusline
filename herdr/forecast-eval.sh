#!/usr/bin/env bash
# Score 5h forecasts: per window, actual = last pct seen; error = predicted - actual.
# Prints per-window mean/max abs error and overall, skipping the still-open window.
LOG="${1:-$HOME/.config/herdr/.claude-usage-cache.log}"
awk -v now="$(date +%s)" '
$4 != "" { n[$2]++; pred[$2, n[$2]] = ($4 > 100 ? 100 : $4); ts[$2, n[$2]] = $1 }
{ last[$2] = $3; seen[$2] = 1 }
END {
  for (r in seen) {
    if (r + 0 > now || !n[r]) continue
    sum = 0; mx = 0
    for (i = 1; i <= n[r]; i++) { d = pred[r, i] - last[r]; if (d < 0) d = -d; sum += d; if (d > mx) mx = d }
    printf "%s actual=%d%% n=%d mean_err=%.1f max_err=%d\n", strftime("%m-%d %H:%M", r), last[r], n[r], sum / n[r], mx
    tot += sum; cnt += n[r]
  }
  if (cnt) printf "overall mean_err=%.1f over %d forecasts\n", tot / cnt, cnt
  else print "no closed windows yet"
}' "$LOG"
