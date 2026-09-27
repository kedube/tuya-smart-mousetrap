#!/bin/bash
# Sends openbeken/autoexec.bat to the trap while it runs on batteries, then shows what it reports.
# The trap is only awake for about 15 seconds after you switch it on. This waits for it to wake,
# runs the datapoint and naming lines from autoexec.bat straight away (so that same wake already
# reports with them), re-sends Home Assistant discovery, uploads autoexec.bat for every later
# wake, and then checks the trap's battery report.
# Everything the trap logs is also saved to logs/, like capture-trap-log.sh does.
#
# Usage: ./update-trap.sh [trap-ip]   (Ctrl+C to stop; the IP can also go in trap.conf)
# Don't run capture-trap-log.sh at the same time: both read the same log and would split it.

cd "$(dirname "$0")" || exit 1
# The trap's IP address: the first argument, else TRAP_IP from the environment or from trap.conf
[ -z "${TRAP_IP:-}" ] && [ -f trap.conf ] && TRAP_IP=$(sed -n 's/^TRAP_IP=//p' trap.conf | tail -n 1 | tr -d "\"' \r")
IP="${1:-$TRAP_IP}"
if [ -z "$IP" ]; then
  echo "Usage: $0 <trap-ip>   (or put TRAP_IP=<trap-ip> in trap.conf; see trap.conf.example)"; exit 1
fi
FILE=openbeken/autoexec.bat
LOG="logs/trap-$(date +%Y%m%d-%H%M%S).log"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
mkdir -p logs

read -r -s -p "OpenBeken admin password (blank if none): " PW
echo
AUTH=()
[ -n "$PW" ] && AUTH=(-u "admin:$PW")

# Lines that are safe to run on a running trap: the battery line first (the trap sends its
# battery value about 3 seconds after waking), then the other mappings, types, names, flags
# and change handlers (a repeat of one from boot just runs twice, which is harmless)
BATTERY_LINE=$(grep -m1 '^linkTuyaMCUOutputToChannel 102 ' "$FILE")
LIVE=()
while IFS= read -r line; do LIVE+=("$line"); done < <(
  echo "$BATTERY_LINE"
  grep -E '^(linkTuyaMCUOutputToChannel|setChannelType|SetChannelEnum|SetChannelLabel|SetFlag|addChangeHandler) ' "$FILE" | grep -vF "$BATTERY_LINE"
  echo "scheduleHADiscovery 1"
)
# value = (raw + delta) * mult, from: linkTuyaMCUOutputToChannel 102 enum 2 [flags] [mult] [inv] [delta]
set -- $BATTERY_LINE
MULT=${6:-1}; DELTA=${8:-0}
SIZE=$(wc -c < "$FILE" | tr -d ' ')

# Moves the trap's new log lines into $LOG (OpenBeken hands each line out once), with the Wi-Fi
# password redacted and the trap's CR-LF line ends turned into plain LF.
# Prints the HTTP status: 200 = awake, 401 = wrong password, 000 = asleep.
read_log() {
  local code
  : > "$TMP"
  code=$(curl -s -o "$TMP" -w '%{http_code}' --connect-timeout 0.3 --max-time 2 "${AUTH[@]}" "http://$IP/lograw")
  if [ "$code" = 200 ] && [ -s "$TMP" ]; then
    tr -d '\r' < "$TMP" | sed -E -e 's/(Pass2? *\[)[^]]*/\1<redacted>/g' -e "s/^/[$(date +%H:%M:%S)] /" >> "$LOG"
  fi
  echo "$code"
}

