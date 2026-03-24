#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_DIR="$REPO_DIR/shared/rust-bridge"
OUT_DIR="$REPO_DIR/apps/android/core/bridge/src/main/jniLibs"
SYNC_SCRIPT="$REPO_DIR/apps/ios/scripts/sync-codex.sh"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo is required" >&2
  exit 1
fi

if ! command -v cargo-ndk >/dev/null 2>&1; then
  echo "error: cargo-ndk is required (install with: cargo install cargo-ndk)" >&2
  exit 1
fi

if [ -z "${ANDROID_NDK_HOME:-}" ] && [ -z "${ANDROID_NDK_ROOT:-}" ]; then
  echo "error: set ANDROID_NDK_HOME or ANDROID_NDK_ROOT" >&2
  exit 1
fi

if command -v sccache >/dev/null 2>&1; then
  export RUSTC_WRAPPER="$(command -v sccache)"
fi

echo "==> Preparing codex submodule..."
"$SYNC_SCRIPT" --preserve-current

echo "==> Installing Android Rust targets..."
rustup target add aarch64-linux-android x86_64-linux-android

mkdir -p "$OUT_DIR"

echo "==> Building codex_mobile_client Android shared libs..."
cd "$WORKSPACE_DIR"
cargo ndk -t arm64-v8a -t x86_64 -o "$OUT_DIR" build --release -p codex-mobile-client

echo "==> Building codex_bridge Android shared libs..."
cargo ndk -t arm64-v8a -t x86_64 -o "$OUT_DIR" build --release -p codex-bridge

echo "==> Done. Android JNI libs are in: $OUT_DIR"
