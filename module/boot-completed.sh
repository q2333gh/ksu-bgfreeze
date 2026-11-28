#!/system/bin/sh
MODDIR=${0%/*}
DIR=/data/adb/ksu-bgfreeze
[ -f "$MODDIR/disable" ] && exit 0
[ -f "$DIR/panic" ] && exit 0
chmod 755 "$MODDIR/bin/bgfreeze" "$MODDIR/bin/bgfreeze-daemon.sh" 2>/dev/null
(
  sleep 5
  [ -f "$MODDIR/disable" ] && exit 0
  [ -f "$DIR/panic" ] && exit 0
  [ -x "$MODDIR/bin/bgfreeze" ] && "$MODDIR/bin/bgfreeze" daemon
) &
