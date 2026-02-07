#!/bin/bash
#===========================================
#  Wire-Rocket Installer
#  One-liner installation script
#===========================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Script URL (change to your repo)
ROCKET_SCRIPT_URL="https://raw.githubusercontent.com/emad1381/Wire-Rocket/main/rocket.sh"
INSTALL_PATH="/usr/local/bin/rocket.sh"

#===========================================
# Functions
#===========================================

    print_banner() {
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
    echo -e "${CYAN}║${NC}  ${BOLD}Wire-Rocket${NC} - Fast WireGuard Tunneling Solution        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}Version: 1.0${NC}                                           ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR]${NC} This script must be run as root!"
        echo -e "${YELLOW}[TIP]${NC} Try: sudo $0"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        echo -e "${RED}[ERROR]${NC} Cannot detect OS. /etc/os-release not found."
        exit 1
    fi

    case $OS in
        ubuntu|debian)
            echo -e "${GREEN}[✓]${NC} Detected OS: ${BOLD}$OS $VERSION${NC}"
            PKG_MANAGER="apt"
            ;;
        centos|rhel|fedora|almalinux|rocky)
            echo -e "${GREEN}[✓]${NC} Detected OS: ${BOLD}$OS $VERSION${NC}"
            PKG_MANAGER="yum"
            if command -v dnf &> /dev/null; then
                PKG_MANAGER="dnf"
            fi
            ;;
        *)
            echo -e "${YELLOW}[WARNING]${NC} Unsupported OS: $OS"
            echo -e "${YELLOW}[INFO]${NC} Attempting to continue with apt..."
            PKG_MANAGER="apt"
            ;;
    esac
}

install_dependencies() {
    echo -e "\n${CYAN}[*]${NC} Installing dependencies..."
    
    if [[ $PKG_MANAGER == "apt" ]]; then
        apt update -qq
        apt install -y -qq wireguard-tools iptables curl net-tools qrencode
    else
        $PKG_MANAGER install -y epel-release
        $PKG_MANAGER install -y wireguard-tools iptables curl net-tools qrencode
    fi
    
    echo -e "${GREEN}[✓]${NC} Dependencies installed successfully!"
}

download_rocket_script() {
    echo -e "\n${CYAN}[*]${NC} Downloading Wire-Rocket main script..."
    
    # Check if rocket.sh exists in current directory (for local install)
    if [[ -f "./rocket.sh" ]]; then
        echo -e "${YELLOW}[INFO]${NC} Found local rocket.sh, using local version..."
        cp ./rocket.sh "$INSTALL_PATH"
    else
        # Download from URL
        if curl -sL "$ROCKET_SCRIPT_URL" -o "$INSTALL_PATH"; then
            echo -e "${GREEN}[✓]${NC} Downloaded rocket.sh successfully!"
        else
            echo -e "${RED}[ERROR]${NC} Failed to download rocket.sh"
            echo -e "${YELLOW}[TIP]${NC} Make sure you have internet connection and the URL is correct."
            exit 1
        fi
    fi
    
    chmod +x "$INSTALL_PATH"
    echo -e "${GREEN}[✓]${NC} Installed to: ${BOLD}$INSTALL_PATH${NC}"
}

create_symlink() {
    # Create a convenient alias
    if [[ ! -L /usr/local/bin/wire-rocket ]]; then
        ln -sf "$INSTALL_PATH" /usr/local/bin/wire-rocket 2>/dev/null || true
    fi
    if [[ ! -L /usr/local/bin/wr ]]; then
        ln -sf "$INSTALL_PATH" /usr/local/bin/wr 2>/dev/null || true
    fi
}

enable_ip_forwarding() {
    echo -e "\n${CYAN}[*]${NC} Enabling IP forwarding..."
    
    # Enable immediately
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1 || true
    
    # Make persistent
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    
    # Apply BBR if available
    if modprobe tcp_bbr 2>/dev/null; then
        echo -e "${GREEN}[✓]${NC} BBR congestion control enabled!"
        sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1 || true
        
        if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        fi
        if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        fi
    fi
    
    echo -e "${GREEN}[✓]${NC} IP forwarding enabled!"
}

print_success() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}✓ Installation Complete!${NC}                               ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}To launch Wire-Rocket, run:${NC}"
    echo -e "    ${BOLD}rocket.sh${NC}"
    echo -e "  ${CYAN}Or use the short alias:${NC}"
    echo -e "    ${BOLD}wr${NC}"
    echo ""
    echo -e "  ${YELLOW}Would you like to start the dashboard now? [Y/n]${NC}"
}

#===========================================
# Main Execution
#===========================================

main() {
    clear
    print_banner
    check_root
    detect_os
    install_dependencies
    download_rocket_script
    create_symlink
    enable_ip_forwarding
    print_success
    
    read -r -p "  " response
    response=${response:-Y}
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        exec "$INSTALL_PATH"
    else
        echo -e "\n${GREEN}[✓]${NC} Run ${BOLD}rocket.sh${NC} or ${BOLD}rt${NC} whenever you're ready!\n"
    fi
}

main "$@"
