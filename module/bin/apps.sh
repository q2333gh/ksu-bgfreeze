#!/system/bin/sh
# WebUI helpers: list | get-blacklist | set-blacklist | icon <pkg> | restart | refresh-labels
DIR=/data/adb/ksu-bgfreeze
MODDIR="${MODDIR:-/data/adb/modules/ksu-bgfreeze}"
LIST=$DIR/blacklist.txt
ICONDIR=$DIR/icons
LABELCACHE=$DIR/labels.cache
PKGFILE=$DIR/pkgs.tmp
mkdir -p "$DIR" "$ICONDIR"

cmd=${1:-list}

kill_daemon() {
  pidf=$DIR/daemon.pid
  if [ -f "$pidf" ]; then
    kill "$(cat "$pidf")" 2>/dev/null
  fi
  # Prefer pkill when present (avoids scanning all /proc)
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
  rm -f "$pidf"
}

start_daemon() {
  if [ -x "$MODDIR/bin/bgfreeze-daemon.sh" ]; then
    "$MODDIR/bin/bgfreeze-daemon.sh" &
  fi
}

# Build labels.cache using aapt if available (Android 14+ dumpsys has no application-label).
# Falls back to empty cache (list will show package names).
refresh_label_cache() {
  aapt=
  for c in "$MODDIR/bin/aapt" /data/data/com.termux/files/usr/bin/aapt "$(command -v aapt 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { aapt=$c; break; }
  done

  : > "$LABELCACHE.tmp"
  pm list packages -3 2>/dev/null | sed 's/^package://' | while read -r pkg; do
    [ -n "$pkg" ] || continue
    label=
    if [ -n "$aapt" ]; then
      apk=$(pm path "$pkg" 2>/dev/null | head -1 | cut -d: -f2)
      if [ -n "$apk" ] && [ -f "$apk" ]; then
        # Prefer Chinese label lines from badging
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
    rm -f "$LABELCACHE.tmp"
    # Keep empty marker with size 0 invalid — list treats non-size cache as missing
    rm -f "$LABELCACHE"
    return 1
  fi
}

list_apps() {
  pm list packages -3 2>/dev/null | sed 's/^package://' | sort -u > "$PKGFILE"

  # One-shot join — never spawn awk/tr per package (that alone was ~4s).
  if [ -s "$LABELCACHE" ]; then
    awk -F '\t' '
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
        print p "\t" lab
      }
    ' "$LABELCACHE" "$PKGFILE"
  else
    awk '{ print $1 "\t" $1 }' "$PKGFILE"
  fi
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
    refresh_label_cache && echo OK || echo FAIL
    ;;
  get-blacklist) get_blacklist ;;
  set-blacklist) set_blacklist "$@" ;;
  icon) extract_icon "$2" ;;
  log|logs)
    # 简要日志：默认尾 40 行；可传行数 apps.sh log 80
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
  *) echo "usage: apps.sh list|refresh-labels|get-blacklist|set-blacklist|icon <pkg>|log [n]|restart" >&2; exit 1 ;;
esac
