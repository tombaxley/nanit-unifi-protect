# Nanit to UniFi Protect Bridge

Bridge Nanit baby cameras into Ubiquiti's UniFi Protect ecosystem via ONVIF, enabling live viewing on Protect apps, dashboards, and ViewPorts.

## Architecture

The `indiefan/nanit` container connects to the Nanit cloud and receives RTMP streams for **all cameras on your account**. It runs on a single "primary" container. Additional cameras each get their own container running only go2rtc and onvif-server, pulling RTMP from the primary over the network.

```
                            Nanit Cloud
                                |
                                | WebSocket (camera control)
                                v
PRIMARY CONTAINER          +------------------+
                           | indiefan/nanit   | Receives RTMP for ALL cameras
                           | (RTMP :1935)     |
                           +------------------+
                            /             \
          RTMP (localhost) /               \ RTMP (over network)
                         v                 v
                   +-----------+     +-----------+
                   | go2rtc    |     | go2rtc    |   SECONDARY CONTAINER(S)
                   | (:8554)   |     | (:8554)   |
                   +-----------+     +-----------+
                         |                 |
                         v                 v
                   +-----------+     +-----------+
                   | onvif-    |     | onvif-    |
                   | server    |     | server    |
                   | (:8081)   |     | (:8081)   |
                   +-----------+     +-----------+
                         \                /
                   ONVIF  \              / ONVIF
                           v            v
                      +------------------+
                      | UniFi Protect    |
                      | (UNVR)           |
                      +------------------+
                              |
                              v
                  ViewPort / Mobile / Web UI
```

### Why This Architecture?

- **One nanit instance only.** The Nanit cloud limits concurrent "app" connections per camera. Running multiple nanit containers causes `"Too many app connections"` errors that break streams. A single nanit instance stays within limits.
- **One ONVIF container per camera.** UniFi Protect has issues when multiple ONVIF cameras are served from the same host — it tends to conflate them. Each camera gets its own LXC container with its own IPs and ONVIF instance.

## Prerequisites

- **Proxmox VE** with LXC support
- **Debian 13 (Trixie)** LXC container template
- Container settings: **unprivileged**, **nesting=1** (required for Docker)
- **UniFi Protect 5.0.33+** (ONVIF third-party camera support)
- **Nanit account** with camera(s) set up in the Nanit app

## Quick Start

### 1. Create a Proxmox LXC Container

Create a Debian 13 container with these specs (adjust as needed):

| Setting | Value |
|---|---|
| OS | Debian 13 (Trixie) |
| Cores | 1 |
| RAM | 1024 MB |
| Disk | 16 GB |
| Network | Static IP on vmbr0 (see below) |
| Unprivileged | Yes |
| Nesting | Yes (features: nesting=1) |
| Start on boot | Yes |

### 2. Run the Setup Script

SSH into the container and run:

```bash
apt-get update && apt-get install -y git
git clone https://github.com/tombaxley/nanit-unifi-protect.git /tmp/nanit-setup
chmod +x /tmp/nanit-setup/setup.sh
/tmp/nanit-setup/setup.sh
```

The script will prompt for all configuration values and set up everything automatically. It will ask whether this is the **primary** container (runs nanit + go2rtc + ONVIF) or a **secondary** container (runs go2rtc + ONVIF only, pulls RTMP from the primary over the network).

- Your **first container** should be set up as **primary**.
- All **additional camera containers** should be set up as **secondary**, pointing to the primary container's IP for their RTMP source.

### 3. Provide Nanit Session Data (Primary Only)

The `indiefan/nanit` container needs a `session.json` file to authenticate with Nanit's cloud API. There are two ways to get this:

**Option A: Copy from an existing setup**

If you already have a working nanit container, copy its session data:

```bash
scp root@<existing-container>:/opt/nanit/data/session.json /opt/nanit/data/session.json
```

Then restart the stack:

```bash
cd /opt/nanit && docker compose restart nanit
```

**Option B: Fresh login**

If starting from scratch, the nanit container will prompt for Nanit account credentials on first run. Check the logs:

```bash
docker logs nanit
```

Follow the login flow and the session will be saved to `/opt/nanit/data/session.json` automatically.

