#!/system/bin/sh
# WebUI helpers — systems-safe for KernelSU WebView.
# Rules: O(1) daemon stop; no /proc glob; Binder via timeout + cache; blacklist-only.
# snapshot | list | get-blacklist | set-blacklist | get-mode | set-mode | thaw-pkg
# | icon <pkg> | cache-icons | refresh-labels | restart | log | emergency
DIR=/data/adb/ksu-bgfreeze
MODDIR="${MODDIR:-/data/adb/modules/ksu-bgfreeze}"
LIST=$DIR/blacklist.txt
MODEFILE=$DIR/mode
ICONDIR=$DIR/icons
WEBICON="$MODDIR/webroot/icons"
LABELCACHE=$DIR/labels.cache
PKGFILE=$DIR/pkgs.tmp
SNAPFILE=$DIR/snapshot.tsv
PM=/system/bin/pm
TIMEOUT=/system/bin/timeout
mkdir -p "$DIR" "$ICONDIR" "$WEBICON"
[ -f "$MODEFILE" ] || echo stop > "$MODEFILE"

# shellcheck source=/dev/null
. "$MODDIR/bin/tombstone-lib.sh"

cmd=${1:-snapshot}

_run() {
  secs=$1
  shift
  if [ -x "$TIMEOUT" ]; then
    "$TIMEOUT" -k 1 "$secs" "$@"
  else
    "$@"
  fi
}

get_mode() {
  m=$(tr -d ' \t\r\n' < "$MODEFILE" 2>/dev/null)
  case "$m" in
    disable|tombstone) echo disable ;;
    *) echo stop ;;
  esac
}

revive_pkg() {
  pkg=$1
  [ -n "$pkg" ] || return 1
  # Only revive packages we marked — never spray pm enable.
  [ -f "$DIR/tombstone.$pkg" ] || [ -f "$DIR/comps-disabled.$pkg" ] || return 0
  tombstone_revive "$pkg"
}

# Only marker files — no per-blacklist pm list -d loop.
revive_all_tombstones() {
  for f in "$DIR"/tombstone.* "$DIR"/comps-disabled.*; do
    [ -f "$f" ] || continue
    base=${f##*/}
    case "$base" in
      tombstone.*) pkg=${base#tombstone.} ;;
      comps-disabled.*) pkg=${base#comps-disabled.} ;;
      *) continue ;;
    esac
    [ -n "$pkg" ] && tombstone_revive "$pkg"
  done
}

set_mode() {
  want=$1
  case "$want" in
    disable|tombstone)
      if [ ! -f "$DIR/allow-disable" ]; then
        echo "REFUSE disable: touch $DIR/allow-disable first (dangerous)" >&2
        return 1
      fi
      rm -f "$DIR/circuit.open" "$DIR"/fail.*
      echo disable > "$MODEFILE"
      ;;
    stop|sigstop|"")
      echo stop > "$MODEFILE"
      ;;
    *) echo "usage: set-mode stop|disable" >&2; return 1 ;;
  esac
  if [ "$(get_mode)" = "stop" ]; then
    revive_all_tombstones
  fi
  kill_daemon
  start_daemon
  echo "OK mode=$(get_mode)"
  [ -f "$DIR/circuit.open" ] && echo "circuit=$(cat "$DIR/circuit.open")"
}

thaw_pkg() {
  pkg=$2
  [ -n "$pkg" ] || { echo "usage: thaw-pkg <pkg>" >&2; return 1; }
  revive_pkg "$pkg"
  echo OK
}

launch_pkg() {
  pkg=$2
  [ -n "$pkg" ] || { echo "usage: launch-pkg <pkg>" >&2; return 1; }
  if tombstone_launch "$pkg"; then
    echo OK
  else
    echo "FAIL launch $pkg" >&2
    return 1
  fi
}

# O(1): pidfile identity check + flock holder. Never glob /proc.
kill_daemon() {
  pidf=$DIR/daemon.pid
  if [ -f "$pidf" ]; then
    pid=$(tr -d ' \t\r\n' < "$pidf" 2>/dev/null)
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        if [ -r "/proc/$pid/cmdline" ]; then
          case "$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)" in
            *bgfreeze*)
              kill "$pid" 2>/dev/null || true
              kill -9 "$pid" 2>/dev/null || true
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
}

start_daemon() {
  if [ -f "$MODDIR/disable" ]; then
    echo "start_daemon: skip (module disable present)" >&2
    return 0
  fi
  if [ -f "$DIR/panic" ]; then
    echo "start_daemon: skip (panic present)" >&2
    return 0
  fi
  if [ -x "$MODDIR/bin/bgfreeze" ]; then
    "$MODDIR/bin/bgfreeze" daemon >/dev/null 2>&1 &
  elif [ -x "$MODDIR/bin/bgfreeze-daemon.sh" ]; then
    "$MODDIR/bin/bgfreeze-daemon.sh" >/dev/null 2>&1 &
  fi
}

# Atomic replace: write .new then rename (same FS).
install_file() {
  src=$1
  dest=$2
  [ -f "$src" ] || return 1
  mkdir -p "$(dirname "$dest")"
  cp -f "$src" "$dest.new" || return 1
  mv -f "$dest.new" "$dest" || return 1
}

prop_version() {
  grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2 | tr -d ' \t\r\n'
}

prop_version_code() {
  grep '^versionCode=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2 | tr -d ' \t\r\n'
}

binary_version() {
  if [ -x "$MODDIR/bin/bgfreeze" ]; then
    "$MODDIR/bin/bgfreeze" version 2>/dev/null | awk '{print $NF}' | tr -d 'v \t\r\n'
  else
    echo missing
  fi
}

ui_version() {
  sed -n 's/.*data-ui="\([0-9]*\)".*/\1/p' "$MODDIR/webroot/index.html" 2>/dev/null | head -1
}

norm_ver() {
  echo "$1" | sed 's/^v//' | tr -d ' \t\r\n'
}

# Machine-readable health for WebUI / agents.
print_status() {
  pv=$(norm_ver "$(prop_version)")
  bv=$(binary_version)
  ui=$(ui_version)
  vc=$(prop_version_code)
  aligned=0
  [ -n "$pv" ] && [ "$pv" = "$bv" ] && aligned=1
  pid=
  [ -f "$DIR/daemon.pid" ] && pid=$(tr -d ' \t\r\n' < "$DIR/daemon.pid")
  disabled=0
  [ -f "$MODDIR/disable" ] && disabled=1
  panic=0
  [ -f "$DIR/panic" ] && panic=1
  echo "prop=v${pv}"
  echo "versionCode=${vc:-0}"
  echo "binary=${bv}"
  echo "ui=${ui:-0}"
  echo "aligned=${aligned}"
  echo "daemon_pid=${pid:-0}"
  echo "disabled=${disabled}"
  echo "panic=${panic}"
  echo "mode=$(get_mode)"
  if [ "$aligned" != "1" ]; then
    echo "WARN prop/binary mismatch — run hot-update with full zip" >&2
  fi
  if [ "$disabled" = "1" ] || [ "$panic" = "1" ]; then
    echo "WARN daemon will not start until enable (disable/panic set)" >&2
  fi
}

enable_module() {
  rm -f "$MODDIR/disable" "$DIR/panic"
  kill_daemon
  start_daemon
  print_status
  echo ENABLE_OK
}

