#!/system/bin/sh
p=/data/adb/ksu-bgfreeze/daemon.pid
[ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null
rm -rf /data/adb/ksu-bgfreeze /data/local/tmp/ksu-bgfreeze.log
# icons live under ksu-bgfreeze/icons — removed with dir above
