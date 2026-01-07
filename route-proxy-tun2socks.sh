# ĐỊNH TUYẾN PROXY - VPS

# 1. Tạo file cấu hình proxy
mkdir -p /root/tun2socks && echo "123.456.78.90:6789:abcdef:ghijkl" > /root/tun2socks/ip.conf

##########################

cd /root/tun2socks
wget -O /root/tun2socks/tun2socks-linux-amd64.zip https://github.com/xjasonlyu/tun2socks/releases/download/v2.5.2/tun2socks-linux-amd64.zip
sudo apt install unzip dnsutils -y
unzip tun2socks-linux-amd64.zip
mv tun2socks-linux-amd64 /usr/local/bin/tun2socks
chmod +x /usr/local/bin/tun2socks

################

# Tạo script quản lý network
cat << 'EOF' > /root/tun2socks/run.sh
#!/bin/bash

# Đọc và parse file ip.conf
parse_proxy_config() {
    if [ -f /root/tun2socks/ip.conf ]; then
        local config=$(cat /root/tun2socks/ip.conf | head -n1)
        export PROXY_HOST=$(echo "$config" | cut -d: -f1)
        export PROXY_PORT=$(echo "$config" | cut -d: -f2)
        export PROXY_USER=$(echo "$config" | cut -d: -f3)
        export PROXY_PASS=$(echo "$config" | cut -d: -f4)
    else
        echo "Error: /root/tun2socks/ip.conf not found!"
        exit 1
    fi
}

case "$1" in
    start)
        echo "Setting up tun2socks network..."
        
        # Parse proxy config
        parse_proxy_config
        echo "Proxy: $PROXY_HOST:$PROXY_PORT (User: $PROXY_USER)"
        
        # Tạo TUN interface mới
        ip tuntap add mode tun dev tun1 2>/dev/null || true
        ip addr add 10.0.5.1/24 dev tun1 2>/dev/null || true
        ip link set dev tun1 up
        
        # Tìm default gateway và interface thực (bỏ qua tun, docker)
        ORIGINAL_GW=$(ip route show default | grep -vE 'tun|docker|br-' | awk '{print $3}' | head -n1)
        ORIGINAL_IFACE=$(ip route show default | grep -vE 'tun|docker|br-' | awk '{print $5}' | head -n1)
        
        echo "Original Gateway: $ORIGINAL_GW"
        echo "Original Interface: $ORIGINAL_IFACE"
        
        echo "$ORIGINAL_GW" > /tmp/tun2socks_gw
        echo "$ORIGINAL_IFACE" > /tmp/tun2socks_iface
        
        # Route trực tiếp tới proxy
        PROXY_IP="$PROXY_HOST"
        if [ -n "$PROXY_IP" ]; then
            echo "Adding direct route to proxy $PROXY_IP via $ORIGINAL_GW dev $ORIGINAL_IFACE"
            ip route add "$PROXY_IP" via "$ORIGINAL_GW" dev "$ORIGINAL_IFACE" 2>/dev/null || true
        fi
        
        sleep 2
        
        # Xóa default cũ, thêm default mới qua tun1
        ip route del default 2>/dev/null || true
        ip route add default via 10.0.5.1 dev tun1 metric 200
        
        # === Auto-fix DNS ===
        echo "Backing up and setting new DNS..."
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        rm -f /etc/resolv.conf
        echo -e "nameserver 1.1.1.1\nnameserver 1.0.0.1\nnameserver 8.8.8.8\nnameserver 8.8.4.4\noptions use-vc" > /etc/resolv.conf
        
        echo "tun2socks network setup completed!"
        ;;
        
    stop)
        echo "Stopping tun2socks network..."
        
        # Parse proxy config để xóa route
        parse_proxy_config
        
        # Xóa default routes qua tun1
        while ip route del default via 10.0.5.1 dev tun1 2>/dev/null; do
            echo "Removed default route via tun1"
        done
        
        # Đọc gateway và interface gốc
        if [ -f /tmp/tun2socks_gw ] && [ -f /tmp/tun2socks_iface ]; then
            ORIGINAL_GW=$(cat /tmp/tun2socks_gw)
            ORIGINAL_IFACE=$(cat /tmp/tun2socks_iface)
        else
            ORIGINAL_GW=$(ip route show | grep -vE 'tun|docker|br-' | awk '/default/ {print $3; exit}')
            ORIGINAL_IFACE=$(ip route show | grep -vE 'tun|docker|br-' | awk '/default/ {print $5; exit}')
        fi
        
        echo "Restoring Gateway: $ORIGINAL_GW via $ORIGINAL_IFACE"
        ip route add default via "$ORIGINAL_GW" dev "$ORIGINAL_IFACE" 2>/dev/null || true
        
        # Xóa route đến proxy
        PROXY_IP="$PROXY_HOST"
        ip route del "$PROXY_IP" 2>/dev/null || true
        
        # Xóa interface
        ip link set dev tun1 down 2>/dev/null || true
        ip tuntap del mode tun dev tun1 2>/dev/null || true
        
        echo "tun2socks network stopped!"
        ;;
esac
EOF
chmod +x /root/tun2socks/run.sh

# Tạo script khởi động tun2socks
cat << 'EOF' > /root/tun2socks/start-tun2socks.sh
#!/bin/bash

# Đọc config từ file ip.conf
CONFIG=$(cat /root/tun2socks/ip.conf | head -n1)

# Parse config theo format IP:PORT:USER:PASS
export PROXY_HOST=$(echo "$CONFIG" | cut -d: -f1)
export PROXY_PORT=$(echo "$CONFIG" | cut -d: -f2)
export PROXY_USER=$(echo "$CONFIG" | cut -d: -f3)
export PROXY_PASS=$(echo "$CONFIG" | cut -d: -f4)

echo "============================================"
echo "Starting tun2socks"
echo "Proxy Server: $PROXY_HOST:$PROXY_PORT"
echo "Username: $PROXY_USER"
echo "============================================"

# Kiểm tra các biến có giá trị không
if [ -z "$PROXY_HOST" ] || [ -z "$PROXY_PORT" ] || [ -z "$PROXY_USER" ] || [ -z "$PROXY_PASS" ]; then
    echo "ERROR: Missing proxy configuration!"
    echo "Please check /root/tun2socks/ip.conf"
    exit 1
fi

# Chạy tun2socks
exec /usr/local/bin/tun2socks \
    -device tun1 \
    -proxy "socks5://${PROXY_USER}:${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}" \
    -loglevel info
EOF
chmod +x /root/tun2socks/start-tun2socks.sh

# Tạo systemd service file
cat << 'EOF' > /etc/systemd/system/tun2socks.service
[Unit]
Description=tun2socks SOCKS5 Proxy Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStartPre=/root/tun2socks/run.sh start
ExecStart=/root/tun2socks/start-tun2socks.sh
ExecStop=/root/tun2socks/run.sh stop
Restart=always
RestartSec=10
KillMode=mixed
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

