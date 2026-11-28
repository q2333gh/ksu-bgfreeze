#!/system/bin/sh
# Hail-style helpers. Systems rules for WebUI/shell glue:
# - Fail-fast, no Binder retry storms
# - Absolute paths for am/pm when possible
# - At most ONE pm list packages -d per operation (cached)
# - Never walk all /proc from WebUI-facing paths
# - Prefer ps -A over /proc glob; /proc glob only as last resort for one uid

# Requires: DIR

PM=/system/bin/pm
AM=/system/bin/am
TIMEOUT=/system/bin/timeout

_run() {
  # _run <secs> <bin> [args...]
  secs=$1
  shift
  if [ -x "$TIMEOUT" ]; then
    "$TIMEOUT" -k 1 "$secs" "$@"
  else
    "$@"
  fi
}

hail_is_critical_pkg() {
  case "$1" in
    android|com.android.systemui|com.android.phone|com.android.server.telecom|\
    com.android.settings|com.android.launcher*|com.android.permissioncontroller|\
    com.android.providers.settings|com.android.providers.media*|\
    com.android.nfc|com.android.keychain|com.android.keystore|\
    com.android.inputmethod*|com.google.android.inputmethod*|\
    com.android.shell|com.android.bluetooth|com.android.networkstack*|\
    com.oplus.*|net.oneplus.*|com.oneplus.*|com.coloros.*|\
    com.qti.*|com.qualcomm.*|com.android.vending|com.google.android.gms|\
    com.google.android.gsf|com.android.lmk*|me.weishu.kernelsu*|\
    com.rifsxd.ksunext*|com.topjohnwu.magisk*)
      return 0 ;;
  esac
  return 1
}

hail_user_id() {
  u=$(_run 2 "$AM" get-current-user 2>/dev/null | tr -d ' \t\r\n')
  case "$u" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$u" ;;
  esac
}

# One Binder call; reused by hail_is_pkg_disabled within this process.
hail_refresh_disabled_cache() {
  HAIL_DISABLED_CACHE=$(_run 3 "$PM" list packages -d 2>/dev/null | sed 's/^package://')
  HAIL_DISABLED_LOADED=1
}

hail_is_pkg_disabled() {
  pkg=$1
  [ -n "$pkg" ] || return 1
  [ "${HAIL_DISABLED_LOADED:-0}" = "1" ] || hail_refresh_disabled_cache
  printf '%s\n' "$HAIL_DISABLED_CACHE" | grep -qxF "$pkg"
}

hail_is_binder_fail() {
  case "$1" in
    *Failed\ transaction*|*DeadObject*|*NullPointerException*|*RemoteException*|*TimedOut*|*timeout*)
      return 0 ;;
  esac
  return 1
}

hail_trip_circuit() {
  reason=$1
  echo "$reason" > "$DIR/circuit.open"
  echo stop > "$DIR/mode"
  echo "CIRCUIT_OPEN $reason" >&2
}

hail_circuit_open() {
  [ -f "$DIR/circuit.open" ]
}

# Single-shot: force-stop once + pm disable once + verify once. Prints 1|0.
tombstone_apply() {
  pkg=$1
  if hail_is_critical_pkg "$pkg"; then
    echo "hail-refuse-critical $pkg" >&2
    echo 0
    return 1
  fi
  if hail_circuit_open; then
    echo "hail-circuit-open" >&2
    echo 0
    return 1
  fi

  uid=$(hail_user_id)
  rm -f "$DIR/comps-list.$pkg" "$DIR/comps-disabled.$pkg"

  hail_refresh_disabled_cache
  if hail_is_pkg_disabled "$pkg"; then
    echo 1 > "$DIR/tombstone.$pkg"
    echo 1 > "$DIR/frozen.$pkg"
    echo 1
    return 0
  fi

  out_fs=$(_run 3 "$AM" force-stop --user "$uid" "$pkg" 2>&1)
  if hail_is_binder_fail "$out_fs"; then
    hail_trip_circuit "force-stop:$pkg:$out_fs"
    echo 0
    return 1
  fi

  out=$(_run 3 "$PM" disable --user "$uid" "$pkg" 2>&1)
  rc=$?
  if hail_is_binder_fail "$out"; then
    hail_trip_circuit "pm-disable:$pkg:$out"
    echo 0
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "hail-apply-fail $pkg rc=$rc out=$out" >&2
    echo 0
    return 1
  fi

  HAIL_DISABLED_LOADED=0
  hail_refresh_disabled_cache
  if hail_is_pkg_disabled "$pkg"; then
    echo 1 > "$DIR/tombstone.$pkg"
    echo 1 > "$DIR/frozen.$pkg"
    echo 1
    return 0
  fi

  echo "hail-verify-fail $pkg out=$out" >&2
  rm -f "$DIR/tombstone.$pkg"
  echo 0
  return 1
}