> **Note:** The nanit container connects to **all cameras on your Nanit account**. This is expected — go2rtc on each container filters to only the specific camera's stream via the baby UID in the RTMP path.

### 4. Add Camera in UniFi Protect

1. Open UniFi Protect
2. Go to **Settings > Devices > Add Device**
3. Select **Add Third-Party Camera (ONVIF)**
4. Enter:
   - **IP Address:** The secondary/virtual IP (e.g., `192.168.1.151`)
   - **Username:** `admin` (or whatever you configured)
   - **Password:** Your ONVIF password

The camera should appear and start streaming within a few seconds.

### 5. Repeat for Each Camera

Create a new LXC container for each additional camera and run the setup script again, selecting **secondary** mode and providing the primary container's IP.

## Manual Setup

If you prefer to set things up manually instead of using the setup script, follow these steps.

### Install Docker

```bash
apt-get update
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

### Create Config Files

Copy the example files and edit them:

```bash
mkdir -p /opt/nanit/data
cp docker-compose.yml /opt/nanit/          # Primary container (with nanit)
# OR
cp docker-compose.secondary.yml /opt/nanit/docker-compose.yml  # Secondary (no nanit)

cp go2rtc.yaml.example /opt/nanit/go2rtc.yaml            # Primary (localhost RTMP)
# OR
cp go2rtc.yaml.secondary.example /opt/nanit/go2rtc.yaml   # Secondary (network RTMP)

cp onvif.yaml.example /opt/nanit/onvif.yaml
```

Edit each file replacing placeholders with your actual values. See the example files for documentation on each field.

### Set Up Secondary IP for ONVIF

UniFi Protect expects ONVIF devices on port 80. Since we run the ONVIF server on port 8081, we create a secondary IP and NAT port 80 to 8081.

Edit `/etc/network/interfaces`:

```
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address <CONTAINER_IP>/<PREFIX>
    gateway <GATEWAY_IP>

auto eth0:1
iface eth0:1 inet static
    address <ONVIF_VIRTUAL_IP>/<PREFIX>
```

> **Important:** Use static IPs, not DHCP. Multiple config files reference the container's primary IP (`NANIT_RTMP_ADDR`, ONVIF `rtsp_url`/`snapshot_url`). If the IP changes, streams will break.

Create `/etc/rc.local`:

```bash
#!/bin/sh
ip addr add <ONVIF_VIRTUAL_IP>/<PREFIX> dev eth0 2>/dev/null
iptables -t nat -A PREROUTING -d <ONVIF_VIRTUAL_IP> -p tcp --dport 80 -j REDIRECT --to-port 8081
iptables -t nat -A OUTPUT -d <ONVIF_VIRTUAL_IP> -p tcp --dport 80 -j REDIRECT --to-port 8081
exit 0
```

```bash
chmod +x /etc/rc.local
```

Apply immediately (or reboot):

```bash
/etc/rc.local
```

### Configure UFW Firewall

```bash
apt-get install -y ufw
ufw default deny incoming
ufw default allow outgoing

# SSH from LAN
ufw allow from <LAN_SUBNET> to any port 22 proto tcp

# Nanit camera RTMP inbound (use your LAN subnet so camera IP changes don't break things)
ufw allow from <LAN_SUBNET> to any port 1935 proto tcp

# UNVR access to streams
ufw allow from <UNVR_IP> to any port 8554 proto tcp   # RTSP
ufw allow from <UNVR_IP> to any port 8081 proto tcp   # ONVIF
ufw allow from <UNVR_IP> to any port 1984 proto tcp   # go2rtc API
ufw allow from <UNVR_IP> to any port 80 proto tcp     # ONVIF port 80

# ViewPort (optional)
ufw allow from <VIEWPORT_IP> to any port 8554 proto tcp
ufw allow from <VIEWPORT_IP> to any port 1984 proto tcp

# Home Assistant (optional)
ufw allow from <HA_IP> to any port 8554 proto tcp
ufw allow from <HA_IP> to any port 1984 proto tcp

ufw enable
```

> **Tip:** Use your LAN subnet (e.g., `192.168.1.0/24`) instead of individual camera IPs for the RTMP rule. Nanit cameras get their IPs via DHCP, and if the IP changes, a per-IP rule will silently break the stream.

### Start the Stack

```bash
cd /opt/nanit
docker compose up -d
```

## Finding Your Nanit Camera Details

The `session.json` file (in `/opt/nanit/data/`) contains your camera information:

```json
{
  "babies": [
    {
      "uid": "a1b2c3d4",
      "name": "Baby Name",
      "camera_uid": "N301XMN12345AB"
    }
  ]
}
```

- **baby UID** (`uid`): Used in the RTMP path — `rtmp://127.0.0.1:1935/local/<baby_uid>`
- **camera UID** (`camera_uid`): Use as the ONVIF `SerialNumber` for unique identification

## Key Configuration Details

### Primary vs. Secondary Containers

| | Primary Container | Secondary Container(s) |
|---|---|---|
| **nanit** | Yes — connects to cloud, receives RTMP for all cameras | No — does not run nanit |
| **go2rtc source** | `rtmp://127.0.0.1:1935/local/<baby_uid>` | `rtmp://<primary_ip>:1935/local/<baby_uid>` |
| **go2rtc** | Yes | Yes |
| **onvif-server** | Yes | Yes |
| **session.json** | Required | Not needed |

Only the primary container runs `indiefan/nanit`. Secondary containers point their go2rtc at the primary's RTMP server over the network. This avoids Nanit cloud connection limits.

### ONVIF SerialNumber (Critical)

Each ONVIF server instance **must** have a unique `SerialNumber` in its config. UniFi Protect uses this to identify cameras. If two instances share the same serial number, Protect will treat them as duplicates of the same camera.

The `SerialNumber` and `HardwareID` fields are **undocumented** in danimal4326/onvif-server but are fully supported:

```yaml
server:
  SerialNumber: UNIQUE_VALUE_HERE
  HardwareID: UNIQUE_VALUE_HERE
```

Without these, both default to `0.0.0` and `1.0.0` respectively, causing Protect to see all instances as the same camera. Using each camera's Nanit camera UID as the serial number is recommended.

### Network Architecture

Each camera container uses two static IPs:

| IP | Purpose |
|---|---|
| Primary (static) | Container's main IP — runs go2rtc, ONVIF server (and nanit on primary) |
| Secondary (static) | Virtual IP for ONVIF — iptables NATs port 80 to 8081 |

Both IPs **must be static**. The primary IP is referenced in `docker-compose.yml` (`NANIT_RTMP_ADDR`), `onvif.yaml` (`rtsp_url`, `snapshot_url`), and UFW rules. If it changes, streams will break. The secondary IP is what you give to UniFi Protect when adding the camera.

### Why host networking?

All Docker services use `network_mode: host` because:

1. The nanit container receives inbound RTMP connections from physical cameras on port 1935
2. go2rtc needs to reach nanit's RTMP on localhost (or over the network for secondary containers)
3. The ONVIF server needs to be reachable on the secondary IP
4. Bridge networking creates isolation that breaks inter-container communication without additional configuration

## Ports Reference

| Port | Service | Protocol | Purpose |
|---|---|---|---|
| 1935 | nanit | RTMP | Receives video from physical Nanit cameras (primary only) |
| 8554 | go2rtc | RTSP | RTSP output consumed by ONVIF server and UNVR |
| 1984 | go2rtc | HTTP | go2rtc API and web UI (stream status, snapshots) |
| 8081 | onvif-server | HTTP | ONVIF device service endpoint |
| 80 | iptables NAT | HTTP | Redirects to 8081 on the secondary IP |

## Home Assistant Integration

The RTSP streams from go2rtc can be added directly to Home Assistant using the **Generic Camera** integration:

1. Go to **Settings > Devices & Services > Add Integration**
2. Search for **Generic Camera**
3. Enter:
   - **Still Image URL:** `http://<container-ip>:1984/api/frame.jpeg?src=<stream-name>`
   - **Stream Source:** `rtsp://<container-ip>:8554/<stream-name>`
   - **RTSP Transport Protocol:** `TCP`
4. Leave username/password blank

Remember to add your Home Assistant's IP to UFW on each container (ports 8554 and 1984).

## Health Check (Primary Only)

The primary container includes an automated health check that monitors the RTMP stream and restarts the nanit container if it gets stuck in a connection failure loop.

### How It Works

