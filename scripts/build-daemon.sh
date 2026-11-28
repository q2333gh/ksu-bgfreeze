#!/usr/bin/env bash
# Cross-build static aarch64 musl binary into module/bin/bgfreeze
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

TARGET=aarch64-unknown-linux-musl
CROSS_ROOT="${CROSS_ROOT:-}"
if [[ -z "$CROSS_ROOT" ]]; then
  for cand in \
    "${HOME}/cross/aarch64-linux-musl-cross" \
    /tmp/aarch64-linux-musl-cross \
    /opt/aarch64-linux-musl-cross; do
    if [[ -x "${cand}/bin/aarch64-linux-musl-gcc" ]]; then
      CROSS_ROOT="$cand"
      break
    fi
  done
fi

if [[ -z "${CROSS_ROOT}" || ! -x "${CROSS_ROOT}/bin/aarch64-linux-musl-gcc" ]]; then
  echo "error: aarch64-linux-musl-gcc not found. Set CROSS_ROOT or install musl.cc toolchain." >&2
  exit 1
fi

export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="${CROSS_ROOT}/bin/aarch64-linux-musl-gcc"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_AR="${CROSS_ROOT}/bin/aarch64-linux-musl-ar"
export PATH="${CROSS_ROOT}/bin:${PATH}"

cd "$ROOT/daemon"
rustup target add "$TARGET" >/dev/null
cargo build --release --target "$TARGET"
OUT="$ROOT/daemon/target/${TARGET}/release/bgfreeze"
install -m 755 "$OUT" "$ROOT/module/bin/bgfreeze"
file "$ROOT/module/bin/bgfreeze"
ls -lh "$ROOT/module/bin/bgfreeze"
echo "installed: module/bin/bgfreeze"
