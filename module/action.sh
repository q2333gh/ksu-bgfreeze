#!/system/bin/sh
MODDIR=${0%/*}
p=/data/adb/ksu-bgfreeze/daemon.pid
[ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null
sleep 1
"$MODDIR/bin/bgfreeze-daemon.sh" &
echo "restarted"
tail -n 15 /data/local/tmp/ksu-bgfreeze.log 2>/dev/null
