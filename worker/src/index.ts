/**
 * screen-share-ngx Worker
 *
 *   POST /api/sessions   (Bearer SHARED_SECRET)
 *       → creates a Cloudflare Stream Live Input, returns { roomId, whipUrl, viewerUrl }
 *   GET  /r/:roomId
 *       → serves the WHEP viewer page wired to that room's playback URL
 *
 * The Cloudflare account token never leaves the Worker; the CLI only receives
 * the per-session WHIP URL (which carries its own ingest secret).
 */

export interface Env {
  ROOMS: KVNamespace;
  CF_ACCOUNT_ID: string;
  CF_STREAM_TOKEN: string;
  SHARED_SECRET: string;
}

const ROOM_TTL_SECONDS = 60 * 60 * 6; // rooms self-expire after 6h

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);

    if (req.method === "POST" && url.pathname === "/api/sessions") {
      return createSession(req, env, url);
    }
    const roomMatch = url.pathname.match(/^\/r\/([A-Za-z0-9_-]{8,64})$/);
    if (req.method === "GET" && roomMatch) {
      return serveViewer(roomMatch[1], env);
    }
    if (url.pathname === "/") {
      return new Response("screen-share-ngx\n", { headers: { "content-type": "text/plain" } });
    }
    return new Response("Not found", { status: 404 });
  },
};

async function createSession(req: Request, env: Env, url: URL): Promise<Response> {
  const auth = req.headers.get("Authorization") ?? "";
  if (auth !== `Bearer ${env.SHARED_SECRET}`) {
    return json({ error: "unauthorized" }, 401);
  }

  const roomId = randomSlug(20);

  // Create a Stream Live Input with recording off (pure live, lowest latency).
  const res = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${env.CF_ACCOUNT_ID}/stream/live_inputs`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.CF_STREAM_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        meta: { name: `ngx-${roomId}` },
        recording: { mode: "off" },
      }),
    }
  );

  if (!res.ok) {
    return json({ error: "stream_api_failed", detail: await res.text() }, 502);
  }

  const body = (await res.json()) as StreamLiveInputResponse;
  const result = body.result;
  const whipUrl = result?.webRTC?.url;
  const whepUrl = result?.webRTCPlayback?.url;

  if (!whipUrl || !whepUrl) {
    return json({ error: "missing_webrtc_urls", detail: JSON.stringify(body) }, 502);
  }

  await env.ROOMS.put(
    roomId,
    JSON.stringify({ whepUrl, liveInputUid: result.uid }),
    { expirationTtl: ROOM_TTL_SECONDS }
  );

  return json({
    roomId,
    whipUrl,
    viewerUrl: `${url.origin}/r/${roomId}`,
  });
}

async function serveViewer(roomId: string, env: Env): Promise<Response> {
  const raw = await env.ROOMS.get(roomId);
  if (!raw) {
    return new Response("This stream has ended or never existed.", {
      status: 404,
      headers: { "content-type": "text/plain" },
    });
  }
  const { whepUrl } = JSON.parse(raw) as { whepUrl: string };
  return new Response(viewerHTML(whepUrl, roomId), {
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

// --- helpers ---------------------------------------------------------------

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** URL-safe, unguessable room id. */
function randomSlug(len: number): string {
  const alphabet = "abcdefghijkmnpqrstuvwxyz23456789"; // no look-alikes
  const bytes = new Uint8Array(len);
  crypto.getRandomValues(bytes);
  let out = "";
  for (const b of bytes) out += alphabet[b % alphabet.length];
  return out;
}

interface StreamLiveInputResponse {
  result?: {
    uid: string;
    webRTC?: { url: string };
    webRTCPlayback?: { url: string };
  };
}

/** Self-contained WHEP player page. Vanilla WebRTC, no dependencies. */
function viewerHTML(whepUrl: string, roomId: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta name="robots" content="noindex" />
<title>live · ${roomId}</title>
<style>
  html,body{margin:0;height:100%;background:#000;color:#eee;font:14px system-ui,sans-serif}
  #wrap{display:flex;align-items:center;justify-content:center;height:100%}
  video{max-width:100%;max-height:100%;background:#000}
  #status{position:fixed;top:12px;left:12px;padding:6px 10px;border-radius:6px;
           background:rgba(0,0,0,.6);backdrop-filter:blur(6px)}
  .dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:#888;margin-right:6px;vertical-align:middle}
  .live .dot{background:#e2342d;box-shadow:0 0 8px #e2342d}
</style>
</head>
<body>
  <div id="status"><span class="dot"></span><span id="label">connecting…</span></div>
  <div id="wrap"><video id="v" autoplay playsinline muted controls></video></div>
<script>
const WHEP_URL = ${JSON.stringify(whepUrl)};
const video = document.getElementById("v");
const status = document.getElementById("status");
const label = document.getElementById("label");

async function play() {
  const pc = new RTCPeerConnection({
    iceServers: [{ urls: "stun:stun.cloudflare.com:3478" }],
    bundlePolicy: "max-bundle",
  });
  pc.addTransceiver("video", { direction: "recvonly" });

  const stream = new MediaStream();
  pc.ontrack = (e) => { stream.addTrack(e.track); video.srcObject = stream; };
  pc.oniceconnectionstatechange = () => {
    if (pc.iceConnectionState === "connected" || pc.iceConnectionState === "completed") {
      status.classList.add("live"); label.textContent = "LIVE";
    } else if (["failed","disconnected","closed"].includes(pc.iceConnectionState)) {
      status.classList.remove("live"); label.textContent = pc.iceConnectionState;
    }
  };

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  await new Promise((res) => {
    if (pc.iceGatheringState === "complete") return res();
    pc.onicegatheringstatechange = () => pc.iceGatheringState === "complete" && res();
    setTimeout(res, 2000);
  });

  const resp = await fetch(WHEP_URL, {
    method: "POST",
    headers: { "Content-Type": "application/sdp" },
    body: pc.localDescription.sdp,
  });
  if (!resp.ok) { label.textContent = "stream offline"; return; }
  const answer = await resp.text();
  await pc.setRemoteDescription({ type: "answer", sdp: answer });
}

play().catch((e) => { label.textContent = "error"; console.error(e); });
</script>
</body>
</html>`;
}