# Prints "<battery reports> <code the trap sent> <% published> <mouse killed> <low voltage>
# <discovery messages> <trap armed>" from the log, using "-" for anything not reported.
reports() {
  awk '
    { sub(/\r$/, "") }
    /processing id 102,/ { want = 1; next }
    want == 1 && /RecordStorage: byte / { raw = $NF; want = 2; next }
    # Discovery shows up as "Queued topic=.../config" and later "Publishing val ... to .../config"
    /\/config/ && (/Queued topic=/ || /Publishing val .* to /) {
      t = $0; sub(/.*(topic=| to )/, "", t); sub(/[ ,].*/, "", t)
      if (!(t in cfg)) { cfg[t] = 1; disc++ }
    }
    /Publishing val .* to [^ ]*\/[1234]\/get/ {
      for (i = 1; i <= NF; i++) if ($i == "val") v = $(i + 1)
      if ($0 ~ /\/1\/get/) st = v
      if ($0 ~ /\/3\/get/) low = v
      if ($0 ~ /\/4\/get/) arm = v
      if ($0 ~ /\/2\/get/ && want == 2) { n++; code = raw; pct = v; want = 0 }
    }
    END { print n + 0, (code == "" ? "-" : code), (pct == "" ? "-" : pct), (st == "" ? "-" : st), (low == "" ? "-" : low), disc + 0, (arm == "" ? "-" : arm) }
  ' "$LOG" 2>/dev/null
}

cmnd() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 0.5 --max-time 3 "${AUTH[@]}" -X POST --data-binary "$1" "http://$IP/api/cmnd")" = 200 ]
}

echo "Log: $LOG"
echo "Switch the trap off, wait 5 seconds, then switch it back on."

awake=0; fails=0; applied=0; uploaded=0; seen=0; good=0
while :; do
  code=$(read_log)
  if [ "$code" = 401 ]; then
    echo "The trap rejected the password."; exit 1
  elif [ "$code" = 200 ]; then
    fails=0
    if [ $awake = 0 ]; then
      awake=1; applied=0
      echo "$(date +%H:%M:%S) Trap awake."
    fi
    if [ $applied = 0 ]; then
      applied=1
      failed=()
      # One retry for a dropped request; reading the log between commands keeps the trap's
      # small log buffer from overflowing while it's busy
      for c in "${LIVE[@]}"; do cmnd "$c" || cmnd "$c" || failed+=("$c"); read_log > /dev/null; done
      if [ ${#failed[@]} = 0 ]; then
        echo "$(date +%H:%M:%S) New settings active; Home Assistant discovery started."
      else
        echo "$(date +%H:%M:%S) These didn't run (retrying on the next wake):"; printf '    %s\n' "${failed[@]}"
      fi
    fi
    if [ $uploaded = 0 ]; then
      resp=$(curl -s --max-time 5 "${AUTH[@]}" -X POST --data-binary @"$FILE" "http://$IP/api/lfs/autoexec.bat")
      if [[ $resp == *"\"size\":$SIZE"* ]]; then
        uploaded=1
        echo "$(date +%H:%M:%S) autoexec.bat uploaded ($SIZE bytes)."
      fi
    fi
  else
    fails=$((fails + 1))
    # Single missed polls are normal while it's awake; ~4 s of silence means it's off
    if [ $awake = 1 ] && [ $fails -ge 8 ]; then
      awake=0
      echo "$(date +%H:%M:%S) Trap asleep."
      if [ $uploaded = 0 ] || [ $good = 0 ] || [ "$disc" = 0 ]; then
        echo "Not finished yet. Switch the trap off, wait 5 seconds, and on again."
      fi
    fi
  fi

  set -- $(reports)
  n=${1:-0}; raw=$2; pct=$3; st=$4; low=$5; disc=${6:-0}; arm=$7
  if [ "$n" -gt "$seen" ]; then
    seen=$n
    if [ "$pct" = "$(( (raw + DELTA) * MULT ))" ]; then
      good=1
    else
      good=0
      echo "$(date +%H:%M:%S) That battery report came in before the new settings."
    fi
  fi
  if [ $good = 1 ] && [ $uploaded = 1 ] && [ "$disc" -gt 0 ]; then
    case $st in 0) st="No" ;; 1) st="Yes" ;; *) st="not reported" ;; esac
    case $low in 1) low="On - replace the batteries" ;; 0) low="Off" ;; *) low="not set yet" ;; esac
    case $arm in 1) arm="Yes" ;; 0) arm="No" ;; *) arm="not set yet" ;; esac
    echo
    echo "Published to Home Assistant:"
    echo "  Armed:        $arm"
    echo "  Mouse killed: $st"
    echo "  Battery:      $pct % (trap sent code $raw)"
    echo "  Low voltage:  $low"
    echo "  Discovery:    $disc entities sent to Home Assistant"
    echo "autoexec.bat is on the trap, so every wake from now on uses these settings."
    exit 0
  fi
  sleep 0.2
done
