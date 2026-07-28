# PR: iOS jailbreak device automation backend

## Summary

This PR adds **iOS device automation for a rootless jailbreak** (Dopamine + ElleKit)
to Operit2, and wires it into the **existing official `operit/runtime` channel** and
the **official `DeviceAutomationHost` trait**. It is additive and does not change any
existing method signatures, so it is safe to merge and keeps the official frontend
intact.

On a sandboxed iOS app the screen cannot be captured and the UI cannot be driven
directly. This PR bridges that gap with a **SpringBoard tweak** (Unix socket) and a
**per-app injection**, driven by a **Rust agent daemon** that runs the visual agent
loop (screenshot → model → action). The app talks to the daemon over
`operit.sock` / `agent.sock`.

> This started as a concept-validation fork to show that iOS jailbreak device
> automation is feasible and can sit on top of Operit2's existing architecture.
> Feedback on the integration approach is very welcome.

## What's included

### Core (`operit-host-api`)
- New `DeviceAutomationHost` trait with `NormalizedPoint` and `DeviceScreenshot`.
- iOS host descriptor: a `deviceAutomationHost` field + `withDeviceAutomationHost`
  builder on `HostManager` and `createRuntimeHostManager`.
- All other platforms default the field to `None` → backward compatible.

### iOS host (`hosts/ios`, new crate `operit-host-ios-native`)
- `device_automation`: bridges the SpringBoard tweak over `operit.sock`
  (screenshot / tap / swipe / longpress / type / launch / home / back /
  frontmost_app), using normalized 0..1 coordinates.
- `device_agent`: the visual agent loop (AutoGLM-Phone style: screenshot → model →
  `do()`/`finish()` → device action) reusing the shared parser.
- `operit_agent_daemon`: the LaunchDaemon binary serving `agent.sock`
  (ping / status / start / stop / goal).
- SpringBoard tweak (`operit-sb.x`) + per-app injection (`operit-app.x`), and rootless
  **deb packaging** (`DEBIAN/control`, `postinst`, `LaunchDaemon` plist,
  `build_deb.sh`, `packdeb.py`).
- Built with **rootless theos** + **cargo (`--target aarch64-apple-ios`)**.
  Prebuilt `.dylib` / `operit_agent_daemon` / `*.deb` are **excluded via `.gitignore`**
  and produced at build time.

### Flutter bridge (`apps/flutter/.../AppleRuntimeChannel.swift`)
- Replaces the `"iOS screenshot capture is not available to this native host"` stub
  with a real implementation that reaches the tweak over `operit.sock` and returns
  `{ imagePng, width, height }` matching the generated Dart response shape.
- Adds `ownerSystemDeviceAgent{ Ping, Status, Start, Stop, Goal }` handlers that
  forward to the agent daemon over `agent.sock` and return the raw protocol replies.

### Onboarding fix
- `ensureRuntimeHandle` now falls back to the platform default storage roots when
  they are not yet configured, instead of throwing
  `"Runtime and workspace roots are not configured"` and **hard-crashing onboarding**
  (a runtime call can occur before the storage step).

## How to build / test

- **Tweak + daemon + deb** (this PR's backend):
  ```sh
  cd hosts/ios
  # tweak (rootless theos)
  cd tweak && make   # produces operit-sb.dylib / operit-app.dylib
  # daemon
  cargo build --target aarch64-apple-ios --bin operit_agent_daemon
  # package
  cd ../deb && bash build_deb.sh
  ```
- **Flutter app**: built by the existing **iOS Flutter Build** CI (requires the
  `OperitPythonScientific` / `OperitToybox` / `operit_flutter_bridge` xcframeworks,
  which the CI environment provides). This PR does not change that build path.

## Verification

- [x] `operit-host-ios-native` + `operit_agent_daemon` build with
      `cargo build --target aarch64-apple-ios`.
- [x] `AppleRuntimeChannel.swift` passes `swiftc -parse`.
- [ ] Full `Runner.app` build (CI) — to confirm the Swift bridge compiles into the app.
- [ ] On-device end-to-end (tweak + daemon + deb installed on a jailbroken device).

## Notes / follow-ups

- **Base**: tag `v2.0.0-preview.4`.
- The Dart callers for `ownerSystemDeviceAgent*` require a new Rust host trait +
  `operit-core-proxy` codegen (generates `RuntimeHostInteractionKind` + request/response).
  That is a follow-up; the native half is included here so the channel is ready.
- Prebuilt binaries are intentionally not committed (gitignored); they are produced by
  the build scripts.
- Screenshot action coordinates are normalized 0..1 (matching the model's 0..999
  convention divided by 1000) so the tweak is resolution-independent.
