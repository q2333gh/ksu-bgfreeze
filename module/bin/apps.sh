#!/system/bin/sh
# WebUI helpers — keep list path O(n log n), zero per-app forks on open.
# snapshot | list | get-blacklist | set-blacklist | get-mode | set-mode | thaw-pkg
# | icon <pkg> | cache-icons | refresh-labels | restart | log
DIR=/data/adb/ksu-bgfreeze
MODDIR="${MODDIR:-/data/adb/modules/ksu-bgfreeze}"
LIST=$DIR/blacklist.txt
MODEFILE=$DIR/mode
ICONDIR=$DIR/icons
# Served by KernelSU WebUI as relative URL icons/<pkg>.png — no ksu.exec per icon.
WEBICON="$MODDIR/webroot/icons"
LABELCACHE=$DIR/labels.cache
PKGFILE=$DIR/pkgs.tmp
SNAPFILE=$DIR/snapshot.tsv
mkdir -p "$DIR" "$ICONDIR" "$WEBICON"
[ -f "$MODEFILE" ] || echo stop > "$MODEFILE"

# shellcheck source=/dev/null
. "$MODDIR/bin/tombstone-lib.sh"

cmd=${1:-snapshot}

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
  tombstone_revive "$pkg"
}

# Revive packages we hail-disabled (leaving disable mode). Fast path if none.
revive_all_tombstones() {
  any=
  for f in "$DIR"/tombstone.* "$DIR"/comps-disabled.*; do
    [ -f "$f" ] || continue
    any=1
    base=${f##*/}
    case "$base" in
      tombstone.*) pkg=${base#tombstone.} ;;
      comps-disabled.*) pkg=${base#comps-disabled.} ;;
      *) continue ;;
    esac
    [ -n "$pkg" ] && revive_pkg "$pkg"
  done
  # Avoid pm list packages -d per blacklist row when nothing was tombstoned.
  [ -n "$any" ] || return 0
  [ -f "$LIST" ] || return 0
  while IFS= read -r pkg || [ -n "$pkg" ]; do
    case "$pkg" in ''|\#*) continue ;; esac
    hail_is_pkg_disabled "$pkg" || continue
    revive_pkg "$pkg"
  done < "$LIST"
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

# Hail LAUNCH: enable + start launcher activity
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

# Never walk all /proc (8000+ PIDs freezes KernelSU WebUI). pidfile + lock only.
kill_daemon() {
  pidf=$DIR/daemon.pid
  if [ -f "$pidf" ]; then
    pid=$(tr -d ' \t\r\n' < "$pidf" 2>/dev/null)
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        kill "$pid" 2>/dev/null || true
        kill -9 "$pid" 2>/dev/null || true
        ;;
    esac
  fi
  if [ -f "$DIR/daemon.lock" ] && command -v fuser >/dev/null 2>&1; then
    fuser -k "$DIR/daemon.lock" >/dev/null 2>&1 || true
  fi
  rm -f "$pidf"
}

start_daemon() {
  [ -f "$MODDIR/disable" ] && return 0
  [ -f "$DIR/panic" ] && return 0
  if [ -x "$MODDIR/bin/bgfreeze" ]; then
    "$MODDIR/bin/bgfreeze" daemon >/dev/null 2>&1 &
  elif [ -x "$MODDIR/bin/bgfreeze-daemon.sh" ]; then
    "$MODDIR/bin/bgfreeze-daemon.sh" >/dev/null 2>&1 &
  fi
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
  pm list packages -3 2>/dev/null | sed 's/^package://' | while read -r pkg; do
    [ -n "$pkg" ] || continue
    label=
    if [ -n "$aapt" ]; then
      apk=$(pm path "$pkg" 2>/dev/null | head -1 | cut -d: -f2)
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
  pm list packages -3 2>/dev/null | sed 's/^package://' | sort -u > "$PKGFILE"

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
  # Back-compat: pkg \t label only
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
  # Packages removed from blacklist → revive if we had disabled them
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

# Extract one PNG into webroot/icons (and private ICONDIR). Prints nothing; exit 0/1.
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
  apk=$(pm path "$pkg" 2>/dev/null | head -1 | cut -d: -f2)
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
  # Legacy: stdout base64 (slow path for old WebUI)
  pkg=$1
  extract_icon_file "$pkg" || exit 1
  base64 "$WEBICON/$pkg.png" 2>/dev/null | tr -d '\n'
}

# Warm webroot icons for packages missing PNG. Cap extractions so UI stays free.
cache_icons() {
  mkdir -p "$WEBICON"
  limit=${1:-60}
  n=0
  pm list packages -3 2>/dev/null | sed 's/^package://' | sort -u > "$PKGFILE"
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
  cache-icons) cache_icons "${2:-60}" ;;
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
    sleep 1
    start_daemon
    echo OK
    ;;
  emergency|recover)
    # Immediate safe restore — stop daemon, enable disabled pkgs, disable module
    kill_daemon
    touch "$MODDIR/disable" 2>/dev/null || true
    echo stop > "$MODEFILE"
    rm -f "$DIR/allow-disable-on-boot" "$DIR/circuit.open" "$DIR"/fail.*
    : > "$LIST"
    revive_all_tombstones
    pm list packages -d 2>/dev/null | sed 's/^package://' | while read -r p; do
      [ -n "$p" ] || continue
      pm enable --user 0 "$p" >/dev/null 2>&1 || pm enable "$p" >/dev/null 2>&1 || true
    done
    rm -f "$DIR"/tombstone.* "$DIR"/frozen.* "$DIR"/bg.* "$DIR"/watch.* "$DIR"/comps-*
    echo RECOVER_OK
    ;;
  circuit|circuit-status) circuit_status ;;
  circuit-clear) circuit_clear ;;
  *)
    echo "usage: apps.sh snapshot|list|cache-icons|refresh-labels|get-blacklist|set-blacklist|get-mode|set-mode|thaw-pkg|launch-pkg|icon <pkg>|log [n]|restart|emergency|circuit-status|circuit-clear" >&2
    exit 1
    ;;
esac
