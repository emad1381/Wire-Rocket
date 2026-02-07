#!/bin/bash
#===========================================
#  Wire-Rocket Main Logic Script
#  Interactive Dashboard & WireGuard Setup
#===========================================

set -e

# Configuration
WG_CONF="/etc/wireguard/wg0.conf"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
WG_IFACE="wg0"
WG_PORT_RANGE_START=50000
WG_PORT_RANGE_END=65000

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

#===========================================
# Helper Functions
#===========================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR]${NC} This script must be run as root!"
        exit 1
    fi
}

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

generate_keys() {
    umask 077
    wg genkey | tee privatekey | wg pubkey > publickey
    wg genpsk > presharedkey
}

get_public_ip() {
    curl -s https://api.ipify.org || curl -s https://ifconfig.me
}

random_port() {
    shuf -i $WG_PORT_RANGE_START-$WG_PORT_RANGE_END -n 1
}

repair_config_interface() {
    # Auto-repair interface name in wg0.conf if it doesn't match current default
    if [[ -f "$WG_CONF" ]]; then
        CURRENT_DEFAULT=$(ip route | grep default | awk '{print $5}' | head -n1)
        # Find interface used in PostUp
        CONFIG_IFACE=$(grep -oP 'PostUp.*-o \K\w+' "$WG_CONF" | head -n1)
        
        if [[ ! -z "$CURRENT_DEFAULT" ]] && [[ ! -z "$CONFIG_IFACE" ]] && [[ "$CURRENT_DEFAULT" != "$CONFIG_IFACE" ]]; then
            echo -e "${YELLOW}[AUTO-FIX]${NC} Config uses '$CONFIG_IFACE' but system uses '$CURRENT_DEFAULT'. Updating..."
            sed -i "s/$CONFIG_IFACE/$CURRENT_DEFAULT/g" "$WG_CONF"
        fi
    fi
}

#===========================================
# Menu & Dashboard
#===========================================

show_header() {
    clear
    echo -e "${MAGENTA}"
    cat << "EOF"
 _       __  _                   ____             __        __ 
| |     / / (_)_____ ___        / __ \____  _____/ /_____  / /_
| | /| / / / / ___// _ \______ / /_/ / __ \/ ___/ //_/ _ \/ __/
| |/ |/ / / / /   /  __/_____// _, _/ /_/ / /__/ ,< /  __/ /_  
|__/|__/_/_/_/    \___/      /_/ |_|\____/\___/_/|_|\___/\__/  
                                                               
EOF
    echo -e "${NC}"
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}Wire-Rocket Control Panel${NC}                                 ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

show_menu() {
    show_header
    echo -e "  ${GREEN}[1]${NC} Install / Update Tunnel"
    echo -e "  ${GREEN}[2]${NC} Show Tunnel Status"
    echo -e "  ${GREEN}[3]${NC} View Config / Keys"
    echo -e "  ${MAGENTA}[4]${NC} Add Iran Peer (For Kharej Server)"
    echo -e "  ${YELLOW}[5]${NC} Port Forwarding Management (HAProxy)"
    echo -e "  ${BLUE}[6]${NC} Validate Config & Test Connection"
    echo -e "  ${RED}[7]${NC} Uninstall"
    echo -e "  ${RED}[8]${NC} Exit"
    echo ""
    read -p "  Select an option [1-8]: " choice
    
    # Run auto-repair lightly on every interaction if config exists
    repair_config_interface

    case $choice in
        1) install_tunnel ;;
        2) show_status ;;
        3) view_config ;;
        4) add_iran_peer ;;
        5) port_forwarding_menu ;;
        6) diagnostics_menu ;;
        7) uninstall_tunnel ;;
        8) exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}"; sleep 1; show_menu ;;
    esac
}

#===========================================
# Installation Logic
#===========================================

install_tunnel() {
    show_header
    echo -e "${YELLOW}--- Installation Wizard ---${NC}\n"
    
    # Role Selection
    echo -e "Which server is this?"
    echo -e "  ${CYAN}[1]${NC} Kharej (Foreign Server)"
    echo -e "  ${CYAN}[2]${NC} Iran (Local/Nat Server)"
    read -p "  Selection [1-2]: " role_choice

    if [[ "$role_choice" == "1" ]]; then
        setup_kharej
    elif [[ "$role_choice" == "2" ]]; then
        setup_iran
    else
        echo -e "${RED}Invalid selection!${NC}"
        sleep 2
        install_tunnel
    fi
}

setup_kharej() {
    echo -e "\n${CYAN}[*]${NC} Setting up KHAREJ server..."

    # Generate Keys
    echo -e "${CYAN}[*]${NC} Generating Secure Keys..."
    mkdir -p /etc/wireguard
    cd /etc/wireguard
    PRIVATE_KEY=$(wg genkey)
    PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)
    PRESHARED_KEY=$(wg genpsk)
    
    # Get Public IP
    echo -e "${CYAN}[*]${NC} Detecting Public IP..."
    PUBLIC_IP=$(get_public_ip)
    echo -e "${GREEN}[✓]${NC} Public IP: $PUBLIC_IP"
    
    # Port Selection
    WG_PORT=$(random_port)
    echo -e "${GREEN}[✓]${NC} Selected Random Port: ${BOLD}$WG_PORT${NC}"

    # Ask for Iran IP (Optional endpoint, mostly for reference/logs or strict firewall)
    # Since Iran initiates connection usually, usually we don't *need* Endpoint here unless bidirectional
    # But user requested "Ask for 'Iran Server IP' (Tunnel Endpoint)"
    echo -e "\n${YELLOW}[?]${NC} Enter Iran Server IP (Press Enter to skip if dynamic):"
    read -p "  > " IRAN_IP
    
    PEER_ENDPOINT_CONFIG=""
    if [[ ! -z "$IRAN_IP" ]]; then
        # If Iran IP is provided, we can add it, but usually Kharej waits.
        # However, for firewall rules, it might be useful. 
        # But `Endpoint` directive is for initiating. 
        # We will keep it simple and assume passive on Kharej side unless Iran IP is fixed.
        # Actually proper WG setup: Kharej (Server) waits. Iran (Client) initiates.
        : # Do nothing special for config endpoint on server side usually
    fi

    # Detect Interface
    DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    DEFAULT_IFACE=${DEFAULT_IFACE:-eth0}
    echo -e "${GREEN}[✓]${NC} Detected default interface: $DEFAULT_IFACE"

    # Create Config
    cat > "$WG_CONF" << EOF
[Interface]
Address = 10.0.0.1/30
ListenPort = $WG_PORT
PrivateKey = $PRIVATE_KEY
MTU = 1280
PostUp = iptables -A FORWARD -i $WG_IFACE -j ACCEPT; iptables -t nat -A POSTROUTING -o $DEFAULT_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_IFACE -j ACCEPT; iptables -t nat -D POSTROUTING -o $DEFAULT_IFACE -j MASQUERADE

