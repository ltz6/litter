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
- **iOS state management:** `ConversationStore` (ObservableObject) manages WebSocket connection, JSON-RPC calls, and message state. `AppState` (ObservableObject) manages UI state (sidebar, server, model/reasoning selection).
- **iOS server flow:** `DiscoveryView` (sheet) discovers and connects to servers; sidebar/session flows use `thread/list`, `thread/resume`, and `thread/start`.
- **Android root layout:** `LitterAppShell` is the Compose entry; `DefaultLitterAppState` maps backend state into UI state.
- **Android state/transport:** `ServerManager` handles multi-server threads/models/account state and routes notifications via `BridgeRpcTransport`.
- **Android server flow:** Discovery sheet + SSH login sheet + settings/account sheets drive connection, auth, and server management.
- **Message rendering parity:** both platforms support reasoning/system sections, code block rendering, and inline image handling.

### Shared Rust Layer
- `codex-mobile-client` is the shared client library that owns transport, session management, auth, discovery, and SSH for both platforms.
- `codex-bridge` wraps `codex-mobile-client` with C FFI entry points so each platform can call into Rust via a thin native bridge.
- iOS uses Swift bridge files (`Rust*.swift` in `Bridge/`) and Android uses Kotlin bridge files (`Rust*.kt` in `core/bridge/`) to map platform types to the Rust facade.

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
