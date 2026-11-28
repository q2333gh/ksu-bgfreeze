#!/system/bin/sh
# Run as root on a half-booted / recovered OP12:
#   adb shell su -c 'sh /data/adb/modules/ksu-bgfreeze/bin/apps.sh emergency'
# or copy this script and: su -c 'sh emergency-recover.sh'
DIR=/data/adb/ksu-bgfreeze
MOD=/data/adb/modules/ksu-bgfreeze

# 1) Stop freezer daemon
for st in /proc/[0-9]*/cmdline; do
  [ -f "$st" ] || continue
  cmd=$(tr '\0' ' ' < "$st" 2>/dev/null)
  case "$cmd" in
    *bgfreeze-daemon.sh*)
      pid=${st#/proc/}; pid=${pid%/cmdline}
      kill -9 "$pid" 2>/dev/null || true
      ;;
  esac
done
rm -f "$DIR/daemon.pid"

# 2) Disable module for next boot (KernelSU)
touch "$MOD/disable" 2>/dev/null || true

# 3) Force SIGSTOP mode
mkdir -p "$DIR"
echo stop > "$DIR/mode"
rm -f "$DIR/allow-disable-on-boot" "$DIR/panic"
: > "$DIR/blacklist.txt"

# 4) Re-enable disabled packages (best effort)
pm list packages -d 2>/dev/null | sed 's/^package://' | while read -r p; do
  [ -n "$p" ] || continue
  pm enable --user 0 "$p" >/dev/null 2>&1 || pm enable "$p" >/dev/null 2>&1 || true
done

# 5) Clear markers
rm -f "$DIR"/tombstone.* "$DIR"/frozen.* "$DIR"/bg.* "$DIR"/watch.* "$DIR"/comps-* 

# 6) Nudge SystemUI / launcher if present
am start-service -n com.android.systemui/.SystemUIService >/dev/null 2>&1 || true
am force-stop com.android.systemui >/dev/null 2>&1 || true
# After force-stop, zygote usually restarts SystemUI
sleep 2
input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true

echo RECOVER_OK
echo "Reboot recommended. Module is flagged disable for next boot."
