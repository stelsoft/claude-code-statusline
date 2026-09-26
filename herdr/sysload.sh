#!/bin/bash
# CPU and memory for the herdr tab bar. CPU is the average since the previous
# run (herdr calls this every 5s), from a /proc/stat sample kept in a state file.
STATE="$HOME/.config/herdr/.sysload-state"
bar() { local h=$(( ($1*8+99)/100 )) b="" p; [ "$h" -gt 8 ] && h=8; [ "$h" -eq 8 ] && [ "$1" -lt 100 ] && h=7
  local f=$((h/2)) x=$((h%2))
  [ "$f" -gt 0 ] && printf -v p '%*s' "$f" '' && b=${p// /▓}
  [ "$x" = 1 ] && b+=▒
  [ $((4-f-x)) -gt 0 ] && printf -v p '%*s' $((4-f-x)) '' && b+=${p// /░}
  printf '%s' "$b"; }
dot() { if [ "$1" -ge 80 ]; then printf '🔴'; elif [ "$1" -ge 50 ]; then printf '🟡'; else printf '⚫'; fi; }

read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
total=$((user + nice + system + idle + iowait + irq + softirq + steal))
busy=$((total - idle - iowait))
cpu=""
if [ -f "$STATE" ] && read -r p_total p_busy < "$STATE" && [ $((total - p_total)) -gt 0 ]; then
  cpu=$(( (busy - p_busy) * 100 / (total - p_total) ))
fi
printf '%s %s\n' "$total" "$busy" > "$STATE"

while read -r k v _; do case $k in MemTotal:) mt=$v;; MemAvailable:) ma=$v;; esac; done < /proc/meminfo
mem=$(( (mt - ma) * 100 / mt ))
used_g=$(( (mt - ma) / 1024 / 1024 ))
used_d=$(( ((mt - ma) / 1024 % 1024) * 10 / 1024 ))

out=""
[ -n "$cpu" ] && out="$(dot "$cpu") cpu $(bar "$cpu") $cpu%"
out+="${out:+ | }$(dot "$mem") mem $(bar "$mem") $mem% ${used_g}.${used_d}G"
echo "$out"
