#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist"
VER=$(grep '^version=' "$ROOT/module/module.prop" | cut -d= -f2)
NAME="ksu-bgfreeze-${VER}.zip"
mkdir -p "$OUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cp -a "$ROOT/module/." "$TMP/"
# ensure scripts executable in zip metadata
find "$TMP" -type f \( -name '*.sh' -o -name 'update-binary' \) -exec chmod 755 {} \;

(
  cd "$TMP"
  zip -r9 "$OUT/$NAME" . -x '*/.DS_Store' -x '*/__MACOSX/*'
)
echo "packed: $OUT/$NAME"
ls -lh "$OUT/$NAME"
