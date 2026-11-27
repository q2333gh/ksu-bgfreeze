#!/system/bin/sh
MODDIR=${0%/*}
DIR=/data/adb/ksu-bgfreeze
pidf=$DIR/daemon.pid
[ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null
for st in /proc/[0-9]*/cmdline; do
  [ -f "$st" ] || continue
  if tr '\0' ' ' < "$st" 2>/dev/null | grep -q 'bgfreeze-daemon\.sh'; then
    pid=${st#/proc/}; pid=${pid%/cmdline}
    kill "$pid" 2>/dev/null
  fi
done
sleep 1
"$MODDIR/bin/bgfreeze-daemon.sh" &
echo "restarted"
tail -n 15 /data/local/tmp/ksu-bgfreeze.log 2>/dev/null
