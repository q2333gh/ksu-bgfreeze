#!/system/bin/sh
# Minimal POC: ONLY blacklist packages are frozen when backgrounded.
# No other apps/system behavior is touched.
#
# While frozen, re-assert SIGSTOP every poll so newly spawned
# processes (e.g. :daemon keep-alives) cannot escape.

MODDIR="${MODDIR:-/data/adb/modules/ksu-bgfreeze}"
DIR=/data/adb/ksu-bgfreeze
LIST=$DIR/blacklist.txt
[ -f "$LIST" ] || LIST=$MODDIR/config/blacklist.txt
LOG=/data/local/tmp/ksu-bgfreeze.log
DELAY=3
POLL=2

mkdir -p "$DIR"
echo $$ > "$DIR/daemon.pid"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

fg_pkg() {
  dumpsys activity activities 2>/dev/null \
    | grep -E 'mResumedActivity|topResumedActivity' | head -1 \
    | sed -n 's/.* \([a-zA-Z0-9._][a-zA-Z0-9._]*\)\/.*/\1/p'
}

uid_of() {
  awk -v p="$1" '$1==p{print $2;exit}' /data/system/packages.list 2>/dev/null
}

each_pid() {
  uid=$1
  for st in /proc/[0-9]*/status; do
    [ -f "$st" ] || continue
    u=$(awk '/^Uid:/{print $2;exit}' "$st" 2>/dev/null)
    [ "$u" = "$uid" ] || continue
    pid=${st#/proc/}; pid=${pid%/status}
    echo "$pid"
  done
}

# STOP every live process of uid; count newly stopped (were not T).
freeze_uid() {
  uid=$1
  n=0
  for p in $(each_pid "$uid"); do
    st=$(awk '/^State:/{print $2;exit}' /proc/"$p"/status 2>/dev/null)
    [ "$st" = "T" ] && continue
    kill -STOP "$p" 2>/dev/null || continue
    n=$((n + 1))
  done
  echo "$n"
}

thaw_uid() {
  for p in $(each_pid "$1"); do
    kill -CONT "$p" 2>/dev/null
  done
}

log "start list=$LIST"

while true; do
  fg=$(fg_pkg)
  [ -f "$LIST" ] || { sleep "$POLL"; continue; }

  while IFS= read -r pkg || [ -n "$pkg" ]; do
    case "$pkg" in ''|\#*) continue ;; esac
    uid=$(uid_of "$pkg")
    [ -n "$uid" ] || continue

    if [ "$pkg" = "$fg" ]; then
      rm -f "$DIR/bg.$pkg"
      if [ -f "$DIR/frozen.$pkg" ]; then
        thaw_uid "$uid"
        rm -f "$DIR/frozen.$pkg"
        log "thaw $pkg"
      fi
      continue
    fi

    [ -f "$DIR/bg.$pkg" ] || echo "$(date +%s)" > "$DIR/bg.$pkg"
    since=$(cat "$DIR/bg.$pkg" 2>/dev/null || echo 0)
    now=$(date +%s)
    [ $((now - since)) -ge "$DELAY" ] || continue

    # First freeze or re-assert: always STOP non-T pids of this uid.
    added=$(freeze_uid "$uid")
    if [ ! -f "$DIR/frozen.$pkg" ]; then
      echo 1 > "$DIR/frozen.$pkg"
      log "freeze $pkg uid=$uid"
    elif [ "${added:-0}" -gt 0 ] 2>/dev/null; then
      log "refreeze $pkg uid=$uid new=$added"
    fi
  done < "$LIST"

  sleep "$POLL"
done
