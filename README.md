<p align="center">
  <img src="https://img.shields.io/badge/WireGuard-88171A?style=for-the-badge&logo=wireguard&logoColor=white" alt="WireGuard"/>
  <img src="https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black" alt="Linux"/>
  <img src="https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white" alt="Bash"/>
</p>

<h1 align="center">🚀 Wire-Rocket</h1>

<p align="center">
  <strong>The Fastest & Most Reliable WireGuard Tunneling Solution</strong><br>
  <em>Optimized for restrictive network environments</em>
</p>

<p align="center">
  <a href="#-quick-start">Quick Start</a> •
  <a href="#-features">Features</a> •
  <a href="#-setup-guide">Setup Guide</a> •
  <a href="#-troubleshooting">Troubleshooting</a>
</p>

---

## ⚡ Quick Start

### One-Liner Installation

```bash
bash <(curl -sL https://raw.githubusercontent.com/emad1381/Wire-Rocket/main/install.sh)
```

Or clone and run manually:

```bash
git clone https://github.com/emad1381/Wire-Rocket.git
cd Wire-Rocket
chmod +x install.sh rocket.sh
./install.sh
```

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🎨 **Beautiful Dashboard** | Color-coded interactive Bash menu |
| 🔑 **Auto Key Generation** | Automatic WireGuard keypair creation |
| 🌐 **Auto IP Detection** | Automatically detects your public IP |
| 🚀 **Kernel-Level Forwarding** | Uses iptables NAT (faster than HAProxy) |
| 🔒 **Stealth Mode** | Random high UDP port (50000-65000) |
| ⚙️ **Optimized Settings** | BBR, 1280 MTU, PersistentKeepalive |
| 🔄 **Easy Management** | Install, Status, View Config, Uninstall |

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        INTERNET                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ :443 (or custom port)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     🇮🇷 IRAN SERVER                              │
│  ┌───────────────┐    ┌──────────────┐    ┌─────────────────┐  │
│  │   eth0        │───▶│   iptables   │───▶│   wg0           │  │
│  │   Public IP   │    │   NAT/DNAT   │    │   10.0.0.2/30   │  │
│  └───────────────┘    └──────────────┘    └────────┬────────┘  │
└────────────────────────────────────────────────────│────────────┘
                                                     │
                              WireGuard Tunnel (UDP:Random Port)
                                                     │
┌────────────────────────────────────────────────────│────────────┐
│                     🌍 KHAREJ SERVER                             │
│  ┌─────────────────┐    ┌──────────────────────────▼──────────┐ │
│  │   eth0          │    │   wg0                               │ │
│  │   Public IP     │    │   10.0.0.1/30                       │ │
│  └─────────────────┘    └─────────────────────────────────────┘ │
│                                                                  │
│                    Your Services (V2Ray, SSH, etc.)             │
└──────────────────────────────────────────────────────────────────┘
```

---

## 📖 Setup Guide

### Prerequisites

- Two Linux servers (Ubuntu/Debian recommended)
- Root access on both servers
- Open UDP port access between servers

### Step 1: Setup KHAREJ (Foreign) Server

1. **Run the installer:**
   ```bash
   bash <(curl -sL https://raw.githubusercontent.com/emad1381/Wire-Rocket/main/install.sh)
   ```

2. **Select Option 1** → Install / Update Tunnel

3. **Choose Role: [1] Kharej**

4. **Enter the Iran server's public IP** when prompted

5. **IMPORTANT:** Copy the displayed:
   - ✅ Public Key
   - ✅ Preshared Key
   - ✅ WireGuard Port

   You'll need these for the Iran server!

### Step 2: Setup IRAN Server

1. **Run the installer:**
   ```bash
   bash <(curl -sL https://raw.githubusercontent.com/emad1381/Wire-Rocket/main/install.sh)
   ```

2. **Select Option 1** → Install / Update Tunnel

3. **Choose Role: [2] Iran**

4. **Enter the information from Kharej server:**
   - Kharej server's public IP
   - Kharej server's Public Key
   - Preshared Key (from Kharej)
   - WireGuard Port (from Kharej)

5. **Enter the port you want to forward** (e.g., 443)

### Step 3: Verify Connection

On both servers, run:
```bash
./rocket.sh
```
Select **Option 2** → Show Tunnel Status

You should see:
- ✅ Interface: UP
- ✅ Peer connected
- ✅ Handshake successful

---

## 🎛️ Dashboard Options

```
╔══════════════════════════════════════════════╗
║           🚀 Wire-Rocket v1.0                ║
╠══════════════════════════════════════════════╣
║  [1] Install / Update Tunnel                 ║
║  [2] Show Tunnel Status                      ║
║  [3] View Config / Keys                      ║
║  [4] Uninstall                               ║
║  [5] Exit                                    ║
╚══════════════════════════════════════════════╝
```

---

## 🔧 Technical Specifications

### Network Optimizations Applied

| Setting | Value | Purpose |
|---------|-------|---------|
| MTU | 1280 | Safe for tunneling, avoids fragmentation |
| PersistentKeepalive | 20s | Bypasses NAT timeouts |
| net.ipv4.ip_forward | 1 | Enable IP forwarding |
| net.core.default_qdisc | fq | Fair Queue for BBR |
| net.ipv4.tcp_congestion_control | bbr | Google's BBR congestion control |

### Port Forwarding (Iran Server)

The script automatically creates iptables rules:
```bash
# Forward incoming traffic to Kharej through tunnel
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 443 -j DNAT --to-destination 10.0.0.1:443
iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
```

---

## 🔍 Troubleshooting

### Connection Not Establishing

1. **Check WireGuard interface:**
   ```bash
   wg show
   ```

2. **Check if port is open:**
   ```bash
   # On Kharej server
   ss -tuln | grep <WG_PORT>
   ```

3. **Check firewall:**
   ```bash
   ufw status
   iptables -L -n
   ```

### Handshake Failing

1. **Verify keys match:**
   - Kharej's Public Key should be in Iran's config
   - Iran's Public Key should be in Kharej's config

2. **Check endpoint IPs:**
   - Make sure public IPs are correct on both sides

3. **Check time sync:**
   ```bash
   timedatectl status
   ```

### Traffic Not Forwarding

1. **Check IP forwarding:**
   ```bash
   sysctl net.ipv4.ip_forward
   # Should return: net.ipv4.ip_forward = 1
   ```

2. **Check iptables rules:**
   ```bash
   iptables -t nat -L -n -v
   ```

3. **Ping through tunnel:**
   ```bash
   # From Iran
   ping 10.0.0.1
   
   # From Kharej
   ping 10.0.0.2
   ```

### SSH Connection Lost After Setup

The script is designed to NOT affect your SSH connection. However, if you lose SSH:

1. Use your VPS provider's console access
2. Check routing table: `ip route show`
3. Remove the WireGuard interface: `wg-quick down wg0`

---

## 📁 File Locations

| File | Path |
|------|------|
| WireGuard Config | `/etc/wireguard/wg0.conf` |
| Private Key | `/etc/wireguard/privatekey` |
| Public Key | `/etc/wireguard/publickey` |
| Preshared Key | `/etc/wireguard/presharedkey` |
| Wire-Rocket Script | `/usr/local/bin/rocket.sh` |

---

## 🛡️ Security Notes

- Private keys are stored with `chmod 600`
- Configuration files are protected with `chmod 600`
- The preshared key adds an additional layer of symmetric encryption
- Random high UDP ports reduce fingerprinting

---

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

---

<p align="center">
  Made with ❤️ for unrestricted internet access
</p>