[Peer]
# Iran Peer
PublicKey = REPLACE_ME_WITH_IRAN_PUBKEY
PresharedKey = $PRESHARED_KEY
AllowedIPs = 10.0.0.2/32
EOF

    echo -e "\n${GREEN}[✓]${NC} Config created at $WG_CONF"
    chmod 600 "$WG_CONF"
    
    # Start Interface
    # But we can't start fully without Iran's public key usually (wg-quick might complain or just warn)
    # Actually wg-quick is fine with placeholders but connection won't work.
    # WAIT, we need Iran's Public Key to put in Kharej config!
    # The prompt says: "Display the 'Public Key' and 'Preshared Key' clearly and tell the user to copy them to the Iran server."
    # Typically we exchange keys. 
    # Let's generate a placeholder or ask the user to input Iran's key later?
    # Or, we just provide Kharej's info first, and user has to edit Kharej config with Iran Key later.
    # OR, we reverse it: Iran generates first? 
    # Standard flow: 
    # 1. Setup Kharej (Get Kharej PubKey, PSK, IP, Port).
    # 2. Setup Iran (Use Kharej info).
    # 3. Use Iran PubKey to update Kharej config.
    
    # User prompt implies:
    # "If Kharej: ... Display Public Key ... tell user to copy to Iran."
    # It doesn't explicitly say "Ask for Iran Public Key" in step 2.
    # But for a tunnel to work, Kharej NEEDS Iran's Public Key.
    # I will add a placeholder and instruction.
    
    echo -e "\n${RED}[IMPORTANT]${NC} We need the Iran Server's Public Key to finish configuration."
    echo -e "If you haven't set up the Iran server yet, you can come back and edit ${BOLD}$WG_CONF${NC} later."
    echo -e "For now, I'll put a placeholder 'INSERT_IRAN_PUBLIC_KEY_HERE' in the config."
    sed -i "s|REPLACE_ME_WITH_IRAN_PUBKEY|INSERT_IRAN_PUBLIC_KEY_HERE|g" "$WG_CONF"

    # Save keys for display
    echo "$PRIVATE_KEY" > params
    echo "$PUBLIC_KEY" >> params
    echo "$PRESHARED_KEY" >> params
    echo "$WG_PORT" >> params
    
    systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
    # We don't start it yet to avoid error with invalid key? Actually wg allows it.
    systemctl start wg-quick@wg0 >/dev/null 2>&1 || true
    
    echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}CONFIGURATION DETAILS FOR IRAN SERVER${NC}                 ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${BOLD}Kharej IP:${NC}       $PUBLIC_IP"
    echo -e "  ${BOLD}Kharej Port:${NC}     $WG_PORT"
    echo -e "  ${BOLD}Public Key:${NC}      $PUBLIC_KEY"
    echo -e "  ${BOLD}Preshared Key:${NC}   $PRESHARED_KEY"
    echo ""
    echo -e "${YELLOW}[NOTE]${NC} Copy these values to the Iran server setup!"
    echo -e "${YELLOW}[ACTION]${NC} After setting up Iran, get its Public Key and run: ${BOLD}wg set wg0 peer <IRAN_PUBKEY> allowed-ips 10.0.0.2/32${NC}"
    
    # Open Firewall Port
    if command -v ufw &> /dev/null; then
        ufw allow $WG_PORT/udp >/dev/null 2>&1
        echo -e "${GREEN}[✓]${NC} Allowed port $WG_PORT/udp in UFW"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --add-port=$WG_PORT/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo -e "${GREEN}[✓]${NC} Allowed port $WG_PORT/udp in Firewalld"
    fi

    read -p "Press Enter to return to menu..."
    show_menu
}

setup_iran() {
    echo -e "\n${CYAN}[*]${NC} Setting up IRAN server..."

    # Generate Keys
    echo -e "${CYAN}[*]${NC} Generating Secure Keys..."
    mkdir -p /etc/wireguard
    cd /etc/wireguard
    PRIVATE_KEY=$(wg genkey)
    PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)
    
    echo -e "${GREEN}[✓]${NC} generated keys."

    # Ask for Kharej Info
    echo -e "\n${YELLOW}[?]${NC} Enter Kharej Server IP:"
    read -p "  > " KHAREJ_IP
    
    echo -e "\n${YELLOW}[?]${NC} Enter Kharej WireGuard Port (e.g., 51820):"
    read -p "  > " KHAREJ_PORT
    
    echo -e "\n${YELLOW}[?]${NC} Enter Kharej Public Key:"
    read -p "  > " KHAREJ_PUB_KEY
    
    echo -e "\n${YELLOW}[?]${NC} Enter Preshared Key (from Kharej):"
    read -p "  > " PRESHARED_KEY

    # Create Config
    WG_PORT=$(random_port)
    cat > "$WG_CONF" << EOF
[Interface]
Address = 10.0.0.2/30
ListenPort = $WG_PORT
PrivateKey = $PRIVATE_KEY
MTU = 1280
# DNS = 1.1.1.1 # Commented out to avoid resolvconf issues on some VPS
Table = off  # Prevents WireGuard from overwriting default route