# Full hot update from zip or extracted dir. Refuses partial packages.
hot_update() {
  src=$1
  [ -n "$src" ] || {
    echo "usage: hot-update <module.zip|/path/to/extracted>" >&2
    return 1
  }
  [ -e "$src" ] || {
    echo "hot-update: missing $src" >&2
    return 1
  }

  stage=$DIR/hot-stage.$$
  rm -rf "$stage"
  mkdir -p "$stage" || return 1

  if [ -f "$src" ]; then
    case "$src" in
      *.zip)
        unzip -o "$src" -d "$stage" >/dev/null 2>&1 || {
          echo "hot-update: unzip failed" >&2
          rm -rf "$stage"
          return 1
        }
        ;;
      *)
        echo "hot-update: file must be .zip or a directory" >&2
        rm -rf "$stage"
        return 1
        ;;
    esac
  else
    # Directory: accept either module root or nested module/
    if [ -f "$src/module.prop" ]; then
      cp -a "$src/." "$stage/" || {
        rm -rf "$stage"
        return 1
      }
    elif [ -f "$src/module/module.prop" ]; then
      cp -a "$src/module/." "$stage/" || {
        rm -rf "$stage"
        return 1
      }
    else
      echo "hot-update: no module.prop in $src" >&2
      rm -rf "$stage"
      return 1
    fi
  fi

  # Required payload — refuse silent partial updates (was the 0.6.5 footgun).
  for req in module.prop bin/bgfreeze bin/apps.sh bin/tombstone-lib.sh \
    webroot/app.js webroot/index.html webroot/style.css action.sh; do
    if [ ! -f "$stage/$req" ]; then
      echo "hot-update: REFUSE incomplete package (missing $req)" >&2
      rm -rf "$stage"
      return 1
    fi
  done
  if [ ! -x "$stage/bin/bgfreeze" ]; then
    chmod 755 "$stage/bin/bgfreeze" 2>/dev/null || true
  fi
  if [ ! -x "$stage/bin/bgfreeze" ]; then
    echo "hot-update: REFUSE bgfreeze not executable" >&2
    rm -rf "$stage"
    return 1
  fi

  new_ver=$(grep '^version=' "$stage/module.prop" | cut -d= -f2 | tr -d ' \t\r\n')
  new_vc=$(grep '^versionCode=' "$stage/module.prop" | cut -d= -f2 | tr -d ' \t\r\n')
  echo "hot-update: installing $new_ver ($new_vc)"

  kill_daemon

  # Clear sticky stop flags so new binary can run (hot-update = re-enable).
  rm -f "$MODDIR/disable" "$DIR/panic"

  install_file "$stage/module.prop" "$MODDIR/module.prop" || {
    echo "hot-update: fail module.prop" >&2
    rm -rf "$stage"
    return 1
  }
  install_file "$stage/bin/bgfreeze" "$MODDIR/bin/bgfreeze" || {
    echo "hot-update: fail bgfreeze" >&2
    rm -rf "$stage"
    return 1
  }
  chmod 755 "$MODDIR/bin/bgfreeze"
  install_file "$stage/bin/apps.sh" "$MODDIR/bin/apps.sh" || return 1
  chmod 755 "$MODDIR/bin/apps.sh"
  install_file "$stage/bin/tombstone-lib.sh" "$MODDIR/bin/tombstone-lib.sh" || return 1
  chmod 755 "$MODDIR/bin/tombstone-lib.sh"
  [ -f "$stage/bin/bgfreeze-daemon.sh" ] && install_file "$stage/bin/bgfreeze-daemon.sh" "$MODDIR/bin/bgfreeze-daemon.sh"
  install_file "$stage/action.sh" "$MODDIR/action.sh" || return 1
  chmod 755 "$MODDIR/action.sh"
  for w in app.js index.html style.css; do
    install_file "$stage/webroot/$w" "$MODDIR/webroot/$w" || return 1
  done
  for opt in service.sh boot-completed.sh uninstall.sh AGENTS.md; do
    [ -f "$stage/$opt" ] && install_file "$stage/$opt" "$MODDIR/$opt"
  done
  # Keep boot scripts executable
  chmod 755 "$MODDIR/service.sh" "$MODDIR/boot-completed.sh" 2>/dev/null || true

  sync

  start_daemon
  sleep 1

  bv=$(binary_version)
  pv=$(norm_ver "$(prop_version)")
  if [ "$bv" != "$pv" ]; then
    echo "hot-update: VERIFY FAIL binary=$bv prop=$pv" >&2
    rm -rf "$stage"
    return 1
  fi
  if [ -f "$MODDIR/disable" ] || [ -f "$DIR/panic" ]; then
    echo "hot-update: VERIFY FAIL disable/panic still set" >&2
    rm -rf "$stage"
    return 1
  fi

  rm -rf "$stage"
  print_status
  echo "HOT_OK version=v${pv} versionCode=$(prop_version_code)"
}

circuit_status() {
  if [ -f "$DIR/circuit.open" ]; then
    echo "OPEN $(cat "$DIR/circuit.open")"
  else
    echo CLOSED
  fi
}

circuit_clear() {
  rm -f "$DIR/circuit.open" "$DIR"/fail.*
  echo OK
}

find_aapt() {
  for c in "$MODDIR/bin/aapt" /data/data/com.termux/files/usr/bin/aapt "$(command -v aapt 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

refresh_label_cache() {
  aapt=$(find_aapt) || aapt=
  : > "$LABELCACHE.tmp"
  _run 5 "$PM" list packages -3 2>/dev/null | sed 's/^package://' | while read -r pkg; do
    [ -n "$pkg" ] || continue
    label=
    if [ -n "$aapt" ]; then
      apk=$(_run 2 "$PM" path "$pkg" 2>/dev/null | head -1 | cut -d: -f2)
      if [ -n "$apk" ] && [ -f "$apk" ]; then
        bad=$("$aapt" dump badging "$apk" 2>/dev/null) || bad=
        label=$(printf '%s\n' "$bad" | grep "application-label-zh-CN:" | head -1 \
          | sed "s/.*application-label-zh-CN:'//;s/'.*//")
        [ -n "$label" ] || label=$(printf '%s\n' "$bad" | grep "application-label-zh:" | head -1 \
          | sed "s/.*application-label-zh:'//;s/'.*//")
        [ -n "$label" ] || label=$(printf '%s\n' "$bad" | grep "^application-label:" | head -1 \
          | sed "s/.*application-label:'//;s/'.*//")
      fi
    fi
    [ -n "$label" ] || continue
    label=$(printf '%s' "$label" | tr '\t\n|' '   ')
    printf '%s\t%s\n' "$pkg" "$label" >> "$LABELCACHE.tmp"
  done

  if [ -s "$LABELCACHE.tmp" ]; then
    mv "$LABELCACHE.tmp" "$LABELCACHE"
  else
    rm -f "$LABELCACHE.tmp" "$LABELCACHE"
    return 1
  fi
}

# pkg \t label \t 0|1(checked) \t 0|1(has_web_icon)
snapshot_apps() {
  [ -f "$LIST" ] || touch "$LIST"
  _run 5 "$PM" list packages -3 2>/dev/null | sed 's/^package://' | sort -u > "$PKGFILE"

  if [ -s "$LABELCACHE" ]; then
    awk -F '\t' -v listdir="$LIST" -v icondir="$WEBICON" '
      BEGIN {
        while ((getline line < listdir) > 0) {
          if (line ~ /^#/ || line == "") continue
          bl[line] = 1
        }
        close(listdir)
      }
      FNR==NR {
        if (NF >= 2 && $1 != "") {
          lab = $2
          for (i = 3; i <= NF; i++) lab = lab "\t" $i
          gsub(/[\t\n|]/, " ", lab)
          l[$1] = lab
        }
        next
      }
      {
        p = $1
        lab = l[p]
        if (lab == "") lab = p
        ck = (p in bl) ? 1 : 0
        f = icondir "/" p ".png"
        icon = 0
        if ((getline _ < f) >= 0) { icon = 1; close(f) } else { close(f) }
        print p "\t" lab "\t" ck "\t" icon
      }
    ' "$LABELCACHE" "$PKGFILE" > "$SNAPFILE.tmp"
  else
    awk -F '\t' -v listdir="$LIST" -v icondir="$WEBICON" '
      BEGIN {
        while ((getline line < listdir) > 0) {
          if (line ~ /^#/ || line == "") continue
          bl[line] = 1
        }
        close(listdir)
      }
      {
        p = $1
        lab = p
        ck = (p in bl) ? 1 : 0
        f = icondir "/" p ".png"
        icon = 0
        if ((getline _ < f) >= 0) { icon = 1; close(f) } else { close(f) }
        print p "\t" lab "\t" ck "\t" icon
      }
    ' "$PKGFILE" > "$SNAPFILE.tmp"
  fi

  mv "$SNAPFILE.tmp" "$SNAPFILE"
  cat "$SNAPFILE"
}

list_apps() {
  snapshot_apps | awk -F '\t' '{ print $1 "\t" $2 }'
}

get_blacklist() {
  [ -f "$LIST" ] || touch "$LIST"
  grep -v '^#' "$LIST" 2>/dev/null | grep -v '^$' || true
}

set_blacklist() {
  old=$DIR/blacklist.txt.old
  [ -f "$LIST" ] && cp -f "$LIST" "$old" || : > "$old"
  tmp=$DIR/blacklist.txt.new
  : > "$tmp"
  if [ "$#" -gt 1 ]; then
    shift
    for p in "$@"; do
      [ -n "$p" ] && printf '%s\n' "$p" >> "$tmp"
    done
  else
    while IFS= read -r p || [ -n "$p" ]; do
      case "$p" in ''|\#*) continue ;; esac
      printf '%s\n' "$p" >> "$tmp"
    done
  fi
  # Removed from list → revive only if we had tombstoned them
  while IFS= read -r p || [ -n "$p" ]; do
    case "$p" in ''|\#*) continue ;; esac
    grep -qxF "$p" "$tmp" 2>/dev/null && continue
    revive_pkg "$p"
  done < "$old"
  mv "$tmp" "$LIST"
  rm -f "$old"
  kill_daemon
  start_daemon
  echo OK
}

extract_icon_file() {
  pkg=$1
  [ -n "$pkg" ] || return 1
  case "$pkg" in *[!a-zA-Z0-9._]*) return 1 ;; esac
  mkdir -p "$WEBICON" "$ICONDIR"
  out=$WEBICON/$pkg.png
  if [ -f "$out" ] && [ -s "$out" ]; then
    [ -f "$ICONDIR/$pkg.png" ] || cp -f "$out" "$ICONDIR/$pkg.png" 2>/dev/null || true
    return 0
  fi
  apk=$(_run 2 "$PM" path "$pkg" 2>/dev/null | head -1 | cut -d: -f2)
  [ -n "$apk" ] && [ -f "$apk" ] || return 1
  cand=$(unzip -l "$apk" 2>/dev/null | awk '/ic_launcher.*\.png$/ {print $NF}')
  [ -n "$cand" ] || cand=$(unzip -l "$apk" 2>/dev/null | awk '/mipmap.*\.png$/ {print $NF}' | head -15)
  ok=
  tmp=$ICONDIR/$pkg.png.part
  for f in $cand; do
    case "$f" in *webp*|*.xml) continue ;; esac
    unzip -p "$apk" "$f" > "$tmp" 2>/dev/null || continue
    [ -s "$tmp" ] || { rm -f "$tmp"; continue; }
    h=$(od -An -N8 -tx1 "$tmp" 2>/dev/null | tr -d ' \n')
    case "$h" in
      89504e470d0a1a0a*) ok=1; break ;;
    esac
    rm -f "$tmp"
  done
  [ -n "$ok" ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$out"
  cp -f "$out" "$ICONDIR/$pkg.png" 2>/dev/null || true
  return 0
}

extract_icon() {
  pkg=$1
  extract_icon_file "$pkg" || exit 1
  base64 "$WEBICON/$pkg.png" 2>/dev/null | tr -d '\n'
}

cache_icons() {
  mkdir -p "$WEBICON"
  limit=${1:-40}
  n=0
  _run 5 "$PM" list packages -3 2>/dev/null | sed 's/^package://' | sort -u > "$PKGFILE"
  while IFS= read -r pkg || [ -n "$pkg" ]; do
    [ -n "$pkg" ] || continue
    [ -f "$WEBICON/$pkg.png" ] && [ -s "$WEBICON/$pkg.png" ] && continue
    extract_icon_file "$pkg" || true
    n=$((n + 1))
    [ "$n" -ge "$limit" ] && break
  done < "$PKGFILE"
  have=$(ls "$WEBICON"/*.png 2>/dev/null | wc -l | tr -d ' ')
  echo "OK icons=$have"
}

case "$cmd" in
  snapshot) snapshot_apps ;;
  list) list_apps ;;
  refresh-labels)
    refresh_label_cache && echo OK || echo FAIL
    ;;
  cache-icons) cache_icons "${2:-40}" ;;
  get-blacklist) get_blacklist ;;
  set-blacklist) set_blacklist "$@" ;;
  get-mode) get_mode ;;
  set-mode) set_mode "$2" ;;
  thaw-pkg) thaw_pkg "$@" ;;
  launch-pkg) launch_pkg "$@" ;;
  icon) extract_icon "$2" ;;
  log|logs)
    n=${2:-40}
    LOG=/data/local/tmp/ksu-bgfreeze.log
    if [ -f "$LOG" ]; then
      echo "=== $LOG (tail $n) ==="
      tail -n "$n" "$LOG"
    else
      echo "no log yet: $LOG"
    fi
    ;;
  restart)
    kill_daemon
    start_daemon
    echo OK
    ;;
  status|health) print_status ;;
  enable|unpanic) enable_module ;;
  hot-update|hotupdate)
    hot_update "$2"
    ;;
  emergency|recover)
    # Soft recover: stop freeze work + revive our marks. Does NOT leave module disable
    # (that footgun blocked later hot-updates). Use `panic` for hard stop.
    kill_daemon
    echo stop > "$MODEFILE"
    rm -f "$DIR/allow-disable-on-boot" "$DIR/circuit.open" "$DIR"/fail.*
    : > "$LIST"
    revive_all_tombstones
    rm -f "$DIR"/tombstone.* "$DIR"/frozen.* "$DIR"/bg.* "$DIR"/watch.* "$DIR"/comps-*
    echo RECOVER_OK
    ;;
  panic)
    # Hard stop: soft recover + sticky module disable until `enable` / `hot-update`.
    kill_daemon
    touch "$MODDIR/disable" 2>/dev/null || true
    touch "$DIR/panic" 2>/dev/null || true
    echo stop > "$MODEFILE"
    rm -f "$DIR/allow-disable-on-boot" "$DIR/circuit.open" "$DIR"/fail.*
    : > "$LIST"
    revive_all_tombstones
    rm -f "$DIR"/tombstone.* "$DIR"/frozen.* "$DIR"/bg.* "$DIR"/watch.* "$DIR"/comps-*
    echo PANIC_OK
    ;;
  circuit|circuit-status) circuit_status ;;
  circuit-clear) circuit_clear ;;
  *)
    echo "usage: apps.sh snapshot|status|hot-update <zip>|enable|panic|emergency|..." >&2
    exit 1
    ;;
esac
