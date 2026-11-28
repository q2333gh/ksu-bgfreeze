#!/system/bin/sh
# Compatibility launcher → Rust daemon (O(T) snapshot).
MODDIR="${MODDIR:-/data/adb/modules/ksu-bgfreeze}"
BIN="$MODDIR/bin/bgfreeze"

if [ -x "$BIN" ]; then
  exec "$BIN" daemon
fi

# Fallback only if binary missing (should not happen in v0.5+)
LOG=/data/local/tmp/ksu-bgfreeze.log
echo "$(date '+%F %T') FATAL missing $BIN — refuse shell fallback (fail-fast)" >> "$LOG"
exit 1