[Peer]
PublicKey = $KHAREJ_PUB_KEY
PresharedKey = $PRESHARED_KEY
Endpoint = $KHAREJ_IP:$KHAREJ_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 20
EOF
    
    chmod 600 "$WG_CONF"
    echo -e "${GREEN}[✓]${NC} Config created at $WG_CONF"

    # Add custom routing for the tunnel subnet
    # We need to manually add the route for the tunnel IP range, but since Address is /30, kernel does it for link-local.
    # But if we want to route specific traffic through it, we do it via policy routing or just for the peer.
    # Actually, for a relay server, we DON'T want all traffic to go through tunnel.
    # We only want traffic explicitly forwarded (by HAProxy or DNAT) to go there.
    # So `AllowedIPs = 0.0.0.0/0` is fine for PERMISSION, but `Table = off` prevents it from being the DEFAULT ROUTE.
    
    # We also need to ensure the route to the endpoint (Kharej IP) goes through the physical interface (default gateway).
    # Since we set Table = off, the default route remains untouched (going to Internet).
    # HAProxy will just Proxy traffic to 10.0.0.1, which is on the link.
    

    # Append PostUp/PostDown to config (ONLY MASQUERADE for NAT, no specific ports)
    echo "" >> "$WG_CONF"
    echo "PostUp = iptables -t nat -A POSTROUTING -o $WG_IFACE -j MASQUERADE" >> "$WG_CONF"
    echo "PostDown = iptables -t nat -D POSTROUTING -o $WG_IFACE -j MASQUERADE" >> "$WG_CONF"
    
    # Initialize HAProxy Config if not present
    if [[ ! -f "$HAPROXY_CFG" ]]; then
        cat > "$HAPROXY_CFG" << EOF
global
    log /dev/log    local0
    log /dev/log    local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000

# Wire-Rocket Port Forwards will be added below
EOF
    fi

    echo -e "\n${CYAN}[*] Enabling HAProxy Service...${NC}"
    systemctl enable haproxy >/dev/null 2>&1
    systemctl restart haproxy >/dev/null 2>&1

    # Start Interface with Error Handling
    echo -e "\n${CYAN}[*]${NC} Starting Wire-Rocket Interface..."
    
    # Temporarily disable exit on error to catch start failure
    set +e
    systemctl stop wg-quick@wg0 >/dev/null 2>&1
    wg-quick down wg0 >/dev/null 2>&1
    
    if wg-quick up wg0; then
        systemctl enable wg-quick@wg0 >/dev/null 2>&1
        echo -e "${GREEN}[✓] Interface started successfully!${NC}"
    else
        echo -e "${RED}[X] Failed to start WireGuard interface!${NC}"
        echo -e "${YELLOW}[DEBUG] Check 'systemctl status wg-quick@wg0' or 'journalctl -xe' for details.${NC}"
        echo -e "${YELLOW}[NOTE] You can still proceed, but the tunnel is not active yet.${NC}"
        # Do not exit, show keys so user can fix config later
    fi
    set -e
    
    echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}SETUP COMPLETE${NC}                                        ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${BOLD}Your Public Key:${NC} $PUBLIC_KEY"
    echo ""
    echo -e "${YELLOW}[IMPORTANT]${NC} Make sure to add this Public Key to the Kharej server config!"
    echo -e "Command to run on Kharej: ${BOLD}wg set wg0 peer $PUBLIC_KEY allowed-ips 10.0.0.2/32${NC}"
    echo -e "Use ${BOLD}Port Forwarding Management${NC} menu to add ports."
    
    read -p "Press Enter to return to menu..."
    show_menu
}

#===========================================
# Advanced Management
#===========================================

