#!/bin/bash
set -euo pipefail

# ==============================================================================
# Nanit -> UniFi Protect Bridge Setup Script
#
# Sets up a single Nanit camera on a Proxmox LXC container (Debian 13) with:
#   - go2rtc (RTMP -> RTSP conversion)
#   - danimal4326/onvif-server (RTSP -> ONVIF for UniFi Protect)
#   - UFW firewall rules
#   - Secondary IP + iptables NAT for ONVIF port 80
#
# Primary containers additionally run indiefan/nanit (RTMP from Nanit cloud).
# Secondary containers pull RTMP from the primary over the network.
#
# Run this script as root on a fresh Debian 13 LXC container with nesting=1.
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Preflight checks --------------------------------------------------------

[[ $EUID -ne 0 ]] && error "This script must be run as root."

# --- Collect configuration ----------------------------------------------------

echo ""
echo "============================================"
echo " Nanit -> UniFi Protect Bridge Setup"
echo "============================================"
echo ""

read -rp "Is this the PRIMARY container (runs nanit cloud connector)? [y/N]: " IS_PRIMARY
IS_PRIMARY=${IS_PRIMARY,,}

echo ""
read -rp "Camera name (lowercase, no spaces, e.g. 'nursery'): " CAMERA_NAME
read -rp "Nanit baby UID (from session.json, e.g. 'a1b2c3d4'): " BABY_UID
read -rp "Nanit camera UID / serial (e.g. 'N301XMN12345AB'): " CAMERA_UID
read -rp "This container's static IP (e.g. '192.168.1.10'): " CONTAINER_IP
read -rp "Secondary IP for ONVIF virtual camera (e.g. '192.168.1.151'): " ONVIF_IP
read -rp "Gateway IP (e.g. '192.168.1.1'): " GATEWAY_IP
read -rp "Subnet prefix length (e.g. '24'): " SUBNET_PREFIX
read -rp "LAN subnet (e.g. '192.168.1.0/24'): " LAN_SUBNET

if [[ "${IS_PRIMARY}" != "y" ]]; then
    read -rp "Primary container IP (where nanit runs, e.g. '192.168.1.10'): " PRIMARY_IP
    RTMP_SOURCE="rtmp://${PRIMARY_IP}:1935/local/${BABY_UID}"
else
    RTMP_SOURCE="rtmp://127.0.0.1:1935/local/${BABY_UID}"
fi

read -rp "ONVIF username [admin]: " ONVIF_USER
ONVIF_USER=${ONVIF_USER:-admin}
read -rsp "ONVIF password: " ONVIF_PASS
echo ""
read -rp "UNVR IP address (e.g. '192.168.1.2'): " UNVR_IP
read -rp "ViewPort IP (leave blank to skip): " VIEWPORT_IP
read -rp "Home Assistant IP (leave blank to skip): " HA_IP
read -rp "Container hostname [nanit-${CAMERA_NAME}]: " HOSTNAME
HOSTNAME=${HOSTNAME:-nanit-${CAMERA_NAME}}

echo ""
info "Configuration summary:"
if [[ "${IS_PRIMARY}" == "y" ]]; then
    echo "  Mode:           PRIMARY (runs nanit cloud connector)"
else
    echo "  Mode:           SECONDARY (pulls RTMP from ${PRIMARY_IP})"
fi
echo "  Camera name:    ${CAMERA_NAME}"
echo "  Baby UID:       ${BABY_UID}"
echo "  Camera UID:     ${CAMERA_UID}"
echo "  Container IP:   ${CONTAINER_IP}"
echo "  ONVIF IP:       ${ONVIF_IP}"
echo "  RTMP source:    ${RTMP_SOURCE}"
echo "  UNVR IP:        ${UNVR_IP}"
echo "  Hostname:       ${HOSTNAME}"
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && error "Aborted."

# --- Install dependencies -----------------------------------------------------

info "Installing Docker and UFW..."
apt-get update -qq
apt-get install -y -qq curl ufw ca-certificates gnupg > /dev/null 2>&1

if ! command -v docker &> /dev/null; then
    info "Installing Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null 2>&1
fi
info "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+') installed."

