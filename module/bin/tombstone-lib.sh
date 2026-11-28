#!/system/bin/sh
# Hail-style helpers + safe process helpers.
# Rules: ONE attempt, verify once, fail-fast. No binder retry storms.
# Process scans: at most ONE awk over /proc/*/status (never per-pid fork).

# Requires: DIR

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
  u=$(am get-current-user 2>/dev/null | tr -d ' \t\r\n')
  case "$u" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$u" ;;
  esac
}

# Light check: pm list only (no dumpsys). Exit 0 = disabled.
hail_is_pkg_disabled() {
  pkg=$1
  pm list packages -d 2>/dev/null | grep -q "^package:${pkg}$"
}

# True if last binder-facing command looked like a hard failure.
hail_is_binder_fail() {
  case "$1" in
    *Failed\ transaction*|*DeadObject*|*NullPointerException*|*RemoteException*)
      return 0 ;;
  esac
  return 1
}

# Open global circuit: stop further disable/pm storms until manual clear.
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

  # Already disabled → success without more binder traffic
  if hail_is_pkg_disabled "$pkg"; then
    echo 1 > "$DIR/tombstone.$pkg"
    echo 1 > "$DIR/frozen.$pkg"
    echo 1
    return 0
  fi

  # ONE force-stop
  out_fs=$(am force-stop --user "$uid" "$pkg" 2>&1)
  if hail_is_binder_fail "$out_fs"; then
    hail_trip_circuit "force-stop:$pkg:$out_fs"
    echo 0
    return 1
  fi

  # ONE disable (no disable-user / bare fallback chain)
  out=$(pm disable --user "$uid" "$pkg" 2>&1)
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

  # ONE verify
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
  uid=$(hail_user_id)
  # ONE enable + ONE unsuspend — no loops
  pm enable --user "$uid" "$pkg" >/dev/null 2>&1 || true
  pm unsuspend --user "$uid" "$pkg" >/dev/null 2>&1 || true
  rm -f "$DIR/tombstone.$pkg" "$DIR/frozen.$pkg" "$DIR/bg.$pkg" "$DIR/watch.$pkg" \
    "$DIR/comps-disabled.$pkg" "$DIR/comps-list.$pkg" "$DIR/fail.$pkg"
}

# List pids for app uid — prefer ONE `ps`+|awk` (no per-pid forks).
pids_for_uid() {
  uid=$1
  [ -n "$uid" ] || return 0
  [ "$uid" -ge 10000 ] 2>/dev/null || return 0
  out=$(ps -A -o UID,PID 2>/dev/null | awk -v u="$uid" '$1 == u { print $2 }')
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  # Fallback if ps columns unsupported
  grep -l "^Uid:[[:space:]]*${uid}[[:space:]]" /proc/[0-9]*/status 2>/dev/null \
    | sed -n 's|^/proc/\([0-9][0-9]*\)/status$|\1|p'
}

# Snap only matching pids (usually few) — sed State, no global awk storm.
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

freeze_uid() {
  uid=$1
  n=0
  for p in $(pids_for_uid "$uid"); do
    st=$(sed -n 's/^State:[[:space:]]*\([^[:space:]]*\).*/\1/p' /proc/"$p"/status 2>/dev/null | head -1)
    [ "$st" = "T" ] && continue
    kill -STOP "$p" 2>/dev/null || continue
    n=$((n + 1))
  done
  echo "$n"
}

thaw_uid() {
  for p in $(pids_for_uid "$1"); do
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
  if monkey --user "$uid" -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
    return 0
  fi
  cmp=$(cmd package resolve-activity --brief "$pkg" 2>/dev/null | tail -n 1)
  case "$cmp" in
    */*) am start --user "$uid" -n "$cmp" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