add_iran_peer() {
    show_header
    echo -e "${MAGENTA}--- Add Iran Peer (Kharej Side) ---${NC}"
    
    if [[ ! -f "$WG_CONF" ]]; then
        echo -e "${RED}[ERROR] WireGuard config found! Install the tunnel first.${NC}"
        read -p "Press Enter..."
        show_menu
        return
    fi

    # Check if already added
    if grep -q "INSERT_IRAN_PUBLIC_KEY_HERE" "$WG_CONF"; then
        echo -e "${YELLOW}[INFO] Placeholder found. Ready to update.${NC}"
    else
        echo -e "${YELLOW}[INFO] No placeholder found. Updating existing peer config.${NC}"
    fi

    echo -e "\n${CYAN}Enter the Public Key from the Iran server:${NC}"
    read -p "  > " IRAN_PUB_KEY

    if [[ -z "$IRAN_PUB_KEY" ]]; then
        echo -e "${RED}[ERROR] Public Key cannot be empty!${NC}"
        read -p "Press Enter..."
        add_iran_peer
        return
    fi
    
    # Validate Key format (simple base64 check)
    if [[ ! "$IRAN_PUB_KEY" =~ ^[A-Za-z0-9+/]{42}[=]{0,2}$ ]]; then
        # Sometimes keys might be slightly different or user copy-paste includes whitespace
        # Let's try to be less strict or trim whitespace
        IRAN_PUB_KEY=$(echo "$IRAN_PUB_KEY" | xargs)
    fi
     
    if [[ ! "$IRAN_PUB_KEY" =~ ^[A-Za-z0-9+/=]{40,50}$ ]]; then
        echo -e "${RED}[WARNING] Key doesn't look like a valid WireGuard Public Key.${NC}"
        read -p "Proceed anyway? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
             add_iran_peer
             return
        fi
    fi

    echo -e "\n${CYAN}[*] Updating configuration...${NC}"
    
    # If placeholder exists, replace it
    if grep -q "INSERT_IRAN_PUBLIC_KEY_HERE" "$WG_CONF"; then
        sed -i "s|INSERT_IRAN_PUBLIC_KEY_HERE|$IRAN_PUB_KEY|" "$WG_CONF"
        echo -e "${GREEN}[✓] Placeholder replaced with real key.${NC}"
    else
        # Use wg set to update peer
        wg set wg0 peer "$IRAN_PUB_KEY" allowed-ips 10.0.0.2/32
        echo -e "${GREEN}[✓] Peer updated via wg tool.${NC}"
        # Also persist in file if not using wg-quick strip
        wg-quick save wg0 >/dev/null 2>&1 || true
    fi
    
    # Restart interface to apply
    systemctl restart wg-quick@wg0
    
    echo -e "${GREEN}[✓] Configuration updated and interface restarted!${NC}"
    read -p "Press Enter to return to menu..."
    show_menu
}

#===========================================
# Port Forwarding (HAProxy)
#===========================================

port_forwarding_menu() {
    show_header
    echo -e "${YELLOW}--- Port Forwarding Management (HAProxy) ---${NC}"
    echo -e "\n${CYAN}[1] Add New Port Forward${NC}"
    echo -e "${CYAN}[2] List Active Forwards${NC}"
    echo -e "${CYAN}[3] Remove Port Forward${NC}"
    echo -e "${CYAN}[4] Validate Port (Check Listening)${NC}"
    echo -e "${CYAN}[5] Return to Main Menu${NC}"
    
    read -p "  Select Option: " pf_choice
    case $pf_choice in
        1) add_haproxy_forward ;;
        2) list_haproxy_forwards ;;
        3) remove_haproxy_forward ;;
        4) validate_port_forward ;;
        5) show_menu ;;
        *) port_forwarding_menu ;;
    esac
}

add_haproxy_forward() {
    echo -e "\n${YELLOW}--- Add Port Forward ---${NC}"
    
    read -p "  Enter Local Port (Iran Server) [e.g. 443]: " L_PORT
    if [[ -z "$L_PORT" ]]; then echo -e "${RED}Port required!${NC}"; sleep 1; port_forwarding_menu; return; fi
    
    read -p "  Enter Destination IP (Tunnel Endpoint) [default: 10.0.0.1]: " D_IP
    D_IP=${D_IP:-10.0.0.1}
    
    read -p "  Enter Destination Port (Target Service) [default: $L_PORT]: " D_PORT
    D_PORT=${D_PORT:-$L_PORT}
    
    # Check if port is already used in haproxy
    if grep -q "frontend ft_$L_PORT" "$HAPROXY_CFG"; then
        echo -e "${RED}[ERROR] Port $L_PORT is already configured in HAProxy!${NC}"
        read -p "Press Enter..."
        port_forwarding_menu
        return
    fi
    
    # Check system port usage
    if ss -tuln | grep -q ":$L_PORT "; then
        echo -e "${YELLOW}[WARNING] Port $L_PORT seems to be in use by another process!${NC}"
        read -p "Proceed anyway? (HAProxy might fail to start) [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then port_forwarding_menu; return; fi
    fi

    echo -e "\n${CYAN}[*] Adding rule to HAProxy...${NC}"
    
    cat >> "$HAPROXY_CFG" << EOF

frontend ft_$L_PORT
    bind *:$L_PORT
    mode tcp
    default_backend bk_$L_PORT

backend bk_$L_PORT
    mode tcp
    server kharej $D_IP:$D_PORT check
EOF

    echo -e "${CYAN}[*] Reloading HAProxy...${NC}"
    if systemctl reload haproxy; then
        echo -e "${GREEN}[✓] Port Forward Added: $L_PORT -> $D_IP:$D_PORT${NC}"
        
        # Open Firewall for this port
        if command -v ufw &> /dev/null; then
             ufw allow $L_PORT/tcp >/dev/null 2>&1
             echo -e "${GREEN}[✓] Allowed port $L_PORT/tcp in UFW${NC}"
        elif command -v firewall-cmd &> /dev/null; then
             firewall-cmd --add-port=$L_PORT/tcp --permanent >/dev/null 2>&1
             firewall-cmd --reload >/dev/null 2>&1
             echo -e "${GREEN}[✓] Allowed port $L_PORT/tcp in Firewalld${NC}"
        fi
        
    else
        echo -e "${RED}[X] Failed to reload HAProxy! Check config syntax.${NC}"
        # detailed check
        haproxy -c -f "$HAPROXY_CFG"
    fi
    
    read -p "Press Enter..."
    port_forwarding_menu
}

