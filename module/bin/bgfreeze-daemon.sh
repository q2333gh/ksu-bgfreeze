#!/system/bin/sh
# Minimal POC: ONLY blacklist packages are frozen when backgrounded.
# No other apps/system behavior is touched.

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

freeze_uid() { for p in $(each_pid "$1"); do kill -STOP "$p" 2>/dev/null; done; }
thaw_uid()   { for p in $(each_pid "$1"); do kill -CONT "$p" 2>/dev/null; done; }

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
    [ -f "$DIR/frozen.$pkg" ] && continue

    freeze_uid "$uid"
    echo 1 > "$DIR/frozen.$pkg"
    log "freeze $pkg uid=$uid"
  done < "$LIST"

  sleep "$POLL"
done
