#!/bin/bash
set -uo pipefail  # BỎ -e ĐỂ KHÔNG DIE KHI CÓ LỖI

# =====================================================
# PATH & FILE
# =====================================================
BASE_DIR="/root/shelby"
CONF="/root/.shelby/config.yaml"

WALLETS="$BASE_DIR/wallets.txt"
PROXIES="$BASE_DIR/proxy.txt"
STATE="$BASE_DIR/state.txt"
LOG="$BASE_DIR/logs.txt"
FAIL_LOG="$BASE_DIR/fail.txt"

DATA_DIR="$BASE_DIR/data"
DEST_DIR="files"

IPCONF="/root/tun2socks/ip.conf"

# =====================================================
# FAUCET CONFIG
# =====================================================
FAUCET_USD="https://faucet.shelbynet.shelby.xyz/fund?asset=shelbyusd"
FAUCET_NATIVE="https://faucet.shelbynet.shelby.xyz/fund"
FAUCET_AMOUNT=1000000000

# RETRY & TIMEOUT
MAX_RETRY=3
TIMEOUT=30

# =====================================================
# TIME GATE: KIEM TRA CHI CHAY VAO THU 5
# =====================================================
UTC_DAY="$(date -u +%u)"    # 1=Mon ... 4=Thu ... 7=Sun
UTC_HOUR="$(date -u +%H)"

SKIP_FAUCET=false
if (( UTC_DAY == 4 )); then
  echo "[$(date -u)] HOM NAY LA THU 5 -> CHAY FAUCET" >> "$LOG"
  SKIP_FAUCET=false
else
  SKIP_FAUCET=true
fi