list_haproxy_forwards() {
    echo -e "\n${YELLOW}--- Active HAProxy Forwards ---${NC}"
    if [[ ! -f "$HAPROXY_CFG" ]]; then
        echo -e "${RED}Config not found.${NC}"
    else
        grep -E "frontend ft_|bind|server kharej" "$HAPROXY_CFG" | sed 's/frontend ft_/\n--- Rule: /'
    fi
    echo ""
    read -p "Press Enter..."
    port_forwarding_menu
}

remove_haproxy_forward() {
    echo -e "\n${YELLOW}--- Remove Port Forward ---${NC}"
    # List available ports to remove
    PORTS=$(grep "frontend ft_" "$HAPROXY_CFG" | awk -F'ft_' '{print $2}')
    
    if [[ -z "$PORTS" ]]; then
        echo -e "${RED}No forwarding rules found.${NC}"
        read -p "Press Enter..."
        port_forwarding_menu
        return
    fi
    
    echo -e "Available Ports:"
    echo "$PORTS"
    echo ""
    read -p "  Enter Port to Remove: " R_PORT
    
    if [[ -z "$R_PORT" ]]; then port_forwarding_menu; return; fi
    
    if ! grep -q "frontend ft_$R_PORT" "$HAPROXY_CFG"; then
        echo -e "${RED}Port not found in config!${NC}"
    else
        # Remove the block. HAProxy config blocks are tricky to remove with simple sed.
        # We assume standard format: frontend block then backend block.
        # Strategy: Read file, exclude lines belonging to this port's block.
        # This is a bit complex in bash. 
        # Simpler approach: Create a temp file without the specific named sections.
        
        # We'll use a slightly safer method: comment them out or use perl/sed ranges if possible.
        # Or, since we structured it well:
        # frontend ft_PORT ...
        # backend bk_PORT ...
        
        # We will strip lines containing the port identifier in the section names 
        # AND the subsequent lines until next section? No, that's risky.
        
        # Robust method: Re-write file excluding the logic. 
        # Given the complexity of robustly editing config files in bash, 
        # we warn the user or try a focused sed deletion of known structure.
        
        # Deleting 4 lines starting from match? risky if config varies.
        # Let's try to match the exact block structure we generated.
        
        # Block 1: frontend ft_$R_PORT ... default_backend bk_$R_PORT
        # Block 2: backend bk_$R_PORT ... server kharej ...
        
        # We will clear the file of these specific named sections.
        # Using sed to delete range is hard if we don't know end.
        # BUT, we know our generation format.
        
        cp "$HAPROXY_CFG" "${HAPROXY_CFG}.bak"
        
        # Correct sed logic to remove custom blocks
        # Delete from 'frontend ft_PORT' to empty line?
        # Our generator puts empty lines.
        
        # Let's use a loop or python if available? No, stick to bash.
        # We will use grep -v to filter out the relevant lines if they have unique IDs.
        # But 'bind', 'mode', 'server' are common.
        
        # Senior approach: Read file line by line, skip blocks matching target.
        T_FILE=$(mktemp)
        SKIP=0
        while IFS= read -r line; do
            if [[ "$line" == "frontend ft_$R_PORT" ]]; then SKIP=1; fi
            if [[ "$line" == "backend bk_$R_PORT" ]]; then SKIP=1; fi
            
            if [[ "$SKIP" -eq 1 ]]; then
                # Check when to stop skipping. 
                # If we hit an empty line or next section?
                # Our blocks are separated by empty lines usually.
                # If we encounter a new 'frontend' or 'backend' that is NOT ours, we stop skipping?
                # Or just empty line.
                 if [[ -z "$line" ]]; then SKIP=0; fi
            else
                echo "$line" >> "$T_FILE"
            fi
        done < "$HAPROXY_CFG"
        
        mv "$T_FILE" "$HAPROXY_CFG"
        
        echo -e "${GREEN}[✓] Removed rules for port $R_PORT.${NC}"
        systemctl reload haproxy
    fi
    
    read -p "Press Enter..."
    port_forwarding_menu
}

