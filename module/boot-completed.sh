#!/system/bin/sh
MODDIR=${0%/*}
p=/data/adb/ksu-bgfreeze/daemon.pid
[ -f "$p" ] && [ -d "/proc/$(cat "$p")" ] && exit 0
chmod 755 "$MODDIR/bin/bgfreeze-daemon.sh"
"$MODDIR/bin/bgfreeze-daemon.sh" &
