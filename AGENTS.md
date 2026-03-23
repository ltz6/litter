# Repository Guidelines

## Project Structure & Module Organization
- `apps/ios/Sources/Litter/` contains the iOS app code.
- `apps/ios/Sources/Litter/Views/` holds SwiftUI screens, `Models/` contains app state/session logic, and `Bridge/` contains JSON-RPC + C FFI bridge code.
- `apps/android/app/src/main/java/com/litter/android/ui/` contains Android Compose shell/screens.
- `apps/android/app/src/main/java/com/litter/android/state/` contains Android app state, server/session manager, SSH, and websocket transport.
- `apps/android/core/bridge/` contains Android core native bridge bootstrap and websocket client.
- `apps/android/core/network/` contains Android discovery services (Bonjour/Tailscale/LAN probing).
- `apps/android/app/src/test/java/` contains Android unit tests.
- `apps/android/docs/qa-matrix.md` tracks Android parity QA coverage.
- `shared/rust-bridge/codex-mobile-client/` is the shared Rust client library consumed by both iOS and Android. Modules: `types/` (protocol types), `transport/` (WebSocket + in-process channel + JSON-RPC), `session/` (connection, threads, events, voice handoff), `auth.rs`, `discovery.rs`, `ssh.rs`, `parser.rs`, `hydration.rs`. `MobileClient` is the top-level facade both platforms interact with.
- `shared/rust-bridge/codex-bridge/` has C FFI entry points (`codex_mobile_client_init/call/destroy/subscribe_events`) exposed through `shared/rust-bridge/codex-bridge/include/codex_bridge.h`.
- `apps/ios/Sources/Litter/Bridge/Rust*.swift` — iOS bridge files mapping Swift to the shared Rust layer.
- `apps/android/core/bridge/.../Rust*.kt` — Android bridge files mapping Kotlin to the shared Rust layer.
- `shared/third_party/codex/` is the upstream Codex submodule.
- `apps/ios/Frameworks/` contains generated/downloaded iOS XCFrameworks (`codex_bridge.xcframework` and `ios_system/*`); these artifacts are not committed.
- `apps/ios/project.yml` is the source of truth for project generation; regenerate `apps/ios/Litter.xcodeproj` instead of hand-editing project files.

## Architecture
- **iOS root layout:** `ContentView` uses a `ZStack` with a persistent `HeaderView`, main content area, and a `SidebarOverlay` that slides from the left.
- **iOS state management:** `AppStore` (Rust, via UniFFI) is the canonical runtime state owner. `AppModel` is the thin Swift observation shell over Rust snapshots and updates. `AppState` is UI-only state.
- **iOS server flow:** discovery and SSH are separate utility bridges; thread/session/account operations come from generated Rust RPC plus store updates.
- **Android root layout:** `LitterAppShell` is the Compose entry; `DefaultLitterAppState` maps backend state into UI state.
- **Android state/transport:** Android should converge on the same Rust-owned runtime model as iOS instead of re-implementing shared session/thread/account logic in Kotlin.
- **Android server flow:** Discovery sheet + SSH login sheet + settings/account sheets drive connection, auth, and server management.
- **Message rendering parity:** both platforms support reasoning/system sections, code block rendering, and inline image handling.

### Shared Rust Layer
- `codex-mobile-client` is the shared client library that owns transport, session management, auth, discovery, SSH, hydration, reconciliation, and canonical app/runtime state for both platforms.
- `AppStore` is the Rust-owned state surface. It owns snapshots, typed updates, and the small set of truly composite/store-local actions.
- `AppServerRpc` is the generated public UniFFI RPC surface for direct upstream app-server methods and types.
- `DiscoveryBridge` and `SshBridge` are separate Rust utility surfaces. Do not move discovery/SSH policy back into Swift/Kotlin.
- `codex-bridge` wraps `codex-mobile-client` with C FFI entry points so each platform can call into Rust via a thin native bridge.
- iOS uses UniFFI-generated Swift plus thin bridge helpers; Android uses UniFFI-generated Kotlin plus thin bridge helpers.