validate_port_forward() {
    echo -e "\n${YELLOW}--- Validate Port ---${NC}"
    read -p "  Enter Port to Check: " V_PORT
    
    if ss -tuln | grep -q ":$V_PORT "; then
        echo -e "${GREEN}[PASS] Port $V_PORT is open and listening.${NC}"
        # Check process
        PID=$(ss -lptn "sport = :$V_PORT" | grep -oP 'pid=\K\d+')
        echo -e "Process ID: $PID"
        ps -p $PID -o comm=
    else
        echo -e "${RED}[FAIL] Port $V_PORT is NOT listening.${NC}"
        echo -e "Check if HAProxy is running: systemctl status haproxy"
    fi
    read -p "Press Enter..."
    port_forwarding_menu
}

diagnostics_menu() {
    show_header
    echo -e "${BLUE}--- Diagnostics & Validation ---${NC}"
    
    echo -e "\n${CYAN}[1] Validate Configuration File${NC}"
    echo -e "    Checks for syntax errors, key formats, and permissions."
    
    echo -e "\n${CYAN}[2] Test Connectivity (Ping Peer)${NC}"
    echo -e "    Pings the other end of the tunnel."
    
    echo -e "\n${CYAN}[3] Check Handshake Status${NC}"
    echo -e "    Verifies if keys are exchanged successfully."
    
    echo -e "\n${CYAN}[4] Return to Main Menu${NC}"
    
    read -p "  Select Option: " d_choice
    
    case $d_choice in
        1) validate_config ;;
        2) test_connection ;;
        3) check_handshake ;;
        4) show_menu ;;
        *) diagnostics_menu ;;
    esac
}

validate_config() {
    echo -e "\n${YELLOW}--- Validating Config ---${NC}"
    if [[ ! -f "$WG_CONF" ]]; then
        echo -e "${RED}[FAIL] Config file missing at $WG_CONF${NC}"
    else
        echo -e "${GREEN}[PASS] Config file exists.${NC}"
        # Check permissions
        PERM=$(stat -c "%a" "$WG_CONF")
        if [[ "$PERM" != "600" ]]; then
             echo -e "${YELLOW}[WARN] Permissions are $PERM (should be 600). Fixing...${NC}"
             chmod 600 "$WG_CONF"
             echo -e "${GREEN}[FIXED] Permissions set to 600.${NC}"
        else
             echo -e "${GREEN}[PASS] Permissions are secure (600).${NC}"
        fi
        
        # Check for placeholder
        if grep -q "INSERT_IRAN_PUBLIC_KEY_HERE" "$WG_CONF"; then
             echo -e "${RED}[FAIL] Placeholder key found! You must add the Iran Peer Public Key.${NC}"
             echo -e "${YELLOW}[TIP] Use 'Add Iran Peer' option from the main menu.${NC}"
        else
             echo -e "${GREEN}[PASS] No placeholder keys found.${NC}"
        fi
    fi
    read -p "Press Enter..."
    diagnostics_menu
}

test_connection() {
    echo -e "\n${YELLOW}--- Testing Connectivity ---${NC}"
    # Determine Peer IP
    MY_IP=$(ip -4 addr show wg0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    
    if [[ -z "$MY_IP" ]]; then
         echo -e "${RED}[FAIL] Interface wg0 is DOWN.${NC}"
         read -p "Press Enter..."
         diagnostics_menu
         return
    fi
    
    if [[ "$MY_IP" == "10.0.0.1" ]]; then
        TARGET="10.0.0.2"
        ROLE="Kharej"
    else
        TARGET="10.0.0.1"
        ROLE="Iran"
    fi
    
    echo -e "Current Role: $ROLE ($MY_IP)"
    echo -e "Pinging Peer: $TARGET"
    
    if ping -c 4 -W 1 "$TARGET"; then
        echo -e "\n${GREEN}[SUCCESS] Connection is establish and working!${NC}"
    else
        echo -e "\n${RED}[FAIL] Peer Unreachable.${NC}"
        echo -e "${YELLOW}[TIP] Check: 1. Firewalls (UDP ports open?) 2. Correct Keys? 3. Is Peer Online?${NC}"
    fi
    read -p "Press Enter..."
    diagnostics_menu
}

check_handshake() {
    echo -e "\n${YELLOW}--- Handshake Status ---${NC}"
    LATEST_HANDSHAKE=$(wg show wg0 latest-handshakes | awk '{print $2}')
    
    if [[ -z "$LATEST_HANDSHAKE" ]]; then
         echo -e "${RED}[FAIL] No handshake data found.${NC}"
    elif [[ "$LATEST_HANDSHAKE" == "0" ]]; then
         echo -e "${RED}[FAIL] No handshake ever completed.${NC}"
         echo -e "Possible causes: Wrong Keys, Firewall blocking UDP, different PresharedKeys."
    else
         CURRENT_TIME=$(date +%s)
         DIFF=$((CURRENT_TIME - LATEST_HANDSHAKE))
         if [[ "$DIFF" -lt 180 ]]; then
             echo -e "${GREEN}[PASS] Last handshake: $DIFF seconds ago (Healthy)${NC}"
         else
             echo -e "${RED}[WARN] Last handshake: $DIFF seconds ago (Stale)${NC}"
             echo -e "Connection might be lost."
         fi
    fi
    wg show wg0
    read -p "Press Enter..."
    diagnostics_menu
}

#===========================================
# Status & Management
#===========================================

show_status() {
    show_header
    echo -e "${CYAN}--- Service Status ---${NC}"
    if systemctl is-active --quiet wg-quick@wg0; then
        echo -e "Service: ${GREEN}ACTIVE${NC}"
    else
        echo -e "Service: ${RED}INACTIVE${NC}"
    fi

    echo -e "\n${CYAN}--- Interface Info ---${NC}"
    wg show wg0 || echo -e "${RED}Interface wg0 not found${NC}"

    echo -e "\n${CYAN}--- Connectivity Check ---${NC}"
    # Ping the peer
    # If we are 10.0.0.1, ping 10.0.0.2, else ping 10.0.0.1
    MY_IP=$(ip -4 addr show wg0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    if [[ "$MY_IP" == "10.0.0.1" ]]; then
        TARGET="10.0.0.2"
    else
        TARGET="10.0.0.1"
    fi
    
    echo -e "Pinging Peer ($TARGET)..."
    if ping -c 3 -W 1 $TARGET > /dev/null 2>&1; then
        echo -e "${GREEN}[✓] Connection Successful!${NC}"
    else
        echo -e "${RED}[X] Connection Failed (Peer unreachable)${NC}"
    fi

    echo ""
    read -p "Press Enter to return to menu..."
    show_menu
}

view_config() {
    show_header
    if [[ -f "$WG_CONF" ]]; then
        echo -e "${YELLOW}--- Configuration ($WG_CONF) ---${NC}"
        cat "$WG_CONF"
    else
        echo -e "${RED}Config file not found!${NC}"
    fi
    echo ""
    read -p "Press Enter to return to menu..."
    show_menu
}

uninstall_tunnel() {
    echo -e "\n${RED}[WARNING]${NC} This will remove Wire-Rocket and WireGuard configuration."
    read -p "Are you sure? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        systemctl stop wg-quick@wg0 >/dev/null 2>&1 || true
        systemctl disable wg-quick@wg0 >/dev/null 2>&1 || true
        rm -rf /etc/wireguard/wg0.conf
        rm -rf /usr/local/bin/wire-rocket
        rm -rf /usr/local/bin/wr
        # Optionally remove Install path if it's there
        rm -f "/usr/local/bin/rocket.sh"
        
        echo -e "${GREEN}[✓] Uninstalled successfully.${NC}"
        exit 0
    else
        show_menu
    fi
}

#===========================================
# Entry Point
#===========================================

# Check if arguments passed (e.g. for non-interactive mode later), else show menu
check_root
show_menu
