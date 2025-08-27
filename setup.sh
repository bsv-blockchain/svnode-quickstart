#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# Source helper libraries
source "${LIB_DIR}/colors.sh"

# Default values
DEFAULT_INSTALL_DIR="./bsv"
DEFAULT_DATA_DIR="./bsv-data"
NETWORK="mainnet"
NODE_TYPE="pruned"
SYNC_METHOD="snapshot"
BSV_VERSION="1.1.1"

# Configuration variables
INSTALL_DIR=""
DATA_DIR=""
RPC_USER=""
RPC_PASSWORD=""

print_banner() {
    echo_blue "=================================================="
    echo_blue "           SVNode Quick Setup Script              "
    echo_blue "=================================================="
    echo ""
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local response
    
    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    read -p "$(echo_yellow "$prompt")" response
    response=${response:-$default}
    
    [[ "$response" =~ ^[Yy]$ ]]
}

prompt_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice
    
    echo_yellow "$prompt"
    for i in "${!options[@]}"; do
        echo "  $((i+1)). ${options[$i]}"
    done
    
    while true; do
        read -p "$(echo_yellow "Enter choice [1-${#options[@]}]: ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            return $((choice-1))
        fi
        echo_red "Invalid choice. Please try again."
    done
}

collect_user_preferences() {
    echo_green "=== Configuration Setup ==="
    echo ""
    
    # Network selection
    prompt_choice "Select network:" "Mainnet" "Testnet" "Regtest"
    case $? in
        0) NETWORK="mainnet" ;;
        1) NETWORK="testnet" ;;
        2) NETWORK="regtest" ;;
    esac
    echo_info "Network: $NETWORK"
    echo ""
    
    # Node type selection
    prompt_choice "Select node type:" "Pruned (minimal disk space)" "Full (complete blockchain)"
    case $? in
        0) NODE_TYPE="pruned" ;;
        1) NODE_TYPE="full" ;;
    esac
    echo_info "Node type: $NODE_TYPE"
    echo ""
    
    # Sync method selection (not for regtest)
    if [[ "$NETWORK" != "regtest" ]]; then
        if [[ "$NODE_TYPE" == "pruned" ]]; then
            prompt_choice "Select sync method:" "Download snapshot (faster)" "Sync from genesis block (slower)"
            case $? in
                0) SYNC_METHOD="snapshot" ;;
                1) SYNC_METHOD="genesis" ;;
            esac
        else
            SYNC_METHOD="genesis"
            echo_info "Full nodes must sync from genesis block"
        fi
        echo_info "Sync method: $SYNC_METHOD"
        echo ""
    fi
    
    
    # Use default directories (relative to script location)
    INSTALL_DIR="$DEFAULT_INSTALL_DIR"
    DATA_DIR="$DEFAULT_DATA_DIR"
    echo_info "Installation directory: $INSTALL_DIR"
    echo_info "Data directory: $DATA_DIR"
    echo ""
    
    # RPC credentials
    if prompt_yes_no "Generate random RPC credentials?" "y"; then
        RPC_USER="bsv_rpc_$(openssl rand -hex 4)"
        RPC_PASSWORD="$(openssl rand -base64 32)"
        echo_info "Generated RPC username: $RPC_USER"
        echo_info "Generated RPC password: $RPC_PASSWORD"
        echo_warning "Please save these credentials securely!"
    else
        read -p "$(echo_yellow "RPC username: ")" RPC_USER
        read -s -p "$(echo_yellow "RPC password: ")" RPC_PASSWORD
        echo ""
    fi
    echo ""
}

confirm_settings() {
    echo_green "=== Configuration Summary ==="
    echo "Network:             $NETWORK"
    echo "Node type:           $NODE_TYPE"
    [[ "$NETWORK" != "regtest" ]] && echo "Sync method:         $SYNC_METHOD"
    echo "Installation dir:    $INSTALL_DIR"
    echo "Data directory:      $DATA_DIR"
    echo "RPC username:        $RPC_USER"
    echo ""
    
    if ! prompt_yes_no "Proceed with installation?" "y"; then
        echo_red "Installation cancelled."
        exit 1
    fi
}

main() {
    print_banner
    
    # Check if running as root (warn but don't prevent)
    if [[ $EUID -eq 0 ]]; then
        echo_warning "Running as root. It's recommended to run as a regular user with sudo access."
        if ! prompt_yes_no "Continue anyway?" "n"; then
            exit 1
        fi
    fi
    
    # Check system requirements
    echo_info "Checking system requirements..."
    if ! bash "${LIB_DIR}/check_requirements.sh" "$NODE_TYPE"; then
        echo_red "System requirements check failed."
        exit 1
    fi
    echo_green "System requirements met."
    echo ""
    
    # Collect user preferences
    collect_user_preferences
    
    # Confirm settings
    confirm_settings
    
    # Create directories
    echo_info "Creating directories..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR"
    
    # Download and install SVNode
    echo_info "Downloading SVNode v${BSV_VERSION}..."
    bash "${LIB_DIR}/download_node.sh" "$BSV_VERSION" "$INSTALL_DIR"
    
    # Create data directory symlink for convenience
    echo_info "Creating data directory symlink..."
    ln -sfn "$DATA_DIR" "./bsv-data"
    
    # Generate configuration
    echo_info "Generating bitcoin.conf..."
    bash "${LIB_DIR}/config_generator.sh" \
        "$NETWORK" \
        "$NODE_TYPE" \
        "$DATA_DIR" \
        "$RPC_USER" \
        "$RPC_PASSWORD"
    
    # Download snapshot if requested
    if [[ "$SYNC_METHOD" == "snapshot" ]]; then
        echo_info "Downloading blockchain snapshot..."
        bash "${LIB_DIR}/snapshot_sync.sh" "$NETWORK" "$DATA_DIR"
    fi
    
    # Make helper scripts executable
    echo_info "Setting up helper scripts..."
    chmod +x "${SCRIPT_DIR}"/*.sh
    
    echo ""
    echo_green "=== Installation Complete ==="
    echo ""
    echo "Management Commands:"
    echo "  Start SVNode:    ./start.sh"
    echo "  Stop SVNode:     ./stop.sh"
    echo "  Restart SVNode:  ./restart.sh"
    echo "  Use CLI:         ./b.sh <command>"
    echo "  View logs:       tail -f ${DATA_DIR}/debug.log"
    echo ""
    echo "Examples:"
    echo "  ./b.sh getblockchaininfo"
    echo "  ./b.sh getpeerinfo"
    echo "  ./b.sh help"
    echo ""
    echo_info "Configuration file: ${DATA_DIR}/bitcoin.conf"
    echo_info "Data directory: ${DATA_DIR}"
    echo ""
    echo_green "Setup complete! Your SVNode is ready to use."
    echo_info "Start with: ./start.sh"
}

# Run main function
main "$@"