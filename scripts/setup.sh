#!/usr/bin/env bash
#
# screen-share-ngx setup wizard.
#
# Walks through everything needed to go live: Cloudflare auth, the KV namespace,
# account id, the generated shared secret, the Stream API token, deploy, and a
# local CLI config so `screenshare start` works with no flags afterwards.
#
# Safe to re-run (idempotent). Flags:
#   --rotate-secret   generate a fresh SHARED_SECRET even if one is configured
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER_DIR="${ROOT}/worker"
TOML="${WORKER_DIR}/wrangler.toml"
CONFIG_DIR="${HOME}/.config/screenshare"
CONFIG_FILE="${CONFIG_DIR}/config.json"
ROTATE=0
[[ "${1:-}" == "--rotate-secret" ]] && ROTATE=1

# --- pretty output ----------------------------------------------------------
if [[ -t 1 ]]; then B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'; RST=$'\033[0m'
else B=""; DIM=""; GRN=""; YLW=""; RED=""; CYN=""; RST=""; fi
step() { echo; echo "${B}${CYN}▸ $*${RST}"; }
ok()   { echo "  ${GRN}✓${RST} $*"; }
warn() { echo "  ${YLW}!${RST} $*"; }
die()  { echo "  ${RED}✗ $*${RST}" >&2; exit 1; }
ask()  { local p="$1" d="${2:-}" a; if [[ -n "$d" ]]; then read -rp "  ${p} ${DIM}[${d}]${RST} " a; echo "${a:-$d}"; else read -rp "  ${p} " a; echo "$a"; fi; }

# --- 0. preflight ------------------------------------------------------------
step "Checking prerequisites"
for c in node npm openssl; do command -v "$c" >/dev/null 2>&1 || die "'$c' not found. Please install it first."; done
ok "node $(node --version), npm, openssl present"
[[ -f "$TOML" ]] || die "wrangler.toml not found at $TOML"

cd "$WORKER_DIR"
if [[ ! -d node_modules ]]; then
  step "Installing Worker dependencies"
  npm install --silent && ok "dependencies installed"
fi
WR() { npx --yes wrangler "$@"; }

# --- 1. Cloudflare auth ------------------------------------------------------
step "Cloudflare account"
if ! WR whoami 2>/dev/null | grep -qiE "associated with the email|account id"; then
  warn "Not logged in — opening browser for 'wrangler login'…"
  WR login
fi
WHOAMI="$(WR whoami 2>/dev/null || true)"
ok "authenticated"

# --- 2. Account id -----------------------------------------------------------
if grep -q '<YOUR_ACCOUNT_ID>' "$TOML"; then
  step "Detecting account id"
  # Portable to macOS's stock bash 3.2 (no mapfile).
  ACCTS=()
  while IFS= read -r line; do [[ -n "$line" ]] && ACCTS+=("$line"); done \
    < <(printf '%s\n' "$WHOAMI" | grep -oE '[0-9a-f]{32}' | sort -u)
  if [[ "${#ACCTS[@]}" -eq 1 ]]; then
    ACCOUNT_ID="${ACCTS[0]}"; ok "found account ${ACCOUNT_ID}"
  else
    [[ "${#ACCTS[@]}" -gt 1 ]] && { warn "multiple accounts:"; printf '      %s\n' "${ACCTS[@]}"; }
    ACCOUNT_ID="$(ask 'Paste your Cloudflare Account ID:')"
    [[ "$ACCOUNT_ID" =~ ^[0-9a-f]{32}$ ]] || die "that doesn't look like an account id"
  fi
  sed -i '' "s/<YOUR_ACCOUNT_ID>/${ACCOUNT_ID}/" "$TOML"
  ok "wrote CF_ACCOUNT_ID to wrangler.toml"
else
  ok "account id already configured in wrangler.toml"
fi

# --- 3. KV namespace ---------------------------------------------------------
if grep -q '<YOUR_NAMESPACE_ID>' "$TOML"; then
  step "Creating KV namespace 'ROOMS'"
  CREATE_OUT="$(WR kv namespace create ROOMS 2>&1 || true)"
  KV_ID="$(printf '%s\n' "$CREATE_OUT" | grep -oE '[0-9a-f]{32}' | tail -1 || true)"
  if [[ -z "$KV_ID" ]]; then
    # Already exists, or odd output — look it up.
    KV_ID="$(WR kv namespace list 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const a=JSON.parse(s);const m=a.find(n=>/ROOMS/.test(n.title));process.stdout.write(m?m.id:"")}catch(e){}})')"
  fi
  [[ -n "$KV_ID" ]] || die "could not determine KV namespace id. Output was:\n${CREATE_OUT}"
  sed -i '' "s/<YOUR_NAMESPACE_ID>/${KV_ID}/" "$TOML"
  ok "KV namespace ${KV_ID} bound as ROOMS"
else
  ok "KV namespace already configured in wrangler.toml"
fi

# --- 4. Shared secret (generated) -------------------------------------------
step "Shared secret (CLI ↔ Worker auth)"
SHARED_SECRET=""
if [[ "$ROTATE" -eq 0 && -f "$CONFIG_FILE" ]]; then
  SHARED_SECRET="$(node -e 'try{process.stdout.write((require(process.argv[1]).token)||"")}catch(e){}' "$CONFIG_FILE" 2>/dev/null || true)"
fi
if [[ -n "$SHARED_SECRET" ]]; then
  ok "reusing existing secret from ${CONFIG_FILE/#$HOME/\~} (pass --rotate-secret to replace)"
else
  SHARED_SECRET="$(openssl rand -hex 32)"
  ok "generated a new 256-bit secret (openssl rand -hex 32)"
fi
printf '%s' "$SHARED_SECRET" | WR secret put SHARED_SECRET >/dev/null
ok "stored SHARED_SECRET as a Worker secret"

# --- 5. Stream API token -----------------------------------------------------
step "Cloudflare Stream API token"
echo "  ${DIM}Create one (Account → Stream:Edit) at:${RST}"
echo "  ${DIM}https://dash.cloudflare.com/profile/api-tokens → Create Token → Custom token${RST}"
read -rsp "  Paste the Stream API token (input hidden): " STREAM_TOKEN; echo
[[ -n "$STREAM_TOKEN" ]] || die "no token entered"
printf '%s' "$STREAM_TOKEN" | WR secret put CF_STREAM_TOKEN >/dev/null
ok "stored CF_STREAM_TOKEN as a Worker secret"

# --- 6. Deploy ---------------------------------------------------------------
step "Deploying the Worker"
DEPLOY_OUT="$(WR deploy 2>&1)"
echo "$DEPLOY_OUT" | grep -E "Uploaded|Deployed|workers.dev" | sed 's/^/  /' || true
WORKER_URL="$(printf '%s\n' "$DEPLOY_OUT" | grep -oE 'https://[A-Za-z0-9.-]+\.workers\.dev' | tail -1 || true)"
if [[ -z "$WORKER_URL" ]]; then
  warn "couldn't auto-detect the deployed URL"
  WORKER_URL="$(ask 'Enter your Worker URL (https://…workers.dev):')"
fi
ok "deployed → ${WORKER_URL}"

# --- 7. Write CLI config -----------------------------------------------------
step "Writing CLI config"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<JSON
{
  "worker": "${WORKER_URL}",
  "token": "${SHARED_SECRET}"
}
JSON
chmod 600 "$CONFIG_FILE"
ok "saved ${CONFIG_FILE/#$HOME/\~} (chmod 600)"

# --- 8. Locate (or build) the CLI binary ------------------------------------
# Release-kit layout has the prebuilt binary at the kit root; a source checkout
# has it under .build/release after `make build`.
BIN=""
for cand in "${ROOT}/screenshare" "${ROOT}/.build/release/screenshare"; do
  [[ -x "$cand" ]] && { BIN="$cand"; break; }
done
if [[ -z "$BIN" ]]; then
  if [[ -f "${ROOT}/Package.swift" ]]; then
    step "Building the CLI"
    if [[ -t 0 ]] && [[ "$(ask 'Build the screenshare binary now? (y/n)' y)" =~ ^[Yy] ]]; then
      ( cd "$ROOT" && make build )
      BIN="${ROOT}/.build/release/screenshare"
    fi
  else
    warn "screenshare binary not found next to this script."
    warn "Make sure you extracted the full release tarball (binary + WebRTC.framework)."
  fi
fi

# --- done --------------------------------------------------------------------
echo
echo "${B}${GRN}Setup complete.${RST}"
if [[ -n "$BIN" ]]; then
  echo "  Go live with:  ${B}${BIN/#$ROOT\//./}${RST} ${B}start${RST}"
  echo "  ${DIM}(no flags needed — worker URL and secret are saved in your config)${RST}"
fi
echo
