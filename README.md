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

## Quick start

Either way you'll need **Node** (for `wrangler`) and a **Cloudflare account with
Stream** enabled, plus a **Stream API token** ([create one here](https://dash.cloudflare.com/profile/api-tokens)
→ Custom token → Account · Stream · Edit). The wizard handles everything else.

### Option A — prebuilt release (no Swift toolchain)

Grab the latest macOS (Apple Silicon) kit from the
[**Releases**](../../releases/latest) page — it bundles the binary,
`WebRTC.framework`, the wizard, and the Worker source.

```bash
tar -xzf screenshare-*-macos-arm64.tar.gz
cd screenshare-*-macos-arm64
xattr -dr com.apple.quarantine .     # un-notarized build — clear Gatekeeper quarantine
./scripts/setup.sh                   # interactive wizard — see below
./screenshare start
```

### Option B — build from source

Also requires a Swift 5.10+ toolchain.

```bash
make build      # build the CLI (binary at .build/release/screenshare)
make setup      # same wizard
.build/release/screenshare start
```

In both cases the wizard ([`scripts/setup.sh`](scripts/setup.sh)):

- logs you into Cloudflare (`wrangler login`) if needed,
- detects your **account id** and writes it to `wrangler.toml`,
- creates the **KV namespace** and binds it automatically,
- **generates** a 256-bit `SHARED_SECRET` (`openssl rand -hex 32`) and stores it as a Worker secret,
- prompts once for your **Stream API token** (hidden input) and stores it as a secret,
- **deploys** the Worker and captures its URL,
- writes `~/.config/screenshare/config.json` so the CLI runs with **no flags or env vars**.

It's safe to re-run (idempotent); pass `--rotate-secret` to mint a fresh secret.

> First capture triggers the macOS **Screen Recording** permission prompt
> (System Settings → Privacy & Security → Screen Recording). Grant it to the
> terminal launching the binary, then re-run.

Going live prints:

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
--worker <url>    Worker base URL (or $SCREENSHARE_WORKER / config file).
--token <secret>  Shared secret (or $SCREENSHARE_TOKEN / config file).
```

Resolution precedence for `--worker`/`--token`: **flag → environment variable →
`~/.config/screenshare/config.json`** (written by the wizard; override its path
with `$SCREENSHARE_CONFIG`).

## Advanced / manual setup

The wizard is optional — every step it automates can be done by hand.

**Build internals.** `make build` = resolve deps → patch WebRTC headers →
`swift build -c release`. The patch ([`scripts/patch-webrtc-headers.sh`](scripts/patch-webrtc-headers.sh))
works around `stasel/WebRTC` v149's broken macOS slice (missing per-class headers):
it reconstructs them from the platform-neutral iOS slice and regenerates a curated
umbrella omitting iOS-only UIKit/EAGL/audio-session headers. Re-run `make patch`
after any `swift package clean`.

**Manual Worker deploy** (instead of `make setup`):

```bash
cd worker && npm install
npx wrangler kv namespace create ROOMS        # paste the id into wrangler.toml (ROOMS binding)
# set CF_ACCOUNT_ID under [vars] in wrangler.toml
npx wrangler secret put CF_STREAM_TOKEN        # Cloudflare API token, Stream:Edit
npx wrangler secret put SHARED_SECRET          # any secret you invent
npx wrangler deploy                            # prints https://screenshare.<you>.workers.dev
```

Then either write `~/.config/screenshare/config.json`:

```json
{ "worker": "https://screenshare.<you>.workers.dev", "token": "<SHARED_SECRET>" }
```

…or skip the file and export env vars / pass flags per run:

```bash
export SCREENSHARE_WORKER="https://screenshare.<you>.workers.dev"
export SCREENSHARE_TOKEN="<SHARED_SECRET>"
```

> Cloudflare Stream must be enabled on the account (the WebRTC WHIP/WHEP beta is
> part of Stream). Live inputs use `recording: off` for lowest latency.

## Releases

Tagging a commit builds and publishes a macOS (Apple Silicon) binary via
[`.github/workflows/release.yml`](.github/workflows/release.yml):

```bash
git tag v0.1.0 && git push origin v0.1.0
```

The workflow runs the WebRTC header patch, builds the release binary, and bundles
a **self-contained kit** — the binary, `WebRTC.framework` (required — loaded via
`@loader_path`), the setup wizard, and the Worker source (with `wrangler.toml`
sanitized back to placeholders). It ad-hoc signs, then attaches a `.tar.gz` +
SHA-256 to the GitHub Release. A manual `workflow_dispatch` run produces the same
artifact without cutting a release.

Because the kit includes the wizard and Worker source, a downloader needs **no
repo clone and no Swift toolchain** — just `./scripts/setup.sh` (Option A above).

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
  release binary. Argument parsing, subcommands, bitrate parsing, and the
  flag → env → config-file resolution chain are verified by running the binary.
  One upstream deprecation warning remains (`setCodecPreferences`), on a working API.
- **Setup wizard: syntax-checked** (`bash -n`, bash-3.2 compatible). The Cloudflare
  steps need a live account, but its config output is exercised by the CLI tests.
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
