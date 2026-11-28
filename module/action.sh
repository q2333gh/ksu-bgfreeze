#!/system/bin/sh
# KernelSU「执行」：重启 daemon。禁止全表扫 /proc。
MODDIR=${0%/*}
DIR=/data/adb/ksu-bgfreeze
pidf=$DIR/daemon.pid
if [ -f "$pidf" ]; then
  pid=$(tr -d ' \t\r\n' < "$pidf" 2>/dev/null)
  case "$pid" in
    ''|*[!0-9]*) ;;
    *)
      if [ -r "/proc/$pid/cmdline" ]; then
        case "$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)" in
          *bgfreeze*)
            kill "$pid" 2>/dev/null
            kill -9 "$pid" 2>/dev/null
            ;;
        esac
      fi
      ;;
  esac
fi
if [ -f "$DIR/daemon.lock" ] && command -v fuser >/dev/null 2>&1; then
  fuser -k "$DIR/daemon.lock" >/dev/null 2>&1 || true
fi
rm -f "$pidf"
[ -f "$MODDIR/disable" ] && { echo "module disabled — not starting daemon"; exit 0; }
if [ -x "$MODDIR/bin/bgfreeze" ]; then
  "$MODDIR/bin/bgfreeze" daemon >/dev/null 2>&1 &
elif [ -x "$MODDIR/bin/bgfreeze-daemon.sh" ]; then
  "$MODDIR/bin/bgfreeze-daemon.sh" >/dev/null 2>&1 &
fi
echo "daemon restarted (no reboot needed)"
ver=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
echo "module $ver"
tail -n 8 /data/local/tmp/ksu-bgfreeze.log 2>/dev/null
