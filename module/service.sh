#!/system/bin/sh
MODDIR=${0%/*}
mkdir -p /data/adb/ksu-bgfreeze
[ -f /data/adb/ksu-bgfreeze/blacklist.txt ] || cp "$MODDIR/config/blacklist.txt" /data/adb/ksu-bgfreeze/
chmod 755 "$MODDIR/bin/bgfreeze-daemon.sh" "$MODDIR/bin/apps.sh"
(
  sleep 10
  "$MODDIR/bin/bgfreeze-daemon.sh"
) &
