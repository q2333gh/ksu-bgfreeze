#!/system/bin/sh
# WebUI helpers: list | get-blacklist | set-blacklist | icon <pkg> | restart
DIR=/data/adb/ksu-bgfreeze
MODDIR="${MODDIR:-/data/adb/modules/ksu-bgfreeze}"
LIST=$DIR/blacklist.txt
ICONDIR=$DIR/icons
mkdir -p "$DIR" "$ICONDIR"

cmd=${1:-list}

label_of() {
  pkg=$1
  # prefer Chinese label when present
  dumpsys package "$pkg" 2>/dev/null | grep -E "application-label(-zh(-CN)?)?:" | head -1 \
    | sed "s/.*application-label[^:]*://;s/^['\"]//;s/['\"]$//;s/\r//g"
}

list_apps() {
  pm list packages -3 2>/dev/null | sed 's/^package://' | while read -r pkg; do
    [ -n "$pkg" ] || continue
    label=$(label_of "$pkg")
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
  pidf=$DIR/daemon.pid
  [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null
  sleep 1
  if [ -x "$MODDIR/bin/bgfreeze-daemon.sh" ]; then
    "$MODDIR/bin/bgfreeze-daemon.sh" &
  fi
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
  get-blacklist) get_blacklist ;;
  set-blacklist) set_blacklist "$@" ;;
  icon) extract_icon "$2" ;;
  restart)
    pidf=$DIR/daemon.pid
    [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null
    sleep 1
    "$MODDIR/bin/bgfreeze-daemon.sh" &
    echo OK
    ;;
  *) echo "usage: apps.sh list|get-blacklist|set-blacklist|icon <pkg>|restart" >&2; exit 1 ;;
esac