# =====================================================
# INIT
# =====================================================
mkdir -p "$BASE_DIR"
touch "$LOG"
touch "$FAIL_LOG"

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
# HELPER: GET PROXY INFO
# =====================================================
get_proxy_info() {
  local idx="$1"
  local proxy_line="$(sed -n "${idx}p" "$PROXIES" 2>/dev/null)"
  
  if [[ -z "$proxy_line" ]]; then
    echo "UNKNOWN"
    return 1
  fi
  
  # Format: socks5://user:pass@ip:port hoặc ip:port:user:pass
  if [[ "$proxy_line" =~ socks5://.*@([0-9.]+):([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
  elif [[ "$proxy_line" =~ ^([0-9.]+):([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
  else
    echo "$proxy_line" | cut -d: -f1-2
  fi
}

# =====================================================
# HELPER: LOG FAILED PROXY
# =====================================================
log_failed_proxy() {
  local idx="$1"
  local reason="$2"
  local proxy_info="$(get_proxy_info "$idx")"
  local timestamp="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  
  echo "[$timestamp] PROXY #$idx | IP: $proxy_info | Lỗi: $reason" >> "$FAIL_LOG"
}

# =====================================================
# HELPER: SET PROXY VỚI ERROR HANDLING
# =====================================================
set_proxy() {
  local idx="$1"
  local retry=0
  local proxy_info="$(get_proxy_info "$idx")"
  
  while (( retry < MAX_RETRY )); do
    if sed -n "${idx}p" "$PROXIES" > "$IPCONF" 2>/dev/null; then
      if systemctl restart tun2socks 2>&1 | tee -a "$LOG"; then
        sleep 5
        
        # KIỂM TRA PROXY CÓ HOẠT ĐỘNG KHÔNG
        
        if timeout 10 curl -s -m 10 https://ifconfig.me &>/dev/null; then
          # Lấy IP hiện tại qua proxy
          current_ip="$(curl -4 ifconfig.me 2>/dev/null || echo 'N/A')"
          echo "[$(date -u)] ✓ PROXY #$idx ($proxy_info) HOẠT ĐỘNG TỐT | IP hiện tại: $current_ip" >> "$LOG"
          return 0
        else
          echo "[$(date -u)] ✗ PROXY #$idx ($proxy_info) KHÔNG KẾT NỐI ĐƯỢC, thử lại ($((retry+1))/$MAX_RETRY)" >> "$LOG"
        fi
      else
        echo "[$(date -u)] ✗ KHÔNG RESTART ĐƯỢC TUN2SOCKS cho PROXY #$idx, thử lại ($((retry+1))/$MAX_RETRY)" >> "$LOG"
      fi
    else
      echo "[$(date -u)] ✗ KHÔNG ĐỌC ĐƯỢC PROXY #$idx từ file" >> "$LOG"
      log_failed_proxy "$idx" "Không đọc được từ file proxy.txt"
      return 1
    fi
    
    retry=$((retry + 1))
    sleep 5
  done
  
  echo "[$(date -u)] ✗✗✗ PROXY #$idx ($proxy_info) THẤT BẠI SAU $MAX_RETRY LẦN THỬ ✗✗✗" >> "$LOG"
  log_failed_proxy "$idx" "Không kết nối được sau $MAX_RETRY lần thử"
  return 1
}

# =====================================================
# HELPER: FAUCET VỚI RETRY
# =====================================================
faucet() {
  local url="$1"
  local address="$2"
  local retry=0
  
  while (( retry < MAX_RETRY )); do
    echo "[$(date -u)] FAUCET THU LAN $((retry+1))/$MAX_RETRY" >> "$LOG"
    
    if timeout "$TIMEOUT" curl -s -m "$TIMEOUT" -X POST "$url" \
      -H "Content-Type: application/json" \
      -H "Origin: https://docs.shelby.xyz" \
      -d "{\"address\":\"$address\",\"amount\":$FAUCET_AMOUNT}" >> "$LOG" 2>&1; then
      echo "" >> "$LOG"
      echo "[$(date -u)] FAUCET THANH CONG" >> "$LOG"
      return 0
    else
      echo "[$(date -u)] FAUCET THAT BAI, THU LAI..." >> "$LOG"
      retry=$((retry + 1))
      sleep 5
    fi
  done
  
  echo "[$(date -u)] FAUCET THAT BAI SAU $MAX_RETRY LAN THU, BO QUA" >> "$LOG"
  return 1
}

# =====================================================
# MAIN LOOP - MAP ĐÚNG VÍ VỚI PROXY
# =====================================================
wallet_idx="$START_IDX"

while true; do
  # Kiểm tra còn file không
  mapfile -d '' -t files < <(find "$DATA_DIR" -maxdepth 1 -type f -print0 2>/dev/null)
  if (( ${#files[@]} == 0 )); then
    echo "[$(date -u)] HET FILE UPLOAD, KET THUC" >> "$LOG"
    break
  fi
  
  # Reset về 1 nếu vượt quá số ví
  if (( wallet_idx > TOTAL_WALLET )); then
    echo "[$(date -u)] DA HOAN THANH TAT CA $TOTAL_WALLET VI, RESET VE 1" >> "$LOG"
    wallet_idx=1
    echo 1 > "$STATE"
  fi
  
  # Tính proxy_idx dựa trên wallet_idx (map 1:1, lặp lại nếu hết proxy)
  proxy_idx=$(( (wallet_idx - 1) % TOTAL_PROXY + 1 ))
  
  echo "=== [$(date -u)] WALLET $wallet_idx / $TOTAL_WALLET | PROXY $proxy_idx ===" >> "$LOG"

  # ===== BƯỚC 1: ĐỔI VÍ =====
  wallet_line="$(sed -n "${wallet_idx}p" "$WALLETS" 2>/dev/null)"
  if [[ -z "$wallet_line" ]]; then
    echo "[$(date -u)] KHONG DOC DUOC WALLET $wallet_idx, CHUYEN SANG VI TIEP THEO" >> "$LOG"
    wallet_idx=$((wallet_idx + 1))
    echo "$wallet_idx" > "$STATE"
    continue
  fi
  
  IFS='|' read -r priv address <<< "$wallet_line"

  if ! sed -i \
    -e "s|private_key:.*|private_key: ed25519-priv-${priv#0x}|" \
    -e "s|address:.*|address: \"${address}\"|" \
    "$CONF" 2>&1 | tee -a "$LOG"; then
    echo "[$(date -u)] KHONG CAP NHAT DUOC CONFIG CHO WALLET $wallet_idx" >> "$LOG"
    wallet_idx=$((wallet_idx + 1))
    echo "$wallet_idx" > "$STATE"
    continue
  fi
  
  echo "[$(date -u)] DOI VI: $address" >> "$LOG"

  # ===== BƯỚC 2: ĐỔI PROXY =====
  if ! set_proxy "$proxy_idx"; then
    echo "[$(date -u)] PROXY $proxy_idx LOI, BO QUA WALLET $wallet_idx" >> "$LOG"
    wallet_idx=$((wallet_idx + 1))
    echo "$wallet_idx" > "$STATE"
    continue
  fi

  # ===== BƯỚC 3: FAUCET (NẾU ĐÚNG ĐIỀU KIỆN) =====
  if [[ "$SKIP_FAUCET" == false ]]; then
    echo "[$(date -u)] FAUCET SHELBYUSD LAN 1 | $address" >> "$LOG"
    faucet "$FAUCET_USD" "$address" || echo "[$(date -u)] BO QUA FAUCET USD LAN 1" >> "$LOG"
    sleep 10

    echo "[$(date -u)] FAUCET SHELBYUSD LAN 2 | $address" >> "$LOG"
    faucet "$FAUCET_USD" "$address" || echo "[$(date -u)] BO QUA FAUCET USD LAN 2" >> "$LOG"
    sleep 10

    echo "[$(date -u)] FAUCET FUND LAN 1 | $address" >> "$LOG"
    faucet "$FAUCET_NATIVE" "$address" || echo "[$(date -u)] BO QUA FAUCET NATIVE LAN 1" >> "$LOG"
    sleep 10

    echo "[$(date -u)] FAUCET FUND LAN 2 | $address" >> "$LOG"
    faucet "$FAUCET_NATIVE" "$address" || echo "[$(date -u)] BO QUA FAUCET NATIVE LAN 2" >> "$LOG"
    sleep 10
  fi

  # ===== BƯỚC 4: DELAY NGẪU NHIÊN =====
  WAIT=$((RANDOM % 30 + 10))
  sleep "$WAIT"

  # ===== BƯỚC 5: UPLOAD FILE =====
  mapfile -d '' -t files < <(find "$DATA_DIR" -maxdepth 1 -type f -print0 2>/dev/null)
  if (( ${#files[@]} == 0 )); then
    echo "[$(date -u)] HET FILE UPLOAD" >> "$LOG"
    break
  fi

  file="${files[RANDOM % ${#files[@]}]}"
  name="$(basename "$file")"

  EXP_DAYS=$((RANDOM % 356 + 365))
  EXP="${EXP_DAYS}d"

  tmp="$(mktemp)"
  START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

  echo "[$(date -u)] UPLOAD: $name (expiration: $EXP)" >> "$LOG"
  
  if timeout 300 shelby upload "$file" "$DEST_DIR/$name" \
    --expiration "$EXP" \
    --assume-yes 2>&1 | tee "$tmp"; then

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

  # ===== BƯỚC 6: CHUYỂN SANG VÍ TIẾP THEO =====
  wallet_idx=$((wallet_idx + 1))
  echo "$wallet_idx" > "$STATE"

done

echo "[$(date -u)] DA XU LY XONG TAT CA $TOTAL_WALLET VI" >> "$LOG"
