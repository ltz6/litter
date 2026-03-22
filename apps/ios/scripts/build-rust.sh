#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$IOS_DIR/../.." && pwd)"
RUST_BRIDGE_DIR="$REPO_DIR/shared/rust-bridge"
FRAMEWORKS_DIR="$IOS_DIR/Frameworks"
GENERATED_SWIFT_DIR="$RUST_BRIDGE_DIR/generated/swift"
UNIFFI_OUT="$IOS_DIR/Sources/Litter/Bridge/UniFFICodexClient.generated.swift"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-18.0}"
SUBMODULE_DIR="$REPO_DIR/shared/third_party/codex"
IOS_CLANGXX_WRAPPER="$SCRIPT_DIR/ios-clangxx-wrapper.sh"
PATCH_FILES=(
  "$REPO_DIR/patches/codex/ios-exec-hook.patch"
)

SYNC_MODE="--preserve-current"
BUILD_INTEL_SIM=0
DEVICE_ONLY=0
CARGO_FEATURES=""
for arg in "$@"; do
  case "$arg" in
    --preserve-current|--recorded-gitlink)
      SYNC_MODE="$arg"
      ;;
    --with-intel-sim)
      BUILD_INTEL_SIM=1
      ;;
    --device-only)
      DEVICE_ONLY=1
      ;;
    --rpc-trace)
      CARGO_FEATURES="--features rpc-trace"
      ;;
    *)
      echo "usage: $(basename "$0") [--preserve-current|--recorded-gitlink] [--with-intel-sim] [--device-only] [--rpc-trace]" >&2
      exit 1
      ;;
  esac
done

PATCHES_WERE_APPLIED=()
for PATCH_FILE in "${PATCH_FILES[@]}"; do
  if git -C "$SUBMODULE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
    PATCHES_WERE_APPLIED+=("$PATCH_FILE")
  fi
done

cleanup_patch() {
  for PATCH_FILE in "${PATCH_FILES[@]}"; do
    local was_pre_applied=0
    for pre in "${PATCHES_WERE_APPLIED[@]+"${PATCHES_WERE_APPLIED[@]}"}"; do
      if [ "$pre" = "$PATCH_FILE" ]; then
        was_pre_applied=1
        break
      fi
    done
    if [ "$was_pre_applied" -eq 0 ] && git -C "$SUBMODULE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
      echo "==> Reverting $(basename "$PATCH_FILE")..."
      git -C "$SUBMODULE_DIR" apply --reverse "$PATCH_FILE"
    fi
  done
}

trap cleanup_patch EXIT

mkdir -p "$FRAMEWORKS_DIR"

export CXX_aarch64_apple_ios="$IOS_CLANGXX_WRAPPER"
export CXX_aarch64_apple_ios_sim="$IOS_CLANGXX_WRAPPER"
export CXX_x86_64_apple_ios="$IOS_CLANGXX_WRAPPER"

echo "==> Preparing codex submodule..."
"$SCRIPT_DIR/sync-codex.sh" "$SYNC_MODE"

echo "==> Regenerating UniFFI Swift bindings -> $UNIFFI_OUT"
cd "$RUST_BRIDGE_DIR"
"$RUST_BRIDGE_DIR/generate-bindings.sh" --swift-only
cp "$GENERATED_SWIFT_DIR/codex_mobile_client.swift" "$UNIFFI_OUT"

echo "==> Installing iOS targets..."
export IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"
if [ "$DEVICE_ONLY" -eq 1 ]; then
  rustup target add aarch64-apple-ios
elif [ "$BUILD_INTEL_SIM" -eq 1 ]; then
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
else
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim
fi

echo "==> Building codex-mobile-client for aarch64-apple-ios (device)..."
cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client --release --target aarch64-apple-ios --crate-type staticlib $CARGO_FEATURES

if [ "$DEVICE_ONLY" -eq 0 ]; then
  echo "==> Building codex-mobile-client for aarch64-apple-ios-sim (Apple Silicon simulator)..."
  cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client --release --target aarch64-apple-ios-sim --crate-type staticlib $CARGO_FEATURES

  SIMULATOR_LIB="$RUST_BRIDGE_DIR/target/aarch64-apple-ios-sim/release/libcodex_mobile_client.a"
  if [ "$BUILD_INTEL_SIM" -eq 1 ]; then
    echo "==> Building codex-mobile-client for x86_64-apple-ios (Intel simulator)..."
    cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client --release --target x86_64-apple-ios --crate-type staticlib $CARGO_FEATURES

    echo "==> Creating fat simulator lib..."
    mkdir -p "$RUST_BRIDGE_DIR/target/ios-sim-fat/release"
    lipo -create \
      "$RUST_BRIDGE_DIR/target/aarch64-apple-ios-sim/release/libcodex_mobile_client.a" \
      "$RUST_BRIDGE_DIR/target/x86_64-apple-ios/release/libcodex_mobile_client.a" \
      -output "$RUST_BRIDGE_DIR/target/ios-sim-fat/release/libcodex_mobile_client.a"
    SIMULATOR_LIB="$RUST_BRIDGE_DIR/target/ios-sim-fat/release/libcodex_mobile_client.a"
  fi
fi

echo "==> Creating xcframework..."
rm -rf "$FRAMEWORKS_DIR/codex_bridge.xcframework" "$FRAMEWORKS_DIR/codex_mobile_client.xcframework"
if [ "$DEVICE_ONLY" -eq 1 ]; then
  xcodebuild -create-xcframework \
    -library "$RUST_BRIDGE_DIR/target/aarch64-apple-ios/release/libcodex_mobile_client.a" \
    -headers "$GENERATED_SWIFT_DIR" \
    -output "$FRAMEWORKS_DIR/codex_mobile_client.xcframework"
else
  xcodebuild -create-xcframework \
    -library "$RUST_BRIDGE_DIR/target/aarch64-apple-ios/release/libcodex_mobile_client.a" \
    -headers "$GENERATED_SWIFT_DIR" \
    -library "$SIMULATOR_LIB" \
    -headers "$GENERATED_SWIFT_DIR" \
    -output "$FRAMEWORKS_DIR/codex_mobile_client.xcframework"
fi

echo "==> Done: $FRAMEWORKS_DIR/codex_mobile_client.xcframework"
echo "==> Done: $UNIFFI_OUT"
