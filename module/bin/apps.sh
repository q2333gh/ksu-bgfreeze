#!/system/bin/sh
# WebUI helpers: list | get-blacklist | set-blacklist | icon <pkg> | restart
DIR=/data/adb/ksu-bgfreeze
MODDIR="${MODDIR:-/data/adb/modules/ksu-bgfreeze}"
LIST=$DIR/blacklist.txt
ICONDIR=$DIR/icons
LABELCACHE=$DIR/labels.cache
mkdir -p "$DIR" "$ICONDIR"

cmd=${1:-list}

kill_daemon() {
  pidf=$DIR/daemon.pid
  [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null
  # stray instances (old double-start)
  for st in /proc/[0-9]*/cmdline; do
    [ -f "$st" ] || continue
    if tr '\0' ' ' < "$st" 2>/dev/null | grep -q 'bgfreeze-daemon\.sh'; then
      pid=${st#/proc/}; pid=${pid%/cmdline}
      kill "$pid" 2>/dev/null
    fi
  done
  rm -f "$pidf"
}

start_daemon() {
  if [ -x "$MODDIR/bin/bgfreeze-daemon.sh" ]; then
    "$MODDIR/bin/bgfreeze-daemon.sh" &
  fi
}

# One dumpsys package → labels.cache (pkg<TAB>label). Prefer zh labels.
refresh_label_cache() {
  dump=$DIR/packages.dump
  # Full dumpsys once (~1–3s) beats per-app dumpsys (~20s+).
  dumpsys package > "$dump" 2>/dev/null || { rm -f "$dump"; return 1; }
  awk '
    function take_label(line) {
      sub(/^[^:]*:/, "", line)
      gsub(/\r/, "", line)
      gsub(/^\047+/, "", line)
      gsub(/\047+$/, "", line)
      gsub(/^[ \t]+/, "", line)
      gsub(/[ \t]+$/, "", line)
      return line
    }
    /Package \[/ {
      if (pkg != "" && label != "") print pkg "\t" label
      pkg = ""; label = ""
      s = index($0, "[")
      e = index($0, "]")
      if (s > 0 && e > s) pkg = substr($0, s + 1, e - s - 1)
      next
    }
    pkg == "" { next }
    /application-label-zh-CN:/ {
      t = take_label($0)
      if (t != "") label = t
      next
    }
    /application-label-zh:/ {
      if (label == "") {
        t = take_label($0)
        if (t != "") label = t
      }
      next
    }
    /application-label:/ {
      if (label == "") {
        t = take_label($0)
        if (t != "") label = t
      }
      next
    }
    END {
      if (pkg != "" && label != "") print pkg "\t" label
    }
  ' "$dump" > "$LABELCACHE.tmp" && mv "$LABELCACHE.tmp" "$LABELCACHE"
  rm -f "$dump"
}

list_apps() {
  # Refresh cache if missing or older than 24h (or FORCE_LABEL_REFRESH=1).
  need=1
  if [ -f "$LABELCACHE" ] && [ "${FORCE_LABEL_REFRESH:-0}" != "1" ]; then
    # toybox/busybox stat -c %Y; fall back to always refresh if unknown
    now=$(date +%s)
    mtime=$(stat -c %Y "$LABELCACHE" 2>/dev/null || echo 0)
    age=$((now - mtime))
    [ "$mtime" -gt 0 ] && [ "$age" -lt 86400 ] && need=0
  fi
  if [ "$need" = 1 ]; then
    refresh_label_cache || true
  fi

  pm list packages -3 2>/dev/null | sed 's/^package://' | while read -r pkg; do
    [ -n "$pkg" ] || continue
    label=
    if [ -f "$LABELCACHE" ]; then
      label=$(awk -F '\t' -v p="$pkg" '$1==p{print $2;exit}' "$LABELCACHE")
    fi
    [ -n "$label" ] || label=$pkg
    label=$(printf '%s' "$label" | tr '\t\n|' '   ')
    printf '%s\t%s\n' "$pkg" "$label"
  done
}

get_blacklist() {
  [ -f "$LIST" ] || touch "$LIST"
  grep -v '^#' "$LIST" 2>/dev/null | grep -v '^$' || true
}

set_blacklist() {
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
  mv "$tmp" "$LIST"
  kill_daemon
  sleep 1
  start_daemon
  echo OK
}

extract_icon() {
  pkg=$1
  [ -n "$pkg" ] || exit 1
  out=$ICONDIR/$pkg.png
  if [ -f "$out" ] && [ -s "$out" ]; then
    base64 "$out" 2>/dev/null | tr -d '\n'
    return 0
  fi
  apk=$(pm path "$pkg" 2>/dev/null | head -1 | cut -d: -f2)
  [ -n "$apk" ] && [ -f "$apk" ] || exit 1
  cand=$(unzip -l "$apk" 2>/dev/null | awk '/ic_launcher.*\.png$/ {print $NF}')
  [ -n "$cand" ] || cand=$(unzip -l "$apk" 2>/dev/null | awk '/mipmap.*\.png$/ {print $NF}' | head -15)
  ok=
  for f in $cand; do
    case "$f" in *webp*|*.xml) continue ;; esac
    unzip -p "$apk" "$f" > "$out" 2>/dev/null || continue
    [ -s "$out" ] || { rm -f "$out"; continue; }
    # PNG magic bytes
    h=$(od -An -N8 -tx1 "$out" 2>/dev/null | tr -d ' \n')
    case "$h" in
      89504e470d0a1a0a*) ok=1; break ;;
    esac
    rm -f "$out"
  done
  [ -n "$ok" ] || exit 1
  base64 "$out" 2>/dev/null | tr -d '\n'
}

case "$cmd" in
  list) list_apps ;;
  refresh-labels)
    FORCE_LABEL_REFRESH=1
    refresh_label_cache && echo OK || echo FAIL
    ;;
  get-blacklist) get_blacklist ;;
  set-blacklist) set_blacklist "$@" ;;
  icon) extract_icon "$2" ;;
  restart)
    kill_daemon
    sleep 1
    start_daemon
    echo OK
    ;;
  *) echo "usage: apps.sh list|refresh-labels|get-blacklist|set-blacklist|icon <pkg>|restart" >&2; exit 1 ;;
esac
