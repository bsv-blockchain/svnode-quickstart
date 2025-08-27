#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/colors.sh"

NODE_TYPE="${1:-pruned}"

# Minimum disk space requirements (in GB)
PRUNED_MIN_SPACE=200   # 200GB (160GB snapshot + buffer for growth)
FULL_MIN_SPACE=15000   # 15TB"

check_os() {
    echo_info "Checking operating system..."
    
    if [[ "$OSTYPE" != "linux-gnu"* ]]; then
        echo_warning "This script is designed for Linux systems."
        echo_warning "Current OS: $OSTYPE"
        echo_warning "The script may not work correctly on this system."
        return 1
    fi
    
    # Check for specific distributions
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo_info "Detected: $NAME $VERSION"
        
        case "$ID" in
            ubuntu|debian|fedora|centos|rhel|arch|manjaro|opensuse*)
                echo_success "Supported Linux distribution detected."
                ;;
            *)
                echo_warning "Untested Linux distribution: $ID"
                echo_warning "The script should work but has not been tested on this distribution."
                ;;
        esac
    else
        echo_warning "Cannot determine Linux distribution."
    fi
    
    return 0
}

check_disk_space() {
    echo_info "Checking disk space..."
    
    local required_space
    if [[ "$NODE_TYPE" == "full" ]]; then
        required_space=$FULL_MIN_SPACE
        echo_info "Full node selected. Checking for ${required_space}GB available space..."
    else
        required_space=$PRUNED_MIN_SPACE
        echo_info "Pruned node selected. Checking for ${required_space}GB available space..."
    fi
    
    # Override for testnet - much smaller requirements
    if [[ "${NETWORK:-mainnet}" == "testnet" ]]; then
        required_space=30
        echo_info "Testnet detected. Reduced requirement to ${required_space}GB."
    fi
    
    # Get available disk space in GB for root partition
    local available_space=$(df / | awk 'NR==2 {print int($4/1048576)}')
    
    echo_info "Available disk space: ${available_space}GB"
    
    if [ "$available_space" -lt "$required_space" ]; then
        echo_error "Insufficient disk space!"
        echo_error "Required: ${required_space}GB, Available: ${available_space}GB"
        
        if [[ "$NODE_TYPE" == "full" ]]; then
            echo_warning "Consider using a pruned node to reduce disk requirements."
        fi
        
        echo_yellow "Do you want to continue anyway? (not recommended) [y/N]: "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            return 1
        fi
    else
        echo_success "Sufficient disk space available."
    fi
    
    # Check for SSD
    echo_info "Checking disk type..."
    local disk_device=$(df / | awk 'NR==2 {print $1}' | sed 's/[0-9]*$//')
    
    if command -v lsblk &> /dev/null; then
        local rotation=$(lsblk -d -n -o ROTA "$disk_device" 2>/dev/null | head -n1)
        if [[ "$rotation" == "0" ]]; then
            echo_success "SSD detected (recommended for UTXO set)."
        elif [[ "$rotation" == "1" ]]; then
            echo_warning "HDD detected. SSD is strongly recommended for UTXO set storage."
            echo_warning "Node synchronization will be significantly slower with HDD."
        else
            echo_info "Could not determine disk type."
        fi
    fi
    
    return 0
}

check_dependencies() {
    echo_info "Checking required dependencies..."
    
    local missing_deps=()
    
    # Check for required commands
    local commands=("wget" "curl" "tar" "sha256sum" "openssl")
    
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
            echo_warning "Missing: $cmd"
        else
            echo_success "Found: $cmd"
        fi
    done
    
    # Check for sudo/su access
    if command -v sudo &> /dev/null; then
        if sudo -n true 2>/dev/null; then
            echo_success "sudo access available without password."
        else
            echo_info "sudo access available (password may be required)."
        fi
    elif [ "$EUID" -eq 0 ]; then
        echo_info "Running as root user."
    else
        echo_warning "No sudo access and not running as root."
        echo_warning "Installation may require manual privilege elevation."
    fi
    
    # If there are missing dependencies, offer to install them
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo_warning "Missing dependencies: ${missing_deps[*]}"
        
        # Detect package manager and offer to install
        if command -v apt-get &> /dev/null; then
            echo_info "Detected apt package manager."
            echo_yellow "Install missing dependencies with: sudo apt-get install ${missing_deps[*]}"
        elif command -v yum &> /dev/null; then
            echo_info "Detected yum package manager."
            echo_yellow "Install missing dependencies with: sudo yum install ${missing_deps[*]}"
        elif command -v dnf &> /dev/null; then
            echo_info "Detected dnf package manager."
            echo_yellow "Install missing dependencies with: sudo dnf install ${missing_deps[*]}"
        elif command -v pacman &> /dev/null; then
            echo_info "Detected pacman package manager."
            echo_yellow "Install missing dependencies with: sudo pacman -S ${missing_deps[*]}"
        fi
        
        return 1
    else
        echo_success "All required dependencies are installed."
    fi
    
    return 0
}

check_network() {
    echo_info "Checking network connectivity..."
    
    # Test connectivity to BSV download servers
    if curl -s --head --connect-timeout 5 https://download.bitcoinsv.io > /dev/null; then
        echo_success "Can reach Bitcoin SV download server."
    else
        echo_warning "Cannot reach Bitcoin SV download server."
        echo_warning "This may cause issues during installation."
    fi
    
    # Test general internet connectivity
    if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        echo_success "Internet connectivity confirmed."
    else
        echo_warning "Limited or no internet connectivity detected."
    fi
    
    return 0
}

check_ports() {
    echo_info "Checking default ports..."
    
    # Check if default BSV ports are in use
    local mainnet_port=8333
    local testnet_port=18333
    local rpc_mainnet=8332
    local rpc_testnet=18332
    
    for port in $mainnet_port $testnet_port $rpc_mainnet $rpc_testnet; do
        if netstat -tuln 2>/dev/null | grep -q ":$port "; then
            echo_warning "Port $port is already in use."
            echo_warning "This may conflict with SVNode operation."
        fi
    done
    
    echo_info "Port check complete."
    return 0
}

check_memory() {
    echo_info "Checking system memory..."
    
    local total_mem=$(free -g | awk 'NR==2 {print $2}')
    echo_info "Total RAM: ${total_mem}GB"
    
    if [ "$total_mem" -lt 8 ]; then
        echo_warning "Less than 8GB RAM detected."
        echo_warning "Minimum 8GB RAM recommended for optimal performance."
        echo_warning "The node may run slowly or encounter issues with less memory."
    else
        echo_success "Sufficient RAM available."
    fi
    
    return 0
}

main() {
    echo_green "=== System Requirements Check ==="
    echo ""
    
    local failed=0
    
    # Run all checks
    check_os || failed=1
    echo ""
    
    check_disk_space || failed=1
    echo ""
    
    check_dependencies || failed=1
    echo ""
    
    check_memory || failed=1
    echo ""
    
    check_network || failed=1
    echo ""
    
    check_ports || failed=1
    echo ""
    
    if [ $failed -eq 0 ]; then
        echo_green "=== All checks passed ==="
        return 0
    else
        echo_red "=== Some checks failed or have warnings ==="
        echo_yellow "Review the warnings above before proceeding."
        return 1
    fi
}

# Run checks if script is executed directly
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi