#!/usr/bin/env bash
set -euo pipefail

# =====================================================
# PATH & FILE
# =====================================================
BASE_DIR="/root/shelby"
CONF="/root/.shelby/config.yaml"

WALLETS="$BASE_DIR/wallets.txt"
PROXIES="$BASE_DIR/proxy.txt"
STATE="$BASE_DIR/state.txt"
LOG="$BASE_DIR/logs.txt"

DATA_DIR="$BASE_DIR/data"
DEST_DIR="files"

IPCONF="/root/tun2socks/ip.conf"

# ===== FAUCET =====
FAUCET_URL="https://faucet.shelbynet.shelby.xyz/fund?asset=shelbyusd"
FAUCET_AMOUNT=1000000000

# =====================================================
# TIME GATE: SAU 12:00 UTC THU 5
# =====================================================
UTC_DAY="$(date -u +%u)"    # 1=Mon ... 4=Thu
UTC_HOUR="$(date -u +%H)"

if (( UTC_DAY < 4 || (UTC_DAY == 4 && UTC_HOUR < 12) )); then
  echo "[$(date -u)] CHUA DEN 12:00 UTC THU 5 -> SKIP" >> "$LOG"
  exit 0
fi

# =====================================================
# INIT
# =====================================================
mkdir -p "$BASE_DIR"
touch "$LOG"

[[ -f "$STATE" ]] || echo 1 > "$STATE"

START_IDX="$(cat "$STATE" 2>/dev/null || echo 1)"
TOTAL_WALLET="$(wc -l < "$WALLETS")"
TOTAL_PROXY="$(wc -l < "$PROXIES")"

if (( TOTAL_WALLET == 0 || TOTAL_PROXY == 0 )); then
  echo "WALLET / PROXY RONG" >> "$LOG"
  exit 1
fi

# =====================================================
# HELPER: SET PROXY
# =====================================================
set_proxy() {
  local idx="$1"
  sed -n "${idx}p" "$PROXIES" > "$IPCONF"
  systemctl restart tun2socks
  sleep 5
}

# =====================================================
# MAIN LOOP: WALLET → FAUCET → UPLOAD
# =====================================================
proxy_idx=1
wallet_idx="$START_IDX"

while (( wallet_idx <= TOTAL_WALLET )); do
  echo "=== WALLET $wallet_idx / $TOTAL_WALLET | PROXY $proxy_idx ===" >> "$LOG"

  wallet_line="$(sed -n "${wallet_idx}p" "$WALLETS")"
  IFS='|' read -r priv address <<< "$wallet_line"

  # ===== SET CONFIG =====
  sed -i \
    -e "s|private_key:.*|private_key: ed25519-priv-${priv#0x}|" \
    -e "s|address:.*|address: \"${address}\"|" \
    "$CONF"

  # ===== SET PROXY (CHO CA 2 FAUCET) =====
  set_proxy "$proxy_idx"

  # ================= FAUCET LAN 1 =================
  echo "FAUCET LAN 1 | $address" >> "$LOG"
  curl -s -X POST "$FAUCET_URL" \
    -H "Content-Type: application/json" \
    -H "Origin: https://docs.shelby.xyz" \
    -d "{\"address\":\"$address\",\"amount\":$FAUCET_AMOUNT}" >> "$LOG"
  echo "" >> "$LOG"

  sleep 10

  # ================= FAUCET LAN 2 =================
  echo "FAUCET LAN 2 | $address" >> "$LOG"
  curl -s -X POST "$FAUCET_URL" \
    -H "Content-Type: application/json" \
    -H "Origin: https://docs.shelby.xyz" \
    -d "{\"address\":\"$address\",\"amount\":$FAUCET_AMOUNT}" >> "$LOG"
  echo "" >> "$LOG"

  # ================= UPLOAD =================
  WAIT=$((RANDOM % 60 + 30))   # 30–90s
  sleep "$WAIT"

  mapfile -d '' -t files < <(find "$DATA_DIR" -maxdepth 1 -type f -print0)
  (( ${#files[@]} == 0 )) && break

  file="${files[RANDOM % ${#files[@]}]}"
  name="$(basename "$file")"

  EXP_DAYS=$((RANDOM % 356 + 365))
  EXP="${EXP_DAYS}d"

  tmp="$(mktemp)"
  START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

  if shelby upload "$file" "$DEST_DIR/$name" \
    --expiration "$EXP" \
    --assume-yes | tee "$tmp"; then

    aptos="$(grep -A1 "Aptos Explorer" "$tmp" | tail -n1 | xargs || true)"
    shelby_link="$(grep -A1 "Shelby Explorer" "$tmp" | tail -n1 | xargs || true)"

    {
      echo "[$START_TIME] WALLET $wallet_idx"
      echo "Aptos: $aptos"
      echo "Shelby: $shelby_link"
      echo ""
    } >> "$LOG"

    [[ -n "$aptos" && -n "$shelby_link" ]] && rm -f "$file"
  fi

  rm -f "$tmp"

  # ===== NEXT WALLET (DOI PROXY) =====
  wallet_idx=$((wallet_idx + 1))
  proxy_idx=$((proxy_idx + 1))
  (( proxy_idx > TOTAL_PROXY )) && proxy_idx=1

  echo "$wallet_idx" > "$STATE"
done
