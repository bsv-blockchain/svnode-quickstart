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

menu_select() {
    local prompt="$1"
    shift
    local options=("$@")
    local selected=0
    local key

    # Hide cursor
    tput civis

    while true; do
        # Clear screen and show menu
        clear
        echo_blue "=================================================="
        echo_blue "           SVNode Quick Setup Script              "
        echo_blue "=================================================="
        echo ""
        echo_yellow "$prompt"
        echo ""

        # Display options with selection indicator
        for i in "${!options[@]}"; do
            if [ $i -eq $selected ]; then
                echo_green "  → ${options[$i]}"
            else
                echo "    ${options[$i]}"
            fi
        done

        echo ""
        echo_yellow "Use ↑/↓ arrow keys to navigate, Enter to select"

        # Read single character
        read -rsn1 key

        case "$key" in
            $'\x1b')  # Escape sequence
                read -rsn2 key
                case "$key" in
                    '[A')  # Up arrow
                        if [ $selected -gt 0 ]; then
                            selected=$((selected - 1))
                        fi
                        ;;
                    '[B')  # Down arrow
                        if [ $selected -lt $((${#options[@]} - 1)) ]; then
                            selected=$((selected + 1))
                        fi
                        ;;
                esac
                ;;
            '')  # Enter key
                break
                ;;
            'q'|'Q')  # Quit
                echo ""
                echo_red "Setup cancelled."
                tput cnorm  # Show cursor
                exit 1
                ;;
        esac
    done

    # Show cursor again
    tput cnorm

    # Clear screen one more time and show selection
    clear
    echo_blue "=================================================="
    echo_blue "           SVNode Quick Setup Script              "
    echo_blue "=================================================="
    echo ""

    # Return the selected index (don't re-enable set -e here as it will exit on non-zero return)
    return $selected
}

collect_user_preferences() {
    echo_green "=== Configuration Setup ==="
    echo ""

    # Network selection
    set +e
    menu_select "Select network:" "Mainnet" "Testnet" "Regtest"
    local network_choice=$?
    set -e
    case $network_choice in
        0) NETWORK="mainnet" ;;
        1) NETWORK="testnet" ;;
        2) NETWORK="regtest" ;;
    esac
    echo_info "Network: $NETWORK"
    echo ""

    # Sync method selection first (not for regtest)
    if [[ "$NETWORK" != "regtest" ]]; then
        set +e
        menu_select "Select sync method:" "Download snapshot (faster)" "Sync from genesis block (slower)"
        local sync_choice=$?
        set -e
        case $sync_choice in
            0)
                SYNC_METHOD="snapshot"
                # Auto-select node type based on network and snapshot choice
                # Both mainnet and testnet snapshots are pruned
                NODE_TYPE="pruned"
                if [[ "$NETWORK" == "mainnet" ]]; then
                    echo_info "Mainnet snapshot selected - using pruned mode (200GB)"
                else  # testnet
                    echo_info "Testnet snapshot selected - using pruned mode (300GB)"
                fi
                ;;
            1)
                SYNC_METHOD="genesis"
                # For genesis sync, allow user to choose node type
                if [[ "$NETWORK" == "mainnet" ]]; then
                    set +e
                    menu_select "Select node type:" "Pruned (minimal disk space ~200GB)" "Full (complete blockchain ~15TB)"
                    local node_choice=$?
                    set -e
                    case $node_choice in
                        0) NODE_TYPE="pruned" ;;
                        1) NODE_TYPE="full" ;;
                    esac
                else  # testnet
                    set +e
                    menu_select "Select node type:" "Pruned (minimal disk space ~200GB)" "Full (complete blockchain ~300GB)"
                    local node_choice=$?
                    set -e
                    case $node_choice in
                        0) NODE_TYPE="pruned" ;;
                        1) NODE_TYPE="full" ;;
                    esac
                fi
                ;;
        esac
        echo_info "Sync method: $SYNC_METHOD"
        echo_info "Node type: $NODE_TYPE"
        echo ""
    else
        # Regtest is always full
        NODE_TYPE="full"
        SYNC_METHOD="genesis"
        echo_info "Regtest mode - using full node configuration"
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
        RPC_PASSWORD="bsv_pass_$(openssl rand -hex 16)"
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

    # Collect user preferences first (to determine node type)
    collect_user_preferences

    # Check system requirements after we know the node type
    echo_info "Checking system requirements..."
    if ! bash "${LIB_DIR}/check_requirements.sh" "$NODE_TYPE" "$NETWORK"; then
        echo_red "System requirements check failed."
        if ! prompt_yes_no "Continue anyway?" "n"; then
            exit 1
        fi
    fi
    echo_green "System requirements check complete."
    echo ""

    # Confirm settings
    confirm_settings

    # Create directories
    echo_info "Creating directories..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR"

    # Download and install SVNode
    echo_info "Downloading SVNode v${BSV_VERSION}..."
    bash "${LIB_DIR}/download_node.sh" "$BSV_VERSION" "$INSTALL_DIR"

    # Generate configuration
    echo_info "Generating bitcoin.conf..."
    bash "${LIB_DIR}/config_generator.sh" \
        "$NETWORK" \
        "$NODE_TYPE" \
        "$DATA_DIR" \
        "$RPC_USER" \
        "$RPC_PASSWORD"

    # Sync snapshot if requested
    if [[ "$SYNC_METHOD" == "snapshot" ]]; then
        echo_info "Syncing blockchain snapshot..."
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
    echo "  Use CLI:         ./cli.sh <command>"
    # Show network-specific log path
    local log_path
    if [[ "$NETWORK" == "testnet" ]]; then
        log_path="${DATA_DIR}/testnet3/bitcoind.log"
    elif [[ "$NETWORK" == "regtest" ]]; then
        log_path="${DATA_DIR}/regtest/bitcoind.log"
    else
        log_path="${DATA_DIR}/bitcoind.log"
    fi
    echo "  View logs:       tail -f ${log_path}"
    echo ""
    echo "Examples:"
    echo "  ./cli.sh getblockchaininfo"
    echo "  ./cli.sh getpeerinfo"
    echo "  ./cli.sh help"
    echo ""
    echo_info "Configuration file: ${DATA_DIR}/bitcoin.conf"
    echo_info "Data directory: ${DATA_DIR}"
    echo ""
    echo_green "Setup complete! Your SVNode is ready to use."
    echo_info "Start with: ./start.sh"
}

# Run main function
main "$@"