## Feature Placement Rules
- Prefer Rust first. If logic is about session state, thread state, streaming, hydration, approvals, auth/account, discovery merge policy, voice transcript/handoff normalization, or status normalization, it belongs in `shared/rust-bridge/codex-mobile-client/`.
- Keep Swift/Kotlin thin. Platform code should only own UI, platform persistence, platform permissions, audio/session APIs, notifications, ActivityKit/CarPlay/Android services, and render-only projections.
- Do not parse upstream wire-format strings in Swift/Kotlin. If a status, event kind, or payload shape matters to both platforms, expose it as a typed UniFFI enum/record from Rust.
- Do not duplicate merge/reducer/state-machine logic in iOS or Android. Shared reconciliation belongs in Rust reducer/store code.
- If upstream app-server already has a good method/type, use it through generated `AppServerRpc` instead of adding a handwritten wrapper on `AppStore`.
- Keep the generator generic. Do not encode per-method reconciliation policy in codegen. Put convergence logic in handwritten Rust reducer/reconcile code.
- `AppStore` should stay minimal: snapshots, subscriptions, and truly composite/store-local actions only. Plain upstream RPC passthroughs belong on generated `AppServerRpc`.
- Prefer authoritative updates. Store state should be populated from upstream events first, then targeted refresh/reconcile when upstream events are insufficient. Do not hand-patch platform state after RPC success.
- New boundary types that cross into Swift/Kotlin should be UniFFI-safe Rust records/enums. Internal Rust-only state can stay richer and non-UniFFI.
- Generated Rust sources must stay local-only. Use `*.generated.rs` filenames and do not commit generated Rust files; regenerate them via `./shared/rust-bridge/generate-bindings.sh`.

## Where To Implement New Work
- Add or change upstream protocol coverage:
  - update `shared/rust-bridge/codegen/src/main.rs`
  - regenerate bindings
  - do not hand-maintain parallel RPC wrappers unless the logic is genuinely composite
- Add canonical runtime state, reducer logic, or reconciliation:
  - `shared/rust-bridge/codex-mobile-client/src/store/`
- Add conversation hydration, typed item shaping, or shared status normalization:
  - `shared/rust-bridge/codex-mobile-client/src/conversation.rs`
  - `shared/rust-bridge/codex-mobile-client/src/conversation_uniffi.rs`
  - `shared/rust-bridge/codex-mobile-client/src/uniffi_shared.rs`
- Add discovery ranking/dedupe/reconciliation:
  - `shared/rust-bridge/codex-mobile-client/src/discovery.rs`
  - `shared/rust-bridge/codex-mobile-client/src/discovery_uniffi.rs`
- Add voice transcript/handoff/shared realtime normalization:
  - `shared/rust-bridge/codex-mobile-client/src/store/voice.rs`
  - reducer/update boundary types in `store/`
- Add iOS-only behavior:
  - `apps/ios/Sources/Litter/Models/` for controllers/platform services
  - `apps/ios/Sources/Litter/Views/` for SwiftUI
  - keep those files free of shared protocol parsing and shared business rules
- Add Android-only behavior:
  - `apps/android/app/` and `apps/android/core/`
  - keep those files free of duplicated Rust-owned state/reducer logic

## Drift Guardrails
- Before adding new Swift/Kotlin logic, ask: would Android/iOS both need this behavior? If yes, put it in Rust.
- Before adding a new `String` status field to Swift/Kotlin models, ask: should this be a Rust enum instead? Usually yes.
- Before adding a new `AppStore` method, ask: is this a real composite/store action, or just an upstream RPC that should be generated on `AppServerRpc`?
- Before adding a new platform cache, ask: is this canonical runtime data that should live in the Rust store instead?
- When in doubt, prefer one shared Rust implementation plus a thin platform projection over two parallel native implementations.

## Dependencies
### iOS (SPM via `apps/ios/project.yml`)
- **Citadel** — SSH client for remote server connections.
- **Textual** — Renders Markdown in assistant/system messages with custom theming (successor to MarkdownUI).
- **Inject** — Hot reload support for simulator development (Debug builds only).
### Android (Gradle)
- **Compose Material3** — primary Android UI toolkit.
- **Markwon** — Markdown rendering for assistant/system text.
- **JSch** — SSH transport for remote bootstrap flow.
- **androidx.security:security-crypto** — encrypted credential storage.
### Rust Shared Layer (Cargo)
- **codex-app-server-protocol**, **codex-app-server-client**, **codex-protocol**, **codex-core** — upstream Codex crates.
- **tokio-tungstenite** — async WebSocket transport.
- **russh** — SSH client (replacing Citadel on iOS and JSch on Android).
- **uniffi** — generates Swift/Kotlin bindings from Rust.
- **lru**, **base64**, **regex** — utility crates.

## Build System
The root `Makefile` is the primary build interface. It orchestrates submodule sync, patching, UniFFI binding generation, Rust cross-compilation, xcframework packaging, Xcode project generation, and platform builds — with stamp-file caching in `.build-stamps/` so repeated runs skip completed steps. If `sccache` is installed it is used automatically (`RUSTC_WRAPPER=sccache`, `CARGO_INCREMENTAL=0`).

