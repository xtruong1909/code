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

# =====================================================
# FAUCET CONFIG
# =====================================================
FAUCET_USD="https://faucet.shelbynet.shelby.xyz/fund?asset=shelbyusd"
FAUCET_NATIVE="https://faucet.shelbynet.shelby.xyz/fund"
FAUCET_AMOUNT=1000000000

# =====================================================
# TIME GATE: KIEM TRA 12:00 UTC THU 5
# =====================================================
UTC_DAY="$(date -u +%u)"    # 1=Mon ... 4=Thu ... 7=Sun
UTC_HOUR="$(date -u +%H)"

SKIP_FAUCET=false
if (( UTC_DAY < 4 || (UTC_DAY == 4 && UTC_HOUR < 12) )); then
  echo "[$(date -u)] CHUA DEN 12:00 UTC THU 5 -> BO QUA FAUCET" >> "$LOG"
  SKIP_FAUCET=true
else
  echo "[$(date -u)] DA QUA 12:00 UTC THU 5 -> CHAY DAY DU" >> "$LOG"
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

# RESET VE 1 NEU VUOT QUA SO VI
if (( START_IDX > TOTAL_WALLET )); then
  echo "[$(date -u)] RESET STATE VE 1 (da vuot qua $TOTAL_WALLET vi)" >> "$LOG"
  START_IDX=1
  echo 1 > "$STATE"
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
# HELPER: FAUCET
# =====================================================
faucet() {
  local url="$1"
  local address="$2"

  curl -s -X POST "$url" \
    -H "Content-Type: application/json" \
    -H "Origin: https://docs.shelby.xyz" \
    -d "{\"address\":\"$address\",\"amount\":$FAUCET_AMOUNT}" >> "$LOG"
  echo "" >> "$LOG"
}

# =====================================================
# MAIN LOOP - MAP ĐÚNG VÍ VỚI PROXY
# =====================================================
wallet_idx="$START_IDX"

while (( wallet_idx <= TOTAL_WALLET )); do
  # Tính proxy_idx dựa trên wallet_idx (map 1:1, lặp lại nếu hết proxy)
  proxy_idx=$(( (wallet_idx - 1) % TOTAL_PROXY + 1 ))
  
  echo "=== WALLET $wallet_idx / $TOTAL_WALLET | PROXY $proxy_idx ===" >> "$LOG"

  # ===== BUOC 1: DOI VI =====
  wallet_line="$(sed -n "${wallet_idx}p" "$WALLETS")"
  IFS='|' read -r priv address <<< "$wallet_line"

  sed -i \
    -e "s|private_key:.*|private_key: ed25519-priv-${priv#0x}|" \
    -e "s|address:.*|address: \"${address}\"|" \
    "$CONF"
  
  echo "DOI VI: $address" >> "$LOG"

  # ===== BUOC 2: DOI PROXY =====
  set_proxy "$proxy_idx"
  echo "DOI PROXY: $proxy_idx" >> "$LOG"

  # ===== BUOC 3: FAUCET (NEU DUNG DIEU KIEN) =====
  if [[ "$SKIP_FAUCET" == false ]]; then
    echo "FAUCET SHELBYUSD LAN 1 | $address" >> "$LOG"
    faucet "$FAUCET_USD" "$address"
    sleep 10

    echo "FAUCET SHELBYUSD LAN 2 | $address" >> "$LOG"
    faucet "$FAUCET_USD" "$address"
    sleep 10

    echo "FAUCET FUND LAN 1 | $address" >> "$LOG"
    faucet "$FAUCET_NATIVE" "$address"
    sleep 10

    echo "FAUCET FUND LAN 2 | $address" >> "$LOG"
    faucet "$FAUCET_NATIVE" "$address"
    sleep 10
  else
    echo "BO QUA FAUCET CHO WALLET $wallet_idx" >> "$LOG"
  fi

  # ===== BUOC 4: DELAY NGAU NHIEN =====
  WAIT=$((RANDOM % 30 + 15))
  echo "DELAY: ${WAIT}s" >> "$LOG"
  sleep "$WAIT"

  # ===== BUOC 5: UPLOAD FILE =====
  mapfile -d '' -t files < <(find "$DATA_DIR" -maxdepth 1 -type f -print0)
  if (( ${#files[@]} == 0 )); then
    echo "HET FILE UPLOAD" >> "$LOG"
    break
  fi

  file="${files[RANDOM % ${#files[@]}]}"
  name="$(basename "$file")"

  EXP_DAYS=$((RANDOM % 356 + 365))
  EXP="${EXP_DAYS}d"

  tmp="$(mktemp)"
  START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

  echo "UPLOAD: $name (expiration: $EXP)" >> "$LOG"
  
  if shelby upload "$file" "$DEST_DIR/$name" \
    --expiration "$EXP" \
    --assume-yes | tee "$tmp"; then

    aptos="$(grep -A1 "Aptos Explorer" "$tmp" | tail -n1 | xargs || true)"
    shelby_link="$(grep -A1 "Shelby Explorer" "$tmp" | tail -n1 | xargs || true)"

    {
      echo "[$START_TIME] WALLET $wallet_idx UPLOAD THANH CONG"
      echo "Aptos: $aptos"
      echo "Shelby: $shelby_link"
      echo ""
    } >> "$LOG"

    [[ -n "$aptos" && -n "$shelby_link" ]] && rm -f "$file"
  else
    echo "[$START_TIME] WALLET $wallet_idx UPLOAD THAT BAI" >> "$LOG"
  fi

  rm -f "$tmp"

  # ===== BUOC 6: CHUYEN SANG VI TIEP THEO =====
  wallet_idx=$((wallet_idx + 1))

  # RESET VE 1 NEU VUOT QUA SO VI
  if (( wallet_idx > TOTAL_WALLET )); then
    echo "DA HOAN THANH TAT CA $TOTAL_WALLET VI, RESET VE 1" >> "$LOG"
    wallet_idx=1
  fi

  echo "$wallet_idx" > "$STATE"
  echo "HOAN THANH WALLET $((wallet_idx - 1)), CHUYEN SANG WALLET $wallet_idx" >> "$LOG"
  echo "---" >> "$LOG"
done

echo "DA XU LY XONG TAT CA $TOTAL_WALLET VI" >> "$LOG"
