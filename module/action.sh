#!/system/bin/sh
# KernelSU「执行」按钮：只重启守护进程，不需要重启手机。
# WebUI 热更：直接改 /data/adb/modules/ksu-bgfreeze/webroot/ 后，
# 强停 KernelSU 再开 WebUI 即可；开关模块要等下次重启才生效，对热更无意义。
MODDIR=${0%/*}
DIR=/data/adb/ksu-bgfreeze
pidf=$DIR/daemon.pid
[ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null
if command -v pkill >/dev/null 2>&1; then
  pkill -f 'bgfreeze-daemon\.sh' 2>/dev/null
else
  for st in /proc/[0-9]*/cmdline; do
    [ -f "$st" ] || continue
    if tr '\0' ' ' < "$st" 2>/dev/null | grep -q 'bgfreeze-daemon\.sh'; then
      pid=${st#/proc/}; pid=${pid%/cmdline}
      kill "$pid" 2>/dev/null
    fi
  done
fi
sleep 1
"$MODDIR/bin/bgfreeze-daemon.sh" &
echo "daemon restarted (no reboot needed)"
echo "WebUI: force-stop KernelSU app, reopen module WebUI"
ver=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
echo "module $ver webroot ready"
tail -n 12 /data/local/tmp/ksu-bgfreeze.log 2>/dev/null

