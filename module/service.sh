#!/system/bin/sh
# Boot entry — thin glue; work is in bin/bgfreeze (Rust).
MODDIR=${0%/*}
DIR=/data/adb/ksu-bgfreeze
mkdir -p "$DIR"

[ -f "$MODDIR/disable" ] && exit 0

# Safe boot: force mode=stop unless user opted into disable-on-boot
if [ ! -f "$DIR/allow-disable-on-boot" ]; then
  echo stop > "$DIR/mode"
fi

[ -f "$DIR/blacklist.txt" ] || cp "$MODDIR/config/blacklist.txt" "$DIR/"
chmod 755 "$MODDIR/bin/bgfreeze" "$MODDIR/bin/bgfreeze-daemon.sh" \
  "$MODDIR/bin/apps.sh" "$MODDIR/bin/tombstone-lib.sh" 2>/dev/null

(
  sleep 45
  [ -f "$MODDIR/disable" ] && exit 0
  [ -f "$DIR/panic" ] && exit 0
  if [ -x "$MODDIR/bin/bgfreeze" ]; then
    "$MODDIR/bin/bgfreeze" daemon
  else
    echo "$(date '+%F %T') FATAL no bgfreeze binary" >> /data/local/tmp/ksu-bgfreeze.log
  fi
) &
