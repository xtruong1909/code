#!/bin/bash
set -e

# Cài đặt dependencies
apt update -y
apt install -y python3-pip python3-venv protobuf-compiler git golang curl
pip install --upgrade pip setuptools wheel
pip install grpcio grpcio-tools
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu

# Clone hivemind
cd
if [ ! -d "hivemind" ]; then
    git clone https://github.com/hiepntnaa/hivemind/
fi
cd hivemind
HIVEMIND_BUILDGO=1 pip install -e .
python3 -m grpc_tools.protoc -I hivemind/proto \
    --python_out=hivemind/proto \
    --grpc_python_out=hivemind/proto \
    hivemind/proto/*.proto
sed -i 's/^import \(.*_pb2\)/from hivemind.proto import \1/' hivemind/proto/*_pb2.py

# Lấy public IP
IP=$(curl -4 -s ifconfig.me)

# Tạo thư mục cho các DHT nodes
mkdir -p /root/hivemind/nodes

# Tạo script chạy tất cả 20 DHT nodes
cat > /root/hivemind/run_all_dhts.py << 'EOFPYTHON'
from hivemind import DHT
import logging
import time
import threading
import os

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')

# Lấy IP từ biến môi trường
PUBLIC_IP = os.environ.get('PUBLIC_IP', '0.0.0.0')
START_PORT = 65001
NUM_NODES = 10

dhts = []

def start_dht_node(port):
    """Khởi động một DHT node trên port cụ thể"""
    node_dir = f'/root/hivemind/nodes/node_{port}'
    os.makedirs(node_dir, exist_ok=True)
    
    host_maddrs = [f'/ip4/0.0.0.0/tcp/{port}']
    announce_maddrs = [f'/ip4/{PUBLIC_IP}/tcp/{port}']
    identity_path = f'{node_dir}/identity.pem'
    
    logging.info(f"Starting DHT node on port {port}...")
    logging.info(f"  Host: {host_maddrs}")
    logging.info(f"  Announce: {announce_maddrs}")
    
    try:
        dht = DHT(
            start=True,
            host_maddrs=host_maddrs,
            announce_maddrs=announce_maddrs,
            identity_path=identity_path,
            parallel_rpc=8,
        )
        
        logging.info(f"DHT node on port {port} is running!")
        logging.info(f"  Peer ID: {dht.peer_id}")
        logging.info(f"  Visible addresses: {dht.get_visible_maddrs()}")
        
        return dht
    except Exception as e:
        logging.error(f"Failed to start DHT on port {port}: {e}")
        return None

# Khởi động tất cả DHT nodes
logging.info(f"Starting {NUM_NODES} DHT nodes from port {START_PORT} to {START_PORT + NUM_NODES - 1}...")

for i in range(NUM_NODES):
    port = START_PORT + i
    dht = start_dht_node(port)
    if dht:
        dhts.append(dht)
    time.sleep(0.5)  # Delay nhỏ giữa các lần khởi động

logging.info(f"Successfully started {len(dhts)}/{NUM_NODES} DHT nodes")

# Tạo file list.txt với các địa chỉ đầy đủ (bao gồm Peer ID)
list_file = '/root/hivemind/nodes/list.txt'
with open(list_file, 'w') as f:
    for i, dht in enumerate(dhts):
        port = START_PORT + i
        peer_id = str(dht.peer_id)
        full_address = f'/ip4/{PUBLIC_IP}/tcp/{port}/p2p/{peer_id}'
        f.write(f'{full_address}\n')
        logging.info(f"Node {i}: {full_address}")

logging.info(f"Node addresses with Peer IDs saved to: {list_file}")

# Giữ chương trình chạy
logging.info("All nodes are running. Press Ctrl+C to stop.")
try:
    while True:
        time.sleep(3600)
except KeyboardInterrupt:
    logging.info("Shutting down all DHT nodes...")
EOFPYTHON

# Tạo systemd service duy nhất
echo "=== Creating systemd service..."
cat > /etc/systemd/system/hivemind.service << EOF
[Unit]
Description=Hivemind Multiple DHT Nodes Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/hivemind
Environment="PUBLIC_IP=${IP}"
Environment="PYTHONPATH=/root/hivemind"
ExecStart=/usr/bin/python3 /root/hivemind/run_all_dhts.py
Restart=always
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "=== Reloading and starting service..."
systemctl daemon-reload
systemctl enable hivemind
systemctl restart hivemind

echo ""
echo "=== Waiting for nodes to start..."
sleep 5
echo "Node addresses saved to: /root/hivemind/nodes/list.txt"
echo ""
if [ -f /root/hivemind/nodes/list.txt ]; then
    cat /root/hivemind/nodes/list.txt
fi
echo ""
echo "View logs:"
echo "  journalctl -u hivemind -f"
