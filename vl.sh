#!/usr/bin/env bash
# N4 — Cloud Run (US only) VLESS WS → send URL to Telegram (5h END label)
set -euo pipefail

# ===== Required: Telegram creds =====
: "${TELEGRAM_TOKEN:?Set TELEGRAM_TOKEN}"
: "${TELEGRAM_CHAT_ID:?Set TELEGRAM_CHAT_ID}"

# ===== Fixed Cloud Run config (Qwiklabs-friendly) =====
REGION="us-central1"
SERVICE="${SERVICE:-n4gcp}"
CPU="${CPU:-2}"
MEMORY="${MEMORY:-2Gi}"
TIMEOUT="${TIMEOUT:-3600}"
CONCURRENCY="${CONCURRENCY:-100}"
MIN_INSTANCES="${MIN_INSTANCES:-1}"
MAX_INSTANCES="${MAX_INSTANCES:-8}"    # 2 vCPU * 8 = 16 vCPU (within Qwiklabs quota)
PORT="${PORT:-8080}"

# ===== Image & protocol settings (VLESS WS) =====
IMAGE="${IMAGE:-docker.io/n4pro/vl:latest}"
VLESS_UUID="${VLESS_UUID:-0c890000-4733-b20e-067f-fc341bd20000}"
  WS_PATH="${WS_PATH:-/N4}"           # leading slash required

# ===== Preflight =====
command -v gcloud >/dev/null || { echo "❌ gcloud not found"; exit 1; }
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[[ -n "$PROJECT" ]] || { echo "❌ No active project. Run: gcloud config set project <ID>"; exit 1; }

# ===== Compute END label (+5h, Asia/Yangon AM/PM) =====
if TZ=Asia/Yangon date +%Y >/dev/null 2>&1; then
  END_AMPM="$(TZ=Asia/Yangon date -d '+5 hours' '+%I:%M%p' | sed 's/^0//')"
else
  END_AMPM="$(date -u -d '+5 hours' '+%I:%M%p' | sed 's/^0//')"
fi
LABEL_PLAIN="VLESS WS(END-${END_AMPM})"
LABEL_ENC="$(python3 - <<PY
from urllib.parse import quote
print(quote("${LABEL_PLAIN}"))
PY
)"
# Encode WS path
WS_PATH_ENC="$(python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.getenv("WS_PATH","/N4"), safe=""))
PY
)"

# ===== Enable APIs =====
gcloud services enable run.googleapis.com cloudbuild.googleapis.com --quiet

# ===== Deploy to Cloud Run (Gen2) =====
gcloud run deploy "$SERVICE" \
  --image "$IMAGE" \
  --region "$REGION" \
  --platform managed \
  --allow-unauthenticated \
  --port "$PORT" \
  --cpu "$CPU" \
  --memory "$MEMORY" \
  --timeout "$TIMEOUT" \
  --execution-environment gen2 \
  --concurrency "$CONCURRENCY" \
  --min-instances "$MIN_INSTANCES" \
  --max-instances "$MAX_INSTANCES" \
  --set-env-vars "VLESS_UUID=${VLESS_UUID}" \
  --set-env-vars "WS_PATH=${WS_PATH}" \
  --quiet

# ===== Build VLESS WS URL =====
RUN_URL="$(gcloud run services describe "$SERVICE" --region "$REGION" --format='value(status.url)')"
HOST="${RUN_URL#https://}"

# Front via vpn.googleapis.com:443 with SNI=Cloud Run host
VLESS_URL="vless://${VLESS_UUID}@vpn.googleapis.com:443?path=${WS_PATH_ENC}&security=tls&encryption=none&host=${HOST}&type=ws&sni=${HOST}#${LABEL_ENC}"

# ===== Send to Telegram (URL only) =====
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${VLESS_URL}" \
  -d disable_web_page_preview=true >/dev/null

# ===== Local echo =====
echo "$VLESS_URL"