# --- Set hostname -------------------------------------------------------------

hostnamectl set-hostname "${HOSTNAME}" 2>/dev/null || echo "${HOSTNAME}" > /etc/hostname

# --- Create config files ------------------------------------------------------

info "Creating config files in /opt/nanit/..."
mkdir -p /opt/nanit/data

# docker-compose.yml
if [[ "${IS_PRIMARY}" == "y" ]]; then
cat > /opt/nanit/docker-compose.yml << EOF
services:
  nanit:
    image: indiefan/nanit
    container_name: nanit
    restart: unless-stopped
    network_mode: host
    volumes:
      - /opt/nanit/data:/data
    environment:
      - NANIT_RTMP_ADDR=${CONTAINER_IP}:1935
      - NANIT_LOG_LEVEL=info

  go2rtc:
    image: alexxit/go2rtc:latest
    container_name: go2rtc
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./go2rtc.yaml:/config/go2rtc.yaml:ro
    command: ["go2rtc", "-c", "/config/go2rtc.yaml"]

  onvif-${CAMERA_NAME}:
    image: danimal4326/onvif-server:latest
    container_name: onvif-${CAMERA_NAME}
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./onvif.yaml:/onvif-server/config.yaml:ro
    depends_on:
      - go2rtc
EOF
else
cat > /opt/nanit/docker-compose.yml << EOF
services:
  go2rtc:
    image: alexxit/go2rtc:latest
    container_name: go2rtc
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./go2rtc.yaml:/config/go2rtc.yaml:ro
    command: ["go2rtc", "-c", "/config/go2rtc.yaml"]

  onvif-${CAMERA_NAME}:
    image: danimal4326/onvif-server:latest
    container_name: onvif-${CAMERA_NAME}
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./onvif.yaml:/onvif-server/config.yaml:ro
    depends_on:
      - go2rtc
EOF
fi

# go2rtc.yaml
cat > /opt/nanit/go2rtc.yaml << EOF
streams:
  ${CAMERA_NAME}:
    - ${RTMP_SOURCE}

rtsp:
  listen: ":8554"

api:
  listen: ":1984"
EOF

# onvif.yaml
cat > /opt/nanit/onvif.yaml << EOF
server:
  username: ${ONVIF_USER}
  password: ${ONVIF_PASS}
  http_port: 8081
  Manufacturer: Nanit
  Model: ProCamera
  SerialNumber: ${CAMERA_UID}
  HardwareID: nanit-${CAMERA_NAME}-001
  FirmwareVersion: 1.0.0
  devices:
    - name: ${CAMERA_NAME^} Nanit
      token: ${CAMERA_NAME}
      rtsp_url: rtsp://${CONTAINER_IP}:8554/${CAMERA_NAME}
      snapshot_url: http://${CONTAINER_IP}:1984/api/frame.jpeg?src=${CAMERA_NAME}
      width: 1920
      height: 1080
      framerate: 10
      bitrate: 2048
EOF

info "Config files created."

# --- Network: secondary IP + iptables NAT ------------------------------------

info "Setting up secondary IP ${ONVIF_IP} and iptables NAT..."

cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address ${CONTAINER_IP}/${SUBNET_PREFIX}
    gateway ${GATEWAY_IP}

auto eth0:1
iface eth0:1 inet static
    address ${ONVIF_IP}/${SUBNET_PREFIX}
EOF

cat > /etc/rc.local << EOF
#!/bin/sh
# Add secondary IP for ONVIF virtual camera
ip addr add ${ONVIF_IP}/${SUBNET_PREFIX} dev eth0 2>/dev/null
# NAT port 80 on virtual IP to ONVIF server port
iptables -t nat -A PREROUTING -d ${ONVIF_IP} -p tcp --dport 80 -j REDIRECT --to-port 8081
iptables -t nat -A OUTPUT -d ${ONVIF_IP} -p tcp --dport 80 -j REDIRECT --to-port 8081
exit 0
EOF
chmod +x /etc/rc.local

