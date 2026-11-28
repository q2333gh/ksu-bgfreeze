#!/usr/bin/env bash
# Bump module.prop version + versionCode and stub CHANGELOG.
# Usage: bash scripts/bump-version.sh 0.6.7 607
#        bash scripts/bump-version.sh --patch   # 0.6.6/606 → 0.6.7/607
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

prop_get() { grep -E "^$1=" module/module.prop | head -1 | cut -d= -f2- | tr -d '\r'; }
cur_ver=$(prop_get version)
cur_code=$(prop_get versionCode)
cur_plain=${cur_ver#v}

if [[ "${1:-}" == "--patch" ]]; then
  IFS=. read -r MA MI PA <<<"$cur_plain"
  PA=$((PA + 1))
  NEW_PLAIN="${MA}.${MI}.${PA}"
  NEW_CODE=$((cur_code + 1))
elif [[ $# -ge 2 ]]; then
  NEW_PLAIN="${1#v}"
  NEW_CODE="$2"
else
  echo "usage: bump-version.sh <x.y.z> <versionCode> | --patch" >&2
  exit 2
fi

NEW_TAG="v${NEW_PLAIN}"
if [[ "$NEW_CODE" -le "$cur_code" ]]; then
  echo "error: versionCode ${NEW_CODE} must be > ${cur_code}" >&2
  exit 1
fi

sed -i.bak -E "s/^version=.*/version=${NEW_TAG}/; s/^versionCode=.*/versionCode=${NEW_CODE}/" module/module.prop
rm -f module/module.prop.bak
sed -i.bak -E "s/^version = \"[^\"]+\"/version = \"${NEW_PLAIN}\"/" daemon/Cargo.toml
rm -f daemon/Cargo.toml.bak

if ! grep -qE "^## ${NEW_TAG}$" CHANGELOG.md; then
  {
    echo "# Changelog"
    echo
    echo "## ${NEW_TAG}"
    echo
    echo "- (describe changes)"
    echo
    tail -n +2 CHANGELOG.md | sed '1{/^$/d;}'
  } > CHANGELOG.md.new
  mv CHANGELOG.md.new CHANGELOG.md
fi

echo "bumped ${cur_ver}/${cur_code} → ${NEW_TAG}/${NEW_CODE}"
echo "next: edit CHANGELOG.md bullets, then bash scripts/ship.sh -m \"Release ${NEW_TAG}\""
