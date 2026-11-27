#!/system/bin/sh
# Minimal POC: ONLY blacklist packages are frozen when backgrounded.
# No other apps/system behavior is touched.
#
# While frozen, re-assert SIGSTOP every poll so newly spawned
# processes (e.g. app :daemon keep-alives) cannot escape.
#
# Log (简要): /data/local/tmp/ksu-bgfreeze.log
#   freeze / thaw / WAKE(=对方试图拉起) / watch

MODDIR="${MODDIR:-/data/adb/modules/ksu-bgfreeze}"
DIR=/data/adb/ksu-bgfreeze
LIST=$DIR/blacklist.txt
[ -f "$LIST" ] || LIST=$MODDIR/config/blacklist.txt
LOG=/data/local/tmp/ksu-bgfreeze.log
DELAY=3
POLL=2
# Periodic snapshot while frozen (seconds between watch lines)
WATCH_EVERY=30

mkdir -p "$DIR"
echo $$ > "$DIR/daemon.pid"

log_rotate() {
  [ -f "$LOG" ] || return 0
  # ~200 KiB
  sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  [ "$sz" -gt 204800 ] 2>/dev/null || return 0
  mv -f "$LOG" "$LOG.1" 2>/dev/null
}

log() {
  log_rotate
  echo "$(date '+%F %T') $*" >> "$LOG"
}

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

# Short process tag: :daemon / :live / main / :foo
proc_tag() {
  pid=$1
  cmd=$(tr '\0' ' ' < /proc/"$pid"/cmdline 2>/dev/null)
  cmd=${cmd%% *}
  case "$cmd" in
    '') echo "pid$pid" ;;
    *:*) echo "${cmd##*:}" | sed 's/^/:/' ;;
    *) echo "main" ;;
  esac
}

# Snapshot: "total=N T=a run=b [main:T :daemon:S ...]"
snap_uid() {
  uid=$1
  total=0
  nt=0
  nr=0
  detail=
  for p in $(each_pid "$uid"); do
    st=$(awk '/^State:/{print $2;exit}' /proc/"$p"/status 2>/dev/null) || continue
    tag=$(proc_tag "$p")
    total=$((total + 1))
    if [ "$st" = "T" ]; then
      nt=$((nt + 1))
    else
      nr=$((nr + 1))
    fi
    detail="$detail $tag:$st"
  done
  echo "total=$total T=$nt run=$nr [${detail# }]"
}

# STOP every non-T process of uid; echo count newly stopped.
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

log "start pid=$$ list=$LIST poll=${POLL}s delay=${DELAY}s"

while true; do
  fg=$(fg_pkg)
  [ -f "$LIST" ] || { sleep "$POLL"; continue; }

  while IFS= read -r pkg || [ -n "$pkg" ]; do
    case "$pkg" in ''|\#*) continue ;; esac
    uid=$(uid_of "$pkg")
    [ -n "$uid" ] || continue

    if [ "$pkg" = "$fg" ]; then
      rm -f "$DIR/bg.$pkg" "$DIR/watch.$pkg"
      if [ -f "$DIR/frozen.$pkg" ]; then
        before=$(snap_uid "$uid")
        thaw_uid "$uid"
        rm -f "$DIR/frozen.$pkg"
        after=$(snap_uid "$uid")
        log "thaw $pkg uid=$uid before{$before} after{$after}"
      fi
      continue
    fi

    [ -f "$DIR/bg.$pkg" ] || echo "$(date +%s)" > "$DIR/bg.$pkg"
    since=$(cat "$DIR/bg.$pkg" 2>/dev/null || echo 0)
    now=$(date +%s)
    [ $((now - since)) -ge "$DELAY" ] || continue

    before=$(snap_uid "$uid")
    added=$(freeze_uid "$uid")
    after=$(snap_uid "$uid")

    if [ ! -f "$DIR/frozen.$pkg" ]; then
      echo 1 > "$DIR/frozen.$pkg"
      echo "$now" > "$DIR/watch.$pkg"
      log "freeze $pkg uid=$uid stopped=$added before{$before} after{$after}"
    elif [ "${added:-0}" -gt 0 ] 2>/dev/null; then
      # 对方（如应用宝 :daemon）在冻结期间又拉起进程 → WAKE，再被我们 STOP
      run_before=$(echo "$before" | sed -n 's/.*run=\([0-9]*\).*/\1/p')
      run_after=$(echo "$after" | sed -n 's/.*run=\([0-9]*\).*/\1/p')
      log "WAKE $pkg uid=$uid new=$added run:$run_before->$run_after before{$before} after{$after}"
      echo "$now" > "$DIR/watch.$pkg"
    else
      # Fully frozen: quiet, with a watch heartbeat
      lastw=$(cat "$DIR/watch.$pkg" 2>/dev/null || echo 0)
      if [ $((now - lastw)) -ge "$WATCH_EVERY" ]; then
        log "watch $pkg uid=$uid $after"
        echo "$now" > "$DIR/watch.$pkg"
      fi
    fi
  done < "$LIST"

  sleep "$POLL"
done