### Common targets
| Target | Description |
|---|---|
| `make ios` | Full iOS pipeline: sync → patch → bindings → rust (device+sim) → xcframework → ios_system → xcgen → xcodebuild |
| `make ios-sim` | iOS for simulator only (arm64-sim, faster) |
| `make ios-device` | iOS for device only |
| `make ios-run` | Full iOS build then opens Xcode |
| `make android` | Full Android pipeline: sync → kotlin bindings → rust JNI → gradle assemble |
| `make android-remote` | Android remote-only debug APK |
| `make android-install` | Build + install remote-only APK to emulator |
| `make all` | Both platforms |
| `make rust-ios` | Just the Rust xcframework |
| `make rust-android` | Just the Android JNI `.so` files |
| `make bindings` | Regenerate UniFFI Swift + Kotlin bindings |
| `make xcgen` | Regenerate `Litter.xcodeproj` from `project.yml` |
| `make test` | Run Rust + iOS + Android tests |
| `make testflight` | Full iOS build + TestFlight upload |
| `make play-upload` | Full Android build + Google Play upload |
| `make clean` | Remove all build artifacts + stamp cache |

### Cache invalidation
- `make rebuild-rust-ios` / `make rebuild-rust-android` / `make rebuild-bindings` — force-rebuild a specific stage.
- `make clean-rust` / `make clean-ios` / `make clean-android` — remove platform-specific artifacts.

### Configuration overrides (env vars)
- `IOS_SIM_DEVICE` — simulator name (default: `iPhone 17 Pro`)
- `XCODE_CONFIG` — Xcode build configuration (default: `Debug`)
- `IOS_SCHEME` — Xcode scheme (default: `Litter`)
- `IOS_DEPLOYMENT_TARGET` — minimum iOS version (default: `18.0`)

### Individual scripts (called by Make, can also be run standalone)
- `./apps/ios/scripts/build-rust.sh` — cross-compile Rust for iOS, create `codex_mobile_client.xcframework`
- `./apps/ios/scripts/download-ios-system.sh` — download `ios_system` XCFrameworks
- `./apps/ios/scripts/sync-codex.sh` — sync codex submodule + apply patches
- `./apps/ios/scripts/regenerate-project.sh` — regenerate Xcode project via xcodegen
- `./apps/ios/scripts/testflight-upload.sh` — archive, export IPA, upload to TestFlight
- `./shared/rust-bridge/generate-bindings.sh` — generate UniFFI Swift/Kotlin bindings
- `./tools/scripts/build-android-rust.sh` — cross-compile Rust JNI libs for Android via `cargo-ndk`

### Hot Reload (InjectionIII)
- Install: `brew install --cask injectioniii`
- Key views have `@ObserveInjection` + `.enableInjection()` wired up (ContentView, ConversationView, HeaderView, SessionSidebarView, MessageBubbleView).
- Debug builds include `-Xlinker -interposable` in linker flags.
- Run the app in simulator, open InjectionIII pointed at the project directory, then save any Swift file to see changes without relaunching.

## Coding Style & Naming Conventions
- Swift style follows standard Xcode defaults: 4-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for properties/functions.
- Kotlin style follows standard Android/Kotlin conventions: 4-space indentation, `UpperCamelCase` types, `lowerCamelCase` members.
- Dark theme: pure `Color.black` backgrounds, `#00FF9C` accent, `SFMono-Regular` font throughout.
- Keep concurrency boundaries explicit (`actor`, `@MainActor`) and avoid cross-actor mutable state.
- Group iOS files by layer (`Views`, `Models`, `Bridge`) and Android files by module (`app/ui`, `app/state`, `core/*`).
- No repository-local SwiftLint/SwiftFormat config is currently committed; keep formatting consistent with existing files.

## Testing Guidelines
- iOS tests: prefer XCTest and create `Tests/CodexIOSTests/` with files named `*Tests.swift`.
- Android tests: place unit tests under `apps/android/app/src/test/java/`.
- iOS test command: `xcodebuild test` using the same project/scheme/destination pattern as build commands.
- Android test command: `gradle -p apps/android :app:testOnDeviceDebugUnitTest :app:testRemoteOnlyDebugUnitTest`.
- Keep `apps/android/docs/qa-matrix.md` updated when parity scope changes.

## Commit & Pull Request Guidelines
- Use concise, imperative commit subjects with optional scope (example: `bridge: retry initialize handshake`).
- PRs should include: purpose, key changes, verification steps (commands/device), and screenshots for UI changes.
- If project structure changes, include updates to `apps/ios/project.yml` and mention whether project regeneration was run.
