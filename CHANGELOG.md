# Changelog

All notable changes to **screen-share-ngx** are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] — 2026-06-23

Fixes for two streaming issues reported against 1.0.0.

### Fixed

- **Stream played at reduced resolution.** The WebRTC video source was created in
  the default (camera) mode, whose quality scaler downscales resolution under
  CPU/bandwidth pressure. It's now created with `forScreenCast: true` and the
  sender uses `degradationPreference = maintainResolution`, so resolution stays
  sharp and frame rate is shed first instead — the right trade-off for legible text.
- **Viewers saw "offline" after refreshing while the publisher was still running.**
  ScreenCaptureKit stops delivering frames when the screen is static, starving the
  encoder so a refreshing/late-joining viewer couldn't be sent a keyframe. Added a
  ~3 fps frame heartbeat that re-pushes the last frame while idle, keeping the
  encoder live and the input joinable.

### Changed

- Capture now uses the display's true framebuffer resolution (`CGDisplayMode`
  pixel dimensions) instead of a hardcoded ×2, which was wrong on non-2x and
  scaled displays.
- ICE connection-state changes are logged in human-readable form, so a dropped
  publisher connection (`DISCONNECTED`/`FAILED`) is visible in the terminal.
- `--version` now reports `1.0.1` (was incorrectly `0.1.0`).

## [1.0.0] — 2026-06-22

First stable release. **screen-share-ngx** is a macOS command-line tool that
captures a display, hardware-encodes it, and publishes it to a randomized public
URL with **sub-second latency** — built on the newest standardized streaming
transport (WebRTC over WHIP/WHEP) and Cloudflare's edge.

```
ScreenCaptureKit ─► libwebrtc (VideoToolbox H.264/H.265) ─WHIP─► Cloudflare Stream edge
                                                                       │
   viewer ◄── WHEP player page ◄── Cloudflare Worker (random room URL) ◄┘
```

### Highlights

- **Hardware-accelerated end to end.** ScreenCaptureKit delivers zero-copy
  IOSurface frames straight from the window server; VideoToolbox does the H.264/
  H.265 encode on the Apple Silicon media engine. No CPU copy on the capture path.
- **Sub-second latency.** WebRTC ingest via **WHIP** (RFC 9725) and playback via
  **WHEP**, fanned out over Cloudflare Stream's edge.
- **One public URL, no app to install for viewers.** Each session gets an
  unguessable room at `https://<your-worker>.workers.dev/r/<random>`, served as a
  dependency-free WHEP player page that works in the browser.
- **Direct-to-edge publish.** The CLI streams straight to Cloudflare — no proxy
  hop — for the lowest latency.

### Added

- **CLI (`screenshare start`)** with `--display`, `--fps` (default 60),
  `--bitrate` (default 8M; accepts `8M`/`12000k`/raw bits), `--codec`
  (`h264` default, `h265` optional), and `--shows-cursor`.
- **Setup wizard (`scripts/setup.sh` / `make setup`)** that does the whole
  Cloudflare setup interactively: `wrangler login`, account-id detection, KV
  namespace creation, **`SHARED_SECRET` generation** (`openssl rand -hex 32`),
  hidden Stream-token prompt, Worker deploy, and writes
  `~/.config/screenshare/config.json`. Idempotent; `--rotate-secret` to mint a new secret.
- **Zero-flag operation after setup.** Credential resolution precedence:
  flag → environment variable → config file (`$SCREENSHARE_CONFIG` to override path).
- **Cloudflare Worker** that mints unguessable 20-character rooms (6-hour TTL via
  KV), creates a Stream Live Input (`recording: off` for lowest latency), and
  serves the WHEP viewer. The Cloudflare API token never leaves the Worker.
- **Self-contained release kit.** GitHub Releases ship a macOS (Apple Silicon)
  tarball containing the binary, `WebRTC.framework`, the wizard, and the Worker
  source — so it installs and deploys with **no repo clone and no Swift toolchain**.
- **Release automation** (`.github/workflows/release.yml`): tag `v*` to build,
  bundle, ad-hoc sign, checksum, and publish.

### Install

**Prebuilt (recommended)** — download the latest kit from the
[Releases](../../releases/latest) page:

```bash
tar -xzf screenshare-1.0.0-macos-arm64.tar.gz
cd screenshare-1.0.0-macos-arm64
xattr -dr com.apple.quarantine .     # un-notarized build
./scripts/setup.sh                   # deploys your Worker + writes config
./screenshare start
```

**From source:**

```bash
make build && make setup && .build/release/screenshare start
```

### Requirements

- macOS 13+ on **Apple Silicon**
- **Node** (for `wrangler`) and a **Cloudflare account with Stream** enabled,
  plus a Stream API token (Account · Stream · Edit)
- Building from source additionally needs a **Swift 5.10+** toolchain
- The macOS **Screen Recording** permission (prompted on first capture)

### Security

- Rooms are unguessable 20-character slugs that self-expire after 6 hours.
- The CLI authenticates to the Worker with a generated bearer secret; the
  Cloudflare account token stays server-side in the Worker.
- The local config file is written `chmod 600`.

### Known limitations

- **Video only** — no audio in this release.
- **Apple Silicon only** — no Intel/universal binary.
- **Un-notarized** — downloaders must clear the Gatekeeper quarantine flag
  (`xattr -dr com.apple.quarantine`).
- **H.265 over WHEP** has inconsistent browser playback; **H.264 is the default**
  and most broadly compatible.
- **AV1 is not offered for encode** — no current Apple Silicon has a hardware AV1
  encoder, and software AV1 would defeat the performance goal.
- Tuned for a **small audience**; Cloudflare's edge can fan out further if needed.

### Notes for builders

- `make build` resolves dependencies, applies a WebRTC header workaround, then
  builds. The workaround ([`scripts/patch-webrtc-headers.sh`](scripts/patch-webrtc-headers.sh))
  fixes `stasel/WebRTC` v149's macOS XCFramework slice, which ships without its
  per-class headers. Re-run `make patch` after `swift package clean`.

[1.0.1]: ../../releases/tag/v1.0.1
[1.0.0]: ../../releases/tag/v1.0.0
