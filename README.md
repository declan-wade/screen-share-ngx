# screen-share-ngx

A macOS CLI that captures a display, **hardware-encodes** it with VideoToolbox,
and publishes it over **WebRTC (WHIP/WHEP)** to **Cloudflare Stream** — yielding a
randomized public URL with **sub-second latency**.

```
ScreenCaptureKit ──► libwebrtc (VideoToolbox H.264/H.265) ──WHIP──► Cloudflare Stream edge
                                                                          │
  viewer ◄── WHEP player page ◄── Cloudflare Worker (random room URL) ◄────┘
```

Performance choices: zero-copy IOSurface frames from the window server, dedicated
hardware encode engine, direct edge ingest (the CLI publishes straight to
Cloudflare — no proxy hop), and WHIP/WHEP for the lowest-latency standardized
WebRTC signaling.

## Layout

| Path | What |
|------|------|
| `Sources/screenshare/` | Swift CLI (capture → encode → WHIP publish) |
| `worker/` | Cloudflare Worker (mints random rooms, serves WHEP viewer page) |

## 1. Deploy the Worker

The Worker holds your Cloudflare credentials so the CLI never sees them.

```bash
cd worker
npm install

# Create the KV namespace and paste the printed id into wrangler.toml (ROOMS binding)
npx wrangler kv namespace create ROOMS

# Edit wrangler.toml: set CF_ACCOUNT_ID under [vars]

# Secrets:
#  - a Cloudflare API token scoped to Stream:Edit  → https://dash.cloudflare.com/profile/api-tokens
#  - a shared secret you invent (the CLI must present it)
npx wrangler secret put CF_STREAM_TOKEN
npx wrangler secret put SHARED_SECRET

npx wrangler deploy   # prints e.g. https://screenshare.<you>.workers.dev
```

> Cloudflare Stream must be enabled on the account (the WebRTC WHIP/WHEP beta is
> part of Stream). Live inputs created here use `recording: off` for lowest latency.

## 2. Build the CLI

Requires macOS 13+ and a Swift 5.10+ toolchain (Xcode 15+ or the Swift toolchain).

```bash
make build      # resolve deps → patch WebRTC headers → swift build -c release
# binary at .build/release/screenshare
```

> **Why `make` and not just `swift build`:** the `stasel/WebRTC` v149 binary ships
> a broken macOS slice — its XCFramework is missing every per-class header, so
> `import WebRTC` won't compile. `make` runs [`scripts/patch-webrtc-headers.sh`](scripts/patch-webrtc-headers.sh),
> which reconstructs the macOS headers from the (complete, platform-neutral) iOS
> slice and regenerates a curated umbrella that omits iOS-only UIKit/EAGL/audio-session
> headers. Re-run `make patch` after any `swift package clean`.

First run triggers the **Screen Recording** permission prompt (System Settings →
Privacy & Security → Screen Recording). Grant it to the terminal/app launching the
binary, then re-run.

## 3. Go live

```bash
export SCREENSHARE_WORKER="https://screenshare.<you>.workers.dev"
export SCREENSHARE_TOKEN="<the SHARED_SECRET you set>"

.build/release/screenshare start            # capture main display, 60fps, 8Mbps, H.264
```

```
────────────────────────────────────────────────────────────
  🔴  LIVE — share this URL:

      https://screenshare.<you>.workers.dev/r/k7m2p9qx...

  room: k7m2p9qx...   ·   press Ctrl-C to stop
────────────────────────────────────────────────────────────
```

Anyone who opens that URL gets the live stream via WHEP in their browser.

### Options

```
--display <n>     Display index (0 = main). Default 0.
--fps <n>         Capture frame rate. Default 60.
--bitrate <v>     Target bitrate: 8M, 12000k, 6000000. Default 8M.
--codec <c>       h264 (default, best interop) or h265 (better compression).
--shows-cursor    Include the cursor.
--worker <url>    Worker base URL (or $SCREENSHARE_WORKER).
--token <secret>  Shared secret (or $SCREENSHARE_TOKEN).
```

## Releases

Tagging a commit builds and publishes a macOS (Apple Silicon) binary via
[`.github/workflows/release.yml`](.github/workflows/release.yml):

```bash
git tag v0.1.0 && git push origin v0.1.0
```

The workflow runs the WebRTC header patch, builds the release binary, bundles it
with `WebRTC.framework` (required — the binary loads it via `@loader_path`),
ad-hoc signs, and attaches a `.tar.gz` + SHA-256 to the GitHub Release. A manual
`workflow_dispatch` run produces the same artifact without cutting a release.

> The build is **un-notarized**, so consumers must clear quarantine after
> downloading: `xattr -dr com.apple.quarantine <extracted-folder>`.

## Notes & trade-offs

- **Codec:** H.264 is the safe default — universally hardware-encoded *and* the
  most broadly playable over WHEP in browsers. H.265 compresses better and is
  also hardware-encoded on Apple Silicon, but browser WHEP playback is less
  consistent. **AV1 is intentionally not offered for encode**: no current Apple
  Silicon has a hardware AV1 *encoder*, so it would violate the performance goal.
- **Audio:** intentionally omitted (video-only build). Adding it later means an
  `SCStreamConfiguration.capturesAudio` tap → an Opus track on the same
  PeerConnection.
- **Scale:** tuned for a small audience. Cloudflare Stream's edge fans out WHEP
  far beyond that if you ever need it.
- **Security:** rooms are unguessable 20-char slugs and self-expire after 6h.
  The CLI authenticates to the Worker with a bearer secret; the Cloudflare token
  stays server-side.

## Status

- **CLI: compiles cleanly** (`make build`, Swift 6.2 / macOS SDK) into a 1.7 MB
  release binary. Argument parsing, subcommands, bitrate parsing and env-var
  resolution are verified by running the binary. One upstream deprecation warning
  remains (`setCodecPreferences`), on a working API.
- **Worker: typechecks cleanly** (`tsc --noEmit`).
- **Not yet exercised end-to-end here:** the live capture → WHIP → WHEP path needs
  Screen Recording permission, a deployed Worker, and a Cloudflare Stream account —
  none of which exist in the build sandbox. The integration points are wired to
  the current ScreenCaptureKit / libwebrtc / Cloudflare Stream APIs; first real run
  is where you'd confirm negotiation and tune encoder params.

### Known dependency issue

`stasel/WebRTC` v149's macOS XCFramework slice is missing its per-class headers
(packaging bug upstream). [`scripts/patch-webrtc-headers.sh`](scripts/patch-webrtc-headers.sh)
works around it locally. If upstream fixes the slice, the patch becomes a no-op
(it's idempotent and detects already-complete headers).
