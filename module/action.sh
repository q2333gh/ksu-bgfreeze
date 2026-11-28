#!/system/bin/sh
# KernelSU「执行」按钮：只重启守护进程，不需要重启手机。
# 禁止全表扫 /proc（会卡 WebUI / 管理器）。
MODDIR=${0%/*}
DIR=/data/adb/ksu-bgfreeze
pidf=$DIR/daemon.pid
if [ -f "$pidf" ]; then
  pid=$(tr -d ' \t\r\n' < "$pidf" 2>/dev/null)
  case "$pid" in
    ''|*[!0-9]*) ;;
    *) kill "$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null ;;
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
echo "WebUI: force-stop KernelSU app, reopen module WebUI"
ver=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
echo "module $ver webroot ready"
tail -n 12 /data/local/tmp/ksu-bgfreeze.log 2>/dev/null
