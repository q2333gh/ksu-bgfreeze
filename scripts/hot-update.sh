#!/usr/bin/env bash
# Safe device hot-update helper (host side).
# Always ships the FULL module zip — never scripts-only.
# On device: sh /data/adb/modules/ksu-bgfreeze/bin/apps.sh hot-update <zip>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="${1:-}"

if [[ -z "$ZIP" ]]; then
  bash "$ROOT/scripts/pack.sh"
  VER=$(grep '^version=' "$ROOT/module/module.prop" | cut -d= -f2)
  ZIP="$ROOT/dist/ksu-bgfreeze-${VER}.zip"
fi

[[ -f "$ZIP" ]] || { echo "missing zip: $ZIP" >&2; exit 1; }

echo "Ready zip: $ZIP"
echo "sha256: $(sha256sum "$ZIP" | awk '{print $1}')"
echo
BN=$(basename "$ZIP")
echo "On device (root), prefer Release zip. Bootstrap if installed apps.sh is older:"
echo "  ZIP=/sdcard/Download/$BN"
echo "  W=/data/local/tmp/ksu-hot"
echo "  rm -rf \$W && mkdir -p \$W && unzip -o \$ZIP -d \$W"
echo "  # Run NEW apps.sh from extract (installs into /data/adb/modules/ksu-bgfreeze)"
echo "  sh \$W/bin/apps.sh hot-update \$ZIP"
echo "  sh /data/adb/modules/ksu-bgfreeze/bin/apps.sh status   # expect aligned=1"
echo
echo "Agent/phone MCP: curl GitHub Release zip → same steps. Never cp apps.sh alone."