# Apply immediately
ip addr add "${ONVIF_IP}/${SUBNET_PREFIX}" dev eth0 2>/dev/null || true
iptables -t nat -A PREROUTING -d "${ONVIF_IP}" -p tcp --dport 80 -j REDIRECT --to-port 8081
iptables -t nat -A OUTPUT -d "${ONVIF_IP}" -p tcp --dport 80 -j REDIRECT --to-port 8081

info "Secondary IP and NAT rules applied."

# --- Firewall -----------------------------------------------------------------

info "Configuring UFW firewall..."
ufw default deny incoming > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1

# SSH from LAN
ufw allow from "${LAN_SUBNET}" to any port 22 proto tcp comment 'SSH from LAN' > /dev/null 2>&1

# RTMP from LAN (cameras and secondary containers)
ufw allow from "${LAN_SUBNET}" to any port 1935 proto tcp comment 'LAN RTMP' > /dev/null 2>&1

# UNVR access
ufw allow from "${UNVR_IP}" to any port 8554 proto tcp comment 'UNVR RTSP' > /dev/null 2>&1
ufw allow from "${UNVR_IP}" to any port 8081 proto tcp comment 'UNVR ONVIF' > /dev/null 2>&1
ufw allow from "${UNVR_IP}" to any port 1984 proto tcp comment 'UNVR go2rtc API' > /dev/null 2>&1
ufw allow from "${UNVR_IP}" to any port 80 proto tcp comment 'UNVR ONVIF port 80' > /dev/null 2>&1

# ViewPort access (optional)
if [[ -n "${VIEWPORT_IP}" ]]; then
    ufw allow from "${VIEWPORT_IP}" to any port 8554 proto tcp comment 'ViewPort RTSP' > /dev/null 2>&1
    ufw allow from "${VIEWPORT_IP}" to any port 1984 proto tcp comment 'ViewPort go2rtc API' > /dev/null 2>&1
fi

# Home Assistant access (optional)
if [[ -n "${HA_IP}" ]]; then
    ufw allow from "${HA_IP}" to any port 8554 proto tcp comment 'Home Assistant RTSP' > /dev/null 2>&1
    ufw allow from "${HA_IP}" to any port 1984 proto tcp comment 'Home Assistant go2rtc API' > /dev/null 2>&1
fi

echo "y" | ufw enable > /dev/null 2>&1
info "Firewall configured."

# --- Nanit session data -------------------------------------------------------

if [[ "${IS_PRIMARY}" == "y" ]] && [[ ! -f /opt/nanit/data/session.json ]]; then
    warn "No session.json found in /opt/nanit/data/"
    warn "You need to copy session.json from an existing nanit container or"
    warn "run the nanit container once to generate a new session via login."
    warn "See README.md for details."
fi

# --- Pull and start -----------------------------------------------------------

info "Pulling Docker images and starting services..."
cd /opt/nanit
docker compose pull -q
docker compose up -d

echo ""
info "Waiting for services to start..."
sleep 5

# --- Verify -------------------------------------------------------------------

echo ""
info "=== Service Status ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"

echo ""
info "=== ONVIF Device Info ==="
SERIAL=$(curl -s "http://127.0.0.1:8081/onvif/device_service" \
    -H 'Content-Type: application/soap+xml' \
    -d '<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl"><s:Body><tds:GetDeviceInformation/></s:Body></s:Envelope>' \
    2>/dev/null | grep -oP 'SerialNumber>\K[^<]+' || echo "FAILED")
echo "  ONVIF Serial: ${SERIAL}"

echo ""
echo "============================================"
info "Setup complete!"
echo ""
if [[ "${IS_PRIMARY}" == "y" ]]; then
    echo "  Mode: PRIMARY (nanit cloud connector running)"
else
    echo "  Mode: SECONDARY (pulling RTMP from ${PRIMARY_IP})"
fi
echo ""
echo "  Add this camera in UniFi Protect:"
echo "    IP Address: ${ONVIF_IP}"
echo "    Username:   ${ONVIF_USER}"
echo "    Password:   (as configured)"
echo ""
echo "  RTSP stream:  rtsp://${CONTAINER_IP}:8554/${CAMERA_NAME}"
echo "  go2rtc UI:    http://${CONTAINER_IP}:1984"
echo "============================================"
