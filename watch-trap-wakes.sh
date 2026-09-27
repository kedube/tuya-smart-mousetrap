#!/bin/bash
# Logs every time the trap wakes up, to find out how often it checks in on its own.
# Leave it running overnight or longer, with the computer plugged in. On macOS it stops the
# computer from idle-sleeping while it runs; elsewhere, turn off sleep yourself. No password needed: any answer from the trap's web server
# means it's awake. It only asks for the main page, so it's safe to run alongside
# update-trap.sh or capture-trap-log.sh.
#
# Usage: ./watch-trap-wakes.sh [trap-ip]   (Ctrl+C to stop; the IP can also go in trap.conf)

cd "$(dirname "$0")" || exit 1
# The trap's IP address: the first argument, else TRAP_IP from the environment or from trap.conf
[ -z "${TRAP_IP:-}" ] && [ -f trap.conf ] && TRAP_IP=$(sed -n 's/^TRAP_IP=//p' trap.conf | tail -n 1 | tr -d "\"' \r")
IP="${1:-$TRAP_IP}"
if [ -z "$IP" ]; then
  echo "Usage: $0 <trap-ip>   (or put TRAP_IP=<trap-ip> in trap.conf; see trap.conf.example)"; exit 1
fi
OUT="logs/wakes-$(date +%Y%m%d-%H%M%S).log"
mkdir -p logs
if command -v caffeinate >/dev/null 2>&1; then
  caffeinate -i -w $$ &
else
  echo "Keep this computer from going to sleep while this runs."
fi

echo "Watching $IP; wakes are logged to $OUT (Ctrl+C to stop)."
awake=0; fails=0; prev=""; start=0; seen=0
while :; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 0.5 --max-time 1 "http://$IP/")
  now=$(date +%s)
  if [ "$code" != 000 ]; then
    fails=0; seen=$now
    if [ $awake = 0 ]; then
      awake=1; start=$now
      gap=""
      if [ -n "$prev" ]; then
        s=$((now - prev)); m=$((s / 60))
        if [ $s -lt 60 ]; then gap="$s s"
        elif [ $m -lt 60 ]; then gap="$m min"
        else gap="$((m / 60)) h $((m % 60)) min"; fi
        gap=", $gap after the previous wake"
      fi
      echo "$(date '+%Y-%m-%d %H:%M:%S') woke up$gap" | tee -a "$OUT"
      prev=$now
    fi
  else
    fails=$((fails + 1))
    # Single missed answers are normal while it's awake; 5 in a row means it's off
    if [ $awake = 1 ] && [ $fails -ge 5 ]; then
      awake=0
      echo "$(date '+%Y-%m-%d %H:%M:%S')   asleep again (awake about $((seen - start + 1)) s)" | tee -a "$OUT"
    fi
  fi
  sleep 1
done
