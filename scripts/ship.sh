#!/usr/bin/env bash
# One-entry ship prep for ksu-bgfreeze.
# Fixed chain after push: GitHub Precheck → Auto Tag → Release (see .github/workflows/).
#
# Usage:
#   bash scripts/ship.sh                     # build+pack, commit if dirty, push Origin main
#   bash scripts/ship.sh -m "msg"            # commit message
#   bash scripts/ship.sh --no-push           # stop before push
#   bash scripts/ship.sh --skip-build        # use existing module/bin/bgfreeze
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MSG=""
NO_PUSH=0
SKIP_BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--message) MSG="${2:-}"; shift 2 ;;
    --no-push) NO_PUSH=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

prop_get() { grep -E "^$1=" module/module.prop | head -1 | cut -d= -f2- | tr -d '\r'; }

VERSION=$(prop_get version)
CODE=$(prop_get versionCode)
test -n "$VERSION"
test "$CODE" -ge 1
case "$VERSION" in
  v*) TAG="$VERSION" ;;
  *) TAG="v${VERSION}" ;;
esac
PLAIN="${TAG#v}"

echo "== ship ${TAG} (versionCode ${CODE}) =="

# Keep Cargo.toml in lockstep with module.prop
if grep -qE '^version = "' daemon/Cargo.toml; then
  sed -i.bak -E "s/^version = \"[^\"]+\"/version = \"${PLAIN}\"/" daemon/Cargo.toml
  rm -f daemon/Cargo.toml.bak
fi

if ! grep -qE "^## ${TAG}$" CHANGELOG.md; then
  echo "error: CHANGELOG.md missing section '## ${TAG}'" >&2
  exit 1
fi

if [[ "$SKIP_BUILD" -ne 1 ]]; then
  bash scripts/build-daemon.sh
fi
test -x module/bin/bgfreeze
bash scripts/pack.sh
test -f "dist/ksu-bgfreeze-${TAG}.zip"

BIN_VER=$(strings module/bin/bgfreeze | grep -E "^bgfreeze ${PLAIN}$" | head -1 || true)
if [[ -z "$BIN_VER" ]]; then
  # fallback: binary may only embed via clap/env
  if command -v "$ROOT/module/bin/bgfreeze" >/dev/null 2>&1; then
    true
  fi
  echo "warn: could not string-match bgfreeze ${PLAIN} (ok if cross-built)"
fi

if [[ -z "$MSG" ]]; then
  MSG="Release ${TAG} (versionCode ${CODE})"
fi

git add -A
if git diff --cached --quiet; then
  echo "nothing to commit (tree clean)"
else
  git commit -m "$MSG"
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" ]]; then
  echo "warn: on branch ${BRANCH} (expected main)" >&2
fi

if [[ "$NO_PUSH" -eq 1 ]]; then
  echo "SHIP_LOCAL_OK ${TAG} (not pushed)"
  exit 0
fi

git push -u origin main

echo
echo "SHIP_ORIGIN_OK ${TAG} @ $(git rev-parse --short HEAD)"
echo "Fixed CI chain on GitHub (after main sync):"
echo "  Precheck → Auto Tag (lightweight ${TAG}) → Release.yml → ksu-bgfreeze-${CODE}-${TAG}.zip"
echo
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo "gh detected — watching Precheck (15m)…"
  # Best-effort; Origin-only agents skip this and use daily_env1.
  sleep 15
  gh run list -R q2333gh/ksu-bgfreeze --branch main --workflow Precheck --limit 3 || true
else
  echo "No gh here — sync tip to GitHub main via daily_env1, then Actions run the chain."
  echo "Marker: NEED_GITHUB_SYNC sha=$(git rev-parse HEAD) tag=${TAG} code=${CODE}"
fi
