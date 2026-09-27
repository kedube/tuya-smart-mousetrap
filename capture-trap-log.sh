#!/bin/bash
# Captures OpenBeken's log from the trap during its short battery-powered wake-ups.
# OpenBeken keeps a small in-memory log and serves it at /lograw; this polls it
# rapidly while the trap is awake and appends everything to a timestamped file.
#
# Usage: ./capture-trap-log.sh [trap-ip]   (Ctrl+C to stop; the IP can also go in trap.conf)

cd "$(dirname "$0")" || exit 1
# The trap's IP address: the first argument, else TRAP_IP from the environment or from trap.conf
[ -z "${TRAP_IP:-}" ] && [ -f trap.conf ] && TRAP_IP=$(sed -n 's/^TRAP_IP=//p' trap.conf | tail -n 1 | tr -d "\"' \r")
IP="${1:-$TRAP_IP}"
if [ -z "$IP" ]; then
  echo "Usage: $0 <trap-ip>   (or put TRAP_IP=<trap-ip> in trap.conf; see trap.conf.example)"; exit 1
fi
OUT="logs/trap-$(date +%Y%m%d-%H%M%S).log"
mkdir -p logs

read -r -s -p "OpenBeken admin password (blank if none): " PW
echo
AUTH=()
[ -n "$PW" ] && AUTH=(-u "admin:$PW")

echo "Logging $IP to $OUT"
echo "Now wake the trap (flip the arm switch). Press Ctrl+C when done."

online=0
while true; do
  chunk=$(curl -s --connect-timeout 0.3 --max-time 2 "${AUTH[@]}" "http://$IP/lograw")
  rc=$?
  now=$(perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%03d", strftime("%H:%M:%S", localtime $t), ($t-int $t)*1000')
  if [ $rc -eq 0 ]; then
    if [ $online -eq 0 ]; then
      echo "=== $now trap ONLINE ===" | tee -a "$OUT"
      online=1
    fi
    if [ -n "$chunk" ]; then
      # OpenBeken logs the Wi-Fi password at boot ("Using Pass [...]"); never write it to disk
      printf '%s\n' "$chunk" | tr -d '\r' | sed -E -e 's/(Pass2? *\[)[^]]*/\1<redacted>/g' -e "s/^/[$now] /" >> "$OUT"
    fi
    sleep 0.2
  else
    if [ $online -eq 1 ]; then
      echo "=== $now trap OFFLINE ===" | tee -a "$OUT"
      online=0
    fi
  fi
done