A systemd timer runs `/opt/nanit/nanit-healthcheck.sh` every 3 minutes. The script queries the go2rtc API to check for active RTMP producers (cameras pushing streams). If no producers are active for **2 consecutive checks** (6 minutes), it automatically restarts the nanit container.

This handles the common failure mode where nanit enters a "too many app connections" retry loop that never recovers without a manual restart.

### Installation

The setup script installs the health check automatically on primary containers. To install manually:

```bash
cp nanit-healthcheck.sh /opt/nanit/nanit-healthcheck.sh
chmod +x /opt/nanit/nanit-healthcheck.sh
cp nanit-healthcheck.service /etc/systemd/system/
cp nanit-healthcheck.timer /etc/systemd/system/
apt-get install -y jq
systemctl daemon-reload
systemctl enable --now nanit-healthcheck.timer
```

### Monitoring

Check health check logs:

```bash
cat /var/log/nanit-healthcheck.log
```

Verify the timer is running:

```bash
systemctl status nanit-healthcheck.timer
```

### Configuration

Edit `/opt/nanit/nanit-healthcheck.sh` to adjust:

- `MAX_FAILURES` — consecutive failures before restart (default: 2)
- Timer interval — edit `/etc/systemd/system/nanit-healthcheck.timer` `OnUnitActiveSec` (default: 180 seconds)

## Troubleshooting

### Camera not appearing in Protect

1. Verify ONVIF is responding:
   ```bash
   curl -s http://<ONVIF_IP>:80/onvif/device_service \
     -H 'Content-Type: application/soap+xml' \
     -d '<?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl"><s:Body><tds:GetDeviceInformation/></s:Body></s:Envelope>'
   ```

2. Check that the serial number is unique:
   ```bash
   # Should return your configured serial, not "0.0.0"
   curl ... | grep -oP 'SerialNumber>\K[^<]+'
   ```

3. Verify UFW allows UNVR access:
   ```bash
   ufw status numbered
   ```

### "Too many app connections" errors

This means too many clients are trying to connect to the Nanit cloud simultaneously. The fix is to run **only one nanit container** across all your LXC containers. Additional containers should pull RTMP from the primary over the network instead of running their own nanit instance. See [Primary vs. Secondary Containers](#primary-vs-secondary-containers).

Also ensure you don't have the Nanit mobile app actively streaming on multiple devices while the containers are running.

### "Unable to stream" on ViewPort

1. Reboot the ViewPort — this fixes the issue most of the time
2. Add the ViewPort's IP to UFW on each camera container (ports 8554, 1984)
3. Check your Ubiquiti network firewall rules allow the ViewPort to reach the camera container IPs

### Stream breaks after camera IP changes

Nanit cameras use DHCP. If a camera's IP changes, it may be blocked by UFW. Use your LAN subnet (e.g., `192.168.1.0/24`) for the RTMP firewall rule instead of individual camera IPs:

```bash
ufw allow from <LAN_SUBNET> to any port 1935 proto tcp
```

You can find a camera's current IP with:

```bash
tcpdump -i eth0 port 1935 -n -c 5
```

### Both cameras show the same name in Protect

Each ONVIF server must have a unique `SerialNumber` in config. See [ONVIF SerialNumber](#onvif-serialnumber-critical) above.

### Stream drops or reconnects

Check nanit container logs (primary container only):
```bash
docker logs -f nanit
```

The nanit container maintains a WebSocket connection to Nanit's cloud. If it disconnects, the camera will stop pushing RTMP. The container handles reconnection automatically.

Check go2rtc stream health:
```bash
curl -s http://127.0.0.1:1984/api/streams | python3 -m json.tool
```

Look for active `producers` (RTMP from nanit) and `consumers` (RTSP to UNVR).

## Components

| Component | Image | Purpose |
|---|---|---|
| [indiefan/nanit](https://github.com/indiefan/nanit) | `indiefan/nanit` | Connects to Nanit cloud, receives RTMP streams from cameras |
| [go2rtc](https://github.com/AlexxIT/go2rtc) | `alexxit/go2rtc:latest` | Converts RTMP to RTSP (and provides WebRTC, API, snapshots) |
| [onvif-server](https://github.com/danimal4326/onvif-server) | `danimal4326/onvif-server:latest` | Wraps RTSP streams as ONVIF-compliant devices |

## License

MIT
