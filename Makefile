#!/usr/bin/make -f
# ─────────────────────────────────────────────────────────────────────────────
# Unified build system for Litter (iOS + Android + shared Rust bridge)
#
# Usage:
#   make ios             # full iOS pipeline (rust + frameworks + xcode build)
#   make android         # full Android pipeline (rust + gradle build)
#   make all             # both platforms
#
#   make ios-sim         # iOS for simulator only (faster, arm64-sim)
#   make ios-device      # iOS for device only
#   make ios-run         # build + open Xcode
#
#   make android-debug   # Android debug APK (both flavors)
#   make android-remote  # Android remote-only debug APK
#   make android-device  # Android on-device debug APK
#   make android-install # build + install remote-only to emulator
#
#   make rust-ios        # just the Rust xcframework (device + sim)
#   make rust-android    # just the Android JNI .so files
#   make bindings        # regenerate UniFFI bindings (swift + kotlin)
#   make bindings-swift  # swift bindings only
#   make bindings-kotlin # kotlin bindings only
#
#   make patch           # apply codex submodule patches
#   make unpatch         # revert codex submodule patches
#   make sync            # sync codex submodule
#   make xcgen           # regenerate Xcode project from project.yml
#   make ios-frameworks  # download ios_system xcframeworks
#
#   make clean           # remove build artifacts + caches
#   make clean-rust      # remove only Rust target dir
#   make clean-ios       # remove iOS frameworks + derived data
#   make clean-android   # remove Android build dir
#
# Cache: Rust compilation is cached via cargo's incremental compilation.
#        Stamp files in .build-stamps/ track completed steps so repeated
#        `make` invocations skip work that's already done.
# ─────────────────────────────────────────────────────────────────────────────

SHELL := /bin/bash
.DEFAULT_GOAL := all

# ── Paths ────────────────────────────────────────────────────────────────────
ROOT          := $(shell pwd)
STAMPS        := $(ROOT)/.build-stamps
RUST_DIR      := $(ROOT)/shared/rust-bridge
RUST_TARGET   := $(RUST_DIR)/target
SUBMODULE_DIR := $(ROOT)/shared/third_party/codex
IOS_DIR       := $(ROOT)/apps/ios
IOS_SCRIPTS   := $(IOS_DIR)/scripts
IOS_FW_DIR    := $(IOS_DIR)/Frameworks
IOS_SOURCES   := $(IOS_DIR)/Sources
ANDROID_DIR   := $(ROOT)/apps/android
ANDROID_JNI   := $(ANDROID_DIR)/core/bridge/src/main/jniLibs
GENERATED_DIR := $(RUST_DIR)/generated
PATCHES_DIR   := $(ROOT)/patches/codex

# ── Configuration ────────────────────────────────────────────────────────────
IOS_DEPLOYMENT_TARGET ?= 18.0
IOS_SIM_DEVICE        ?= iPhone 17 Pro
IOS_SCHEME            ?= Litter
ANDROID_VARIANT       ?= debug
XCODE_CONFIG          ?= Debug
IOS_CLANGXX_WRAPPER   := $(IOS_SCRIPTS)/ios-clangxx-wrapper.sh
CARGO_FEATURES        ?=

# ── sccache detection ────────────────────────────────────────────────────────
SCCACHE := $(shell command -v sccache 2>/dev/null)
ifneq ($(SCCACHE),)
  export RUSTC_WRAPPER    := $(SCCACHE)
  export CARGO_INCREMENTAL := 0
  $(info [cache] Using sccache: $(SCCACHE))
endif

# Patch files to apply to codex submodule
PATCH_FILES := $(PATCHES_DIR)/ios-exec-hook.patch

# Rust source fingerprint inputs
RUST_SOURCES := $(shell find $(RUST_DIR)/codex-mobile-client/src $(RUST_DIR)/codex-bridge/src -name '*.rs' 2>/dev/null)
CARGO_TOMLS  := $(RUST_DIR)/Cargo.toml $(RUST_DIR)/codex-mobile-client/Cargo.toml $(RUST_DIR)/codex-bridge/Cargo.toml

# ── Stamp files (build cache markers) ───────────────────────────────────────
STAMP_SYNC         := $(STAMPS)/sync
STAMP_PATCH        := $(STAMPS)/patch
STAMP_BINDINGS_S   := $(STAMPS)/bindings-swift
STAMP_BINDINGS_K   := $(STAMPS)/bindings-kotlin
STAMP_RUST_IOS_DEV := $(STAMPS)/rust-ios-device
STAMP_RUST_IOS_SIM := $(STAMPS)/rust-ios-sim
STAMP_XCFRAMEWORK  := $(STAMPS)/xcframework
STAMP_IOS_SYSTEM   := $(STAMPS)/ios-system-frameworks
STAMP_XCGEN        := $(STAMPS)/xcgen
STAMP_RUST_ANDROID := $(STAMPS)/rust-android

# ── Ensure stamp dir exists ─────────────────────────────────────────────────
$(shell mkdir -p $(STAMPS))

# ── Export env for Rust iOS cross-compilation ────────────────────────────────
export IPHONEOS_DEPLOYMENT_TARGET := $(IOS_DEPLOYMENT_TARGET)
export CXX_aarch64_apple_ios     := $(IOS_CLANGXX_WRAPPER)
export CXX_aarch64_apple_ios_sim := $(IOS_CLANGXX_WRAPPER)
export CXX_x86_64_apple_ios      := $(IOS_CLANGXX_WRAPPER)

# ═════════════════════════════════════════════════════════════════════════════
# HIGH-LEVEL TARGETS
# ═════════════════════════════════════════════════════════════════════════════

.PHONY: all ios android ios-sim ios-device ios-run \
        android-debug android-remote android-device android-install \
        rust-ios rust-android bindings bindings-swift bindings-kotlin \
        patch unpatch sync xcgen ios-frameworks \
        clean clean-rust clean-ios clean-android help

all: ios android

ios: rust-ios ios-frameworks xcgen ios-build
ios-sim: rust-ios-sim-only ios-frameworks xcgen ios-build-sim
ios-device: rust-ios-device-only ios-frameworks xcgen ios-build-device
ios-run: ios
	@echo "==> Opening Xcode..."
	@open $(IOS_DIR)/Litter.xcodeproj

android: rust-android android-debug

help:
	@head -36 $(ROOT)/Makefile | tail -33

# ═════════════════════════════════════════════════════════════════════════════
# SUBMODULE & PATCHES
# ═════════════════════════════════════════════════════════════════════════════

sync: $(STAMP_SYNC)
$(STAMP_SYNC):
	@echo "==> Syncing codex submodule..."
	@$(IOS_SCRIPTS)/sync-codex.sh --preserve-current
	@touch $@

patch: $(STAMP_PATCH)
$(STAMP_PATCH): $(STAMP_SYNC) $(PATCH_FILES)
	@echo "==> Applying patches..."
	@for pf in $(PATCH_FILES); do \
		name=$$(basename "$$pf"); \
		if git -C $(SUBMODULE_DIR) apply --reverse --check "$$pf" >/dev/null 2>&1; then \
			echo "    $$name already applied"; \
		elif git -C $(SUBMODULE_DIR) apply --check "$$pf" >/dev/null 2>&1; then \
			echo "    Applying $$name..."; \
			git -C $(SUBMODULE_DIR) apply "$$pf"; \
		else \
			echo "ERROR: $$name does not apply cleanly" >&2; exit 1; \
		fi; \
	done
	@touch $@

unpatch:
	@echo "==> Reverting patches..."
	@for pf in $(PATCH_FILES); do \
		name=$$(basename "$$pf"); \
		if git -C $(SUBMODULE_DIR) apply --reverse --check "$$pf" >/dev/null 2>&1; then \
			echo "    Reverting $$name..."; \
			git -C $(SUBMODULE_DIR) apply --reverse "$$pf"; \
		else \
			echo "    $$name not currently applied"; \
		fi; \
	done
	@rm -f $(STAMP_PATCH)

# ═════════════════════════════════════════════════════════════════════════════
# UNIFFI BINDINGS
# ═════════════════════════════════════════════════════════════════════════════

bindings: bindings-swift bindings-kotlin

bindings-swift: $(STAMP_BINDINGS_S)
$(STAMP_BINDINGS_S): $(STAMP_SYNC) $(RUST_SOURCES) $(CARGO_TOMLS)
	@echo "==> Generating Swift bindings..."
	@cd $(RUST_DIR) && ./generate-bindings.sh --swift-only
	@cp $(GENERATED_DIR)/swift/codex_mobile_client.swift \
	    $(IOS_SOURCES)/Litter/Bridge/UniFFICodexClient.generated.swift
	@touch $@

bindings-kotlin: $(STAMP_BINDINGS_K)
$(STAMP_BINDINGS_K): $(STAMP_SYNC) $(RUST_SOURCES) $(CARGO_TOMLS)
	@echo "==> Generating Kotlin bindings..."
	@cd $(RUST_DIR) && ./generate-bindings.sh --kotlin-only
	@touch $@

# ═════════════════════════════════════════════════════════════════════════════
# RUST — iOS
# ═════════════════════════════════════════════════════════════════════════════

# Device static lib
$(STAMP_RUST_IOS_DEV): $(STAMP_PATCH) $(STAMP_BINDINGS_S) $(RUST_SOURCES) $(CARGO_TOMLS)
	@echo "==> Building Rust for iOS device (aarch64-apple-ios)..."
	@rustup target add aarch64-apple-ios
	@cargo rustc --manifest-path $(RUST_DIR)/Cargo.toml \
		-p codex-mobile-client --release \
		--target aarch64-apple-ios --crate-type staticlib $(CARGO_FEATURES)
	@touch $@

# Simulator static lib (arm64 only — Apple Silicon)
$(STAMP_RUST_IOS_SIM): $(STAMP_PATCH) $(STAMP_BINDINGS_S) $(RUST_SOURCES) $(CARGO_TOMLS)
	@echo "==> Building Rust for iOS simulator (aarch64-apple-ios-sim)..."
	@rustup target add aarch64-apple-ios-sim
	@cargo rustc --manifest-path $(RUST_DIR)/Cargo.toml \
		-p codex-mobile-client --release \
		--target aarch64-apple-ios-sim --crate-type staticlib $(CARGO_FEATURES)
	@touch $@

# XCFramework (device + sim)
$(STAMP_XCFRAMEWORK): $(STAMP_RUST_IOS_DEV) $(STAMP_RUST_IOS_SIM)
	@echo "==> Creating codex_mobile_client.xcframework (device + simulator)..."
	@rm -rf $(IOS_FW_DIR)/codex_mobile_client.xcframework
	@mkdir -p $(IOS_FW_DIR)
	@xcodebuild -create-xcframework \
		-library $(RUST_TARGET)/aarch64-apple-ios/release/libcodex_mobile_client.a \
		-headers $(GENERATED_DIR)/swift \
		-library $(RUST_TARGET)/aarch64-apple-ios-sim/release/libcodex_mobile_client.a \
		-headers $(GENERATED_DIR)/swift \
		-output $(IOS_FW_DIR)/codex_mobile_client.xcframework
	@touch $@

# Convenience targets
rust-ios: $(STAMP_XCFRAMEWORK)

rust-ios-sim-only: $(STAMP_PATCH) $(STAMP_BINDINGS_S)
	@echo "==> Building Rust for iOS simulator only..."
	@rustup target add aarch64-apple-ios-sim
	@cargo rustc --manifest-path $(RUST_DIR)/Cargo.toml \
		-p codex-mobile-client --release \
		--target aarch64-apple-ios-sim --crate-type staticlib $(CARGO_FEATURES)
	@rm -rf $(IOS_FW_DIR)/codex_mobile_client.xcframework
	@mkdir -p $(IOS_FW_DIR)
	@xcodebuild -create-xcframework \
		-library $(RUST_TARGET)/aarch64-apple-ios-sim/release/libcodex_mobile_client.a \
		-headers $(GENERATED_DIR)/swift \
		-output $(IOS_FW_DIR)/codex_mobile_client.xcframework

rust-ios-device-only: $(STAMP_PATCH) $(STAMP_BINDINGS_S)
	@echo "==> Building Rust for iOS device only..."
	@rustup target add aarch64-apple-ios
	@cargo rustc --manifest-path $(RUST_DIR)/Cargo.toml \
		-p codex-mobile-client --release \
		--target aarch64-apple-ios --crate-type staticlib $(CARGO_FEATURES)
	@rm -rf $(IOS_FW_DIR)/codex_mobile_client.xcframework
	@mkdir -p $(IOS_FW_DIR)
	@xcodebuild -create-xcframework \
		-library $(RUST_TARGET)/aarch64-apple-ios/release/libcodex_mobile_client.a \
		-headers $(GENERATED_DIR)/swift \
		-output $(IOS_FW_DIR)/codex_mobile_client.xcframework

# ═════════════════════════════════════════════════════════════════════════════
# RUST — Android
# ═════════════════════════════════════════════════════════════════════════════

rust-android: $(STAMP_RUST_ANDROID)
$(STAMP_RUST_ANDROID): $(STAMP_SYNC) $(STAMP_BINDINGS_K) $(RUST_SOURCES) $(CARGO_TOMLS)
	@echo "==> Building Rust for Android (arm64-v8a + x86_64)..."
	@$(ROOT)/tools/scripts/build-android-rust.sh
	@touch $@

# ═════════════════════════════════════════════════════════════════════════════
# iOS FRAMEWORKS & PROJECT
# ═════════════════════════════════════════════════════════════════════════════

ios-frameworks: $(STAMP_IOS_SYSTEM)
$(STAMP_IOS_SYSTEM):
	@echo "==> Downloading ios_system frameworks..."
	@$(IOS_SCRIPTS)/download-ios-system.sh
	@touch $@

xcgen: $(STAMP_XCGEN)
$(STAMP_XCGEN): $(IOS_DIR)/project.yml
	@echo "==> Regenerating Xcode project..."
	@xcodegen generate --spec $(IOS_DIR)/project.yml --project $(IOS_DIR)/Litter.xcodeproj
	@touch $@

# ═════════════════════════════════════════════════════════════════════════════
# iOS XCODE BUILD
# ═════════════════════════════════════════════════════════════════════════════

.PHONY: ios-build ios-build-sim ios-build-device

ios-build:
	@echo "==> Building iOS ($(XCODE_CONFIG), device + simulator)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'generic/platform=iOS' \
		build \
		| tail -20

ios-build-sim:
	@echo "==> Building iOS ($(XCODE_CONFIG), simulator)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM_DEVICE)' \
		build \
		| tail -20

ios-build-device:
	@echo "==> Building iOS ($(XCODE_CONFIG), device)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'generic/platform=iOS' \
		build \
		| tail -20

# ═════════════════════════════════════════════════════════════════════════════
# ANDROID GRADLE BUILD
# ═════════════════════════════════════════════════════════════════════════════

android-debug:
	@echo "==> Building Android debug (both flavors)..."
	@cd $(ANDROID_DIR) && ./gradlew :app:assembleOnDeviceDebug :app:assembleRemoteOnlyDebug

android-remote:
	@echo "==> Building Android remote-only debug..."
	@cd $(ANDROID_DIR) && ./gradlew :app:assembleRemoteOnlyDebug

android-device:
	@echo "==> Building Android on-device debug..."
	@cd $(ANDROID_DIR) && ./gradlew :app:assembleOnDeviceDebug

android-install: android-remote
	@echo "==> Installing remote-only APK to emulator..."
	@adb -e install -r $(ANDROID_DIR)/app/build/outputs/apk/remoteOnly/debug/app-remoteOnly-debug.apk

# ═════════════════════════════════════════════════════════════════════════════
# TESTS
# ═════════════════════════════════════════════════════════════════════════════

.PHONY: test test-rust test-ios test-android

test: test-rust test-ios test-android

test-rust:
	@echo "==> Running Rust tests..."
	@cargo test -p codex-mobile-client --lib

test-ios: xcgen
	@echo "==> Running iOS tests..."
	@xcodebuild test -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration Debug \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM_DEVICE)' \
		| tail -30

test-android:
	@echo "==> Running Android tests..."
	@cd $(ANDROID_DIR) && ./gradlew :app:testOnDeviceDebugUnitTest :app:testRemoteOnlyDebugUnitTest

# ═════════════════════════════════════════════════════════════════════════════
# RELEASE
# ═════════════════════════════════════════════════════════════════════════════

.PHONY: testflight play-upload

testflight: ios
	@echo "==> Uploading to TestFlight..."
	@$(IOS_SCRIPTS)/testflight-upload.sh

play-upload: android
	@echo "==> Uploading to Google Play..."
	@$(ANDROID_DIR)/scripts/play-upload.sh

# ═════════════════════════════════════════════════════════════════════════════
# CLEAN
# ═════════════════════════════════════════════════════════════════════════════

clean: clean-rust clean-ios clean-android
	@rm -rf $(STAMPS)
	@echo "==> Clean complete"

clean-rust:
	@echo "==> Cleaning Rust build artifacts..."
	@rm -rf $(RUST_TARGET)
	@rm -f $(STAMPS)/rust-* $(STAMPS)/bindings-* $(STAMPS)/sync $(STAMPS)/patch

clean-ios:
	@echo "==> Cleaning iOS artifacts..."
	@rm -rf $(IOS_FW_DIR)/codex_mobile_client.xcframework
	@rm -f $(STAMPS)/xcframework $(STAMPS)/xcgen $(STAMPS)/ios-system-frameworks

clean-android:
	@echo "==> Cleaning Android artifacts..."
	@rm -rf $(ANDROID_JNI)/arm64-v8a $(ANDROID_JNI)/x86_64
	@rm -f $(STAMPS)/rust-android
	@cd $(ANDROID_DIR) && ./gradlew clean 2>/dev/null || true

# ═════════════════════════════════════════════════════════════════════════════
# CACHE INVALIDATION
# ═════════════════════════════════════════════════════════════════════════════

# Force rebuild of a specific stage by removing its stamp:
#   make rebuild-rust-ios   → force Rust iOS recompilation
#   make rebuild-bindings   → force binding regeneration
.PHONY: rebuild-rust-ios rebuild-rust-android rebuild-bindings rebuild-xcframework

rebuild-rust-ios:
	@rm -f $(STAMP_RUST_IOS_DEV) $(STAMP_RUST_IOS_SIM) $(STAMP_XCFRAMEWORK)
	@$(MAKE) rust-ios

rebuild-rust-android:
	@rm -f $(STAMP_RUST_ANDROID)
	@$(MAKE) rust-android

rebuild-bindings:
	@rm -f $(STAMP_BINDINGS_S) $(STAMP_BINDINGS_K)
	@$(MAKE) bindings

rebuild-xcframework:
	@rm -f $(STAMP_XCFRAMEWORK)
	@$(MAKE) $(STAMP_XCFRAMEWORK)
