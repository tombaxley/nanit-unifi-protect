# Nanit to UniFi Protect Bridge

Bridge Nanit baby cameras into Ubiquiti's UniFi Protect ecosystem via ONVIF, enabling live viewing on Protect apps, dashboards, and ViewPorts.

## Architecture

```
Nanit Cloud
    |
    | WebSocket (camera control)
    v
+-----------------------+
| indiefan/nanit        | Connects to Nanit API, requests cameras
| (RTMP server :1935)   | stream RTMP to this container
+-----------------------+
    |
    | RTMP (rtmp://127.0.0.1:1935/local/<baby_uid>)
    v
+-----------------------+
| alexxit/go2rtc        | Converts RTMP to RTSP on-demand
| (RTSP :8554, API:1984)|
+-----------------------+
    |
    | RTSP (rtsp://<container-ip>:8554/<stream-name>)
    v
+-----------------------+
| danimal4326/          | Wraps RTSP as an ONVIF device with
| onvif-server (:8081)  | WS-Security auth
+-----------------------+
    |
    | ONVIF (http://<virtual-ip>:80 → NAT → :8081)
    v
+-----------------------+
| UniFi Protect (UNVR)  | Discovers and streams from ONVIF device
+-----------------------+
    |
    v
ViewPort / Mobile App / Web UI
```

## Why One Container Per Camera?

UniFi Protect has issues when multiple ONVIF cameras are served from the same host. While you might expect to run all cameras in a single container, Protect tends to conflate them. The reliable approach is **one dedicated LXC container per Nanit camera**, each with its own IP addresses and ONVIF instance.

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

The script will prompt for all configuration values and set up everything automatically.

### 3. Provide Nanit Session Data

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

> **Note:** The nanit container connects to **all cameras on your Nanit account** regardless of which container it runs on. This is expected behavior. The go2rtc config filters to only the specific camera's RTMP stream.

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

Create a new LXC container for each additional camera and run the setup script again with that camera's details.

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
cp docker-compose.yml /opt/nanit/
cp go2rtc.yaml.example /opt/nanit/go2rtc.yaml
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

# Nanit camera RTMP inbound
ufw allow from <CAMERA_IP> to any port 1935 proto tcp

# UNVR access to streams
ufw allow from <UNVR_IP> to any port 8554 proto tcp   # RTSP
ufw allow from <UNVR_IP> to any port 8081 proto tcp   # ONVIF
ufw allow from <UNVR_IP> to any port 1984 proto tcp   # go2rtc API
ufw allow from <UNVR_IP> to any port 80 proto tcp     # ONVIF port 80

# ViewPort (optional)
ufw allow from <VIEWPORT_IP> to any port 8554 proto tcp
ufw allow from <VIEWPORT_IP> to any port 1984 proto tcp

ufw enable
```

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

### ONVIF SerialNumber (Critical)

Each ONVIF server instance **must** have a unique `SerialNumber` in its config. UniFi Protect uses this to identify cameras. If two instances share the same serial number, Protect will treat them as duplicates of the same camera.

The `SerialNumber` and `HardwareID` fields are **undocumented** in danimal4326/onvif-server but are fully supported:

```yaml
server:
  SerialNumber: UNIQUE_VALUE_HERE
  HardwareID: UNIQUE_VALUE_HERE
```

Without these, both default to `0.0.0` and `1.0.0` respectively, causing Protect to see all instances as the same camera.

### Network Architecture

Each camera container uses two static IPs:

| IP | Purpose |
|---|---|
| Primary (static) | Container's main IP — runs nanit, go2rtc, ONVIF server |
| Secondary (static) | Virtual IP for ONVIF — iptables NATs port 80 to 8081 |

Both IPs **must be static**. The primary IP is referenced in `docker-compose.yml` (`NANIT_RTMP_ADDR`), `onvif.yaml` (`rtsp_url`, `snapshot_url`), and UFW rules. If it changes, streams will break. The secondary IP is what you give to UniFi Protect when adding the camera.

### Why host networking?

All containers use `network_mode: host` because:

1. The nanit container receives inbound RTMP connections from physical cameras on port 1935
2. go2rtc needs to reach nanit's RTMP on localhost
3. The ONVIF server needs to be reachable on the secondary IP
4. Bridge networking creates isolation that breaks inter-container communication without additional configuration

### Nanit Multi-Camera Behavior

The `indiefan/nanit` image connects to **all cameras on your Nanit account**, not just one. This means each container receives RTMP streams for every camera. This is normal — go2rtc only subscribes to the specific camera's stream via the baby UID in the RTMP path.

## Ports Reference

| Port | Service | Protocol | Purpose |
|---|---|---|---|
| 1935 | nanit | RTMP | Receives video from physical Nanit cameras |
| 8554 | go2rtc | RTSP | RTSP output consumed by ONVIF server and UNVR |
| 1984 | go2rtc | HTTP | go2rtc API and web UI (stream status, snapshots) |
| 8081 | onvif-server | HTTP | ONVIF device service endpoint |
| 80 | iptables NAT | HTTP | Redirects to 8081 on the secondary IP |

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

### "Unable to stream" on ViewPort

1. Reboot the ViewPort — this fixes the issue most of the time
2. Add the ViewPort's IP to UFW on each camera container (ports 8554, 1984)
3. Check your Ubiquiti network firewall rules allow the ViewPort to reach the camera container IPs

### Stream drops or reconnects

Check nanit container logs:
```bash
docker logs -f nanit
```

The nanit container maintains a WebSocket connection to Nanit's cloud. If it disconnects, the camera will stop pushing RTMP. The container handles reconnection automatically.

Check go2rtc stream health:
```bash
curl -s http://127.0.0.1:1984/api/streams | python3 -m json.tool
```

Look for active `producers` (RTMP from nanit) and `consumers` (RTSP to UNVR).

### Finding camera IPs (for UFW rules)

If camera IPs change (DHCP), use tcpdump to find the current source:

```bash
tcpdump -i eth0 port 1935 -n -c 5
```

The source IP in the SYN packet is your camera's current IP. Update UFW accordingly.

### Both cameras show the same name in Protect

Each ONVIF server must have a unique `SerialNumber` in config. See [ONVIF SerialNumber](#onvif-serialnumber-critical) above.

## Components

| Component | Image | Purpose |
|---|---|---|
| [indiefan/nanit](https://github.com/indiefan/nanit) | `indiefan/nanit` | Connects to Nanit cloud, receives RTMP streams from cameras |
| [go2rtc](https://github.com/AlexxIT/go2rtc) | `alexxit/go2rtc:latest` | Converts RTMP to RTSP (and provides WebRTC, API, snapshots) |
| [onvif-server](https://github.com/danimal4326/onvif-server) | `danimal4326/onvif-server:latest` | Wraps RTSP streams as ONVIF-compliant devices |

## License

MIT