tombstone_revive() {
  pkg=$1
  [ -n "$pkg" ] || return 1
  # Only touch PackageManager if we marked this pkg (or caller insists via file).
  uid=$(hail_user_id)
  _run 3 "$PM" enable --user "$uid" "$pkg" >/dev/null 2>&1 || true
  _run 3 "$PM" unsuspend --user "$uid" "$pkg" >/dev/null 2>&1 || true
  rm -f "$DIR/tombstone.$pkg" "$DIR/frozen.$pkg" "$DIR/bg.$pkg" "$DIR/watch.$pkg" \
    "$DIR/comps-disabled.$pkg" "$DIR/comps-list.$pkg" "$DIR/fail.$pkg"
  HAIL_DISABLED_LOADED=0
}

# Prefer one `ps` (no /proc glob). Fallback is last resort.
pids_for_uid() {
  uid=$1
  [ -n "$uid" ] || return 0
  [ "$uid" -ge 10000 ] 2>/dev/null || return 0
  out=$(ps -A -o UID,PID 2>/dev/null | awk -v u="$uid" '$1 == u { print $2 }')
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  # Last resort: only this uid's status files via find -maxdepth (still bounded intent)
  # Avoid shell glob /proc/[0-9]* which expands to thousands of args.
  if [ -x /system/bin/find ]; then
    /system/bin/find /proc -maxdepth 2 -name status 2>/dev/null \
      | while read -r st; do
          grep -q "^Uid:[[:space:]]*${uid}[[:space:]]" "$st" 2>/dev/null || continue
          p=${st#/proc/}; p=${p%/status}
          case "$p" in ''|*[!0-9]*) continue ;; esac
          echo "$p"
        done
  fi
}

snap_uid() {
  uid=$1
  total=0
  nt=0
  nr=0
  detail=
  for p in $(pids_for_uid "$uid"); do
    st=$(sed -n 's/^State:[[:space:]]*\([^[:space:]]*\).*/\1/p' /proc/"$p"/status 2>/dev/null | head -1)
    [ -n "$st" ] || continue
    name=$(sed -n 's/^Name:[[:space:]]*//p' /proc/"$p"/status 2>/dev/null | head -1)
    tag=main
    case "$name" in
      *:*) tag=":${name##*:}" ;;
      '') tag="pid$p" ;;
      *) tag=main ;;
    esac
    total=$((total + 1))
    if [ "$st" = "T" ]; then
      nt=$((nt + 1))
    else
      nr=$((nr + 1))
    fi
    detail="$detail $tag:$st"
  done
  echo "total=$total T=$nt run=$nr [${detail# }]"
}

# SIGSTOP only with O(1) uid re-check per pid (TOCTOU).
freeze_uid() {
  uid=$1
  n=0
  for p in $(pids_for_uid "$uid"); do
    [ -r "/proc/$p/status" ] || continue
    u=$(awk '/^Uid:/{print $2; exit}' /proc/"$p"/status 2>/dev/null)
    [ "$u" = "$uid" ] || continue
    st=$(awk '/^State:/{print $2; exit}' /proc/"$p"/status 2>/dev/null)
    [ "$st" = "T" ] && continue
    kill -STOP "$p" 2>/dev/null || continue
    n=$((n + 1))
  done
  echo "$n"
}

thaw_uid() {
  uid=$1
  for p in $(pids_for_uid "$uid"); do
    [ -r "/proc/$p/status" ] || continue
    u=$(awk '/^Uid:/{print $2; exit}' /proc/"$p"/status 2>/dev/null)
    [ "$u" = "$uid" ] || continue
    kill -CONT "$p" 2>/dev/null || true
  done
}

tombstone_uid_has_proc() {
  uid=$1
  [ -n "$uid" ] || return 1
  [ "$uid" -ge 10000 ] 2>/dev/null || return 1
  pids_for_uid "$uid" | grep -q .
}

tombstone_is_active() {
  pkg=$1
  [ -f "$DIR/tombstone.$pkg" ] || return 1
  hail_is_pkg_disabled "$pkg"
}

tombstone_launch() {
  pkg=$1
  uid=$(hail_user_id)
  tombstone_revive "$pkg"
  if _run 5 monkey --user "$uid" -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
    return 0
  fi
  cmp=$(_run 3 cmd package resolve-activity --brief "$pkg" 2>/dev/null | tail -n 1)
  case "$cmp" in
    */*) _run 3 "$AM" start --user "$uid" -n "$cmp" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
