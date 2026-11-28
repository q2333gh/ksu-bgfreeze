#!/usr/bin/env bash
# Cross-build aarch64 daemon into module/bin/bgfreeze.
# Prefer Android NDK (CI / ANDROID_NDK_HOME). Fallback: musl.cc toolchain via CROSS_ROOT.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

install_bin() {
  local out="$1"
  install -m 755 "$out" "$ROOT/module/bin/bgfreeze"
  file "$ROOT/module/bin/bgfreeze"
  ls -lh "$ROOT/module/bin/bgfreeze"
  echo "installed: module/bin/bgfreeze"
}

# ---- Android NDK path (GitHub Actions / local SDK) ----
if [[ -n "${ANDROID_NDK_HOME:-}" && -d "${ANDROID_NDK_HOME}" ]]; then
  TARGET=aarch64-linux-android
  API="${ANDROID_API:-24}"
  PREBUILT="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"
  if [[ ! -d "$PREBUILT" ]]; then
    # macOS host
    PREBUILT="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/darwin-x86_64"
  fi
  CC="${PREBUILT}/bin/aarch64-linux-android${API}-clang"
  AR="${PREBUILT}/bin/llvm-ar"
  if [[ ! -x "$CC" ]]; then
    echo "error: NDK clang missing: $CC" >&2
    exit 1
  fi
  export CC_aarch64_linux_android="$CC"
  export AR_aarch64_linux_android="$AR"
  export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CC"
  export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="$AR"
  cd "$ROOT/daemon"
  rustup target add "$TARGET" >/dev/null
  cargo build --release --target "$TARGET"
  install_bin "$ROOT/daemon/target/${TARGET}/release/bgfreeze"
  exit 0
fi

# ---- musl.cc fallback (local) ----
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
  echo "error: set ANDROID_NDK_HOME or CROSS_ROOT (aarch64-linux-musl-gcc)." >&2
  exit 1
fi

export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="${CROSS_ROOT}/bin/aarch64-linux-musl-gcc"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_AR="${CROSS_ROOT}/bin/aarch64-linux-musl-ar"
export PATH="${CROSS_ROOT}/bin:${PATH}"

cd "$ROOT/daemon"
rustup target add "$TARGET" >/dev/null
cargo build --release --target "$TARGET"
install_bin "$ROOT/daemon/target/${TARGET}/release/bgfreeze"
