#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/colors.sh"

NETWORK="${1:-mainnet}"
NODE_TYPE="${2:-pruned}"
DATA_DIR="${3:-/var/lib/bsv-data}"
RPC_USER="${4:-bsv_rpc}"
RPC_PASSWORD="${5:-changeme}"

generate_mainnet_config() {
    cat << EOF
# Bitcoin SV Node Configuration
# Network: Mainnet
# Generated: $(date)

# Network
mainnet=1

# Data directory (use absolute path)
datadir=$DATA_DIR

# Connection settings
listen=1
server=1
maxconnections=125
maxuploadtarget=5000

# Peer discovery
dnsseed=1
dns=1

# RPC settings
rpcuser=$RPC_USER
rpcpassword=$RPC_PASSWORD
rpcallowip=127.0.0.1
rpcbind=127.0.0.1
rpcport=8332

# Security
rpcssl=0

# Consensus rules
excessiveblocksize=4000000000
maxstackmemoryusageconsensus=100000000

# Mempool settings
maxmempool=3000
maxmempoolsizedisk=10000
mempoolexpiry=336
minrelaytxfee=0.00000250

# Performance and caching
dbcache=4000
maxorphantx=1000
maxscriptcachesize=500
maxsigcachesize=500

# Block production (if mining)
blockmaxsize=4000000000
blockassembler=journaling

# Logging
debug=net
debug=mempool
debug=rpc
logips=1
logtimestamps=1
shrinkdebugfile=1

# Pruning settings
EOF

    if [[ "$NODE_TYPE" == "pruned" ]]; then
        cat << EOF
prune=1
pruneheight=100000
pruneafterheight=100000

EOF
    else
        cat << EOF
# Full node - no pruning
prune=0

EOF
    fi

    cat << EOF
# Additional options
printtoconsole=0
daemon=1

# Index options (full node only)
EOF

    if [[ "$NODE_TYPE" == "full" ]]; then
        cat << EOF
txindex=1
addressindex=1
timestampindex=1
spentindex=1
EOF
    else
        cat << EOF
# Indexes disabled for pruned node
txindex=0
EOF
    fi
}

generate_testnet_config() {
    cat << EOF
# Bitcoin SV Node Configuration
# Network: Testnet
# Generated: $(date)

# Network
testnet=1

# Data directory (use absolute path)
datadir=$DATA_DIR

# Connection settings
listen=1
server=1
maxconnections=125
maxuploadtarget=5000

# Peer discovery
dnsseed=1
dns=1
addnode=testnet-seed.bitcoinsv.io

# RPC settings
rpcuser=$RPC_USER
rpcpassword=$RPC_PASSWORD
rpcallowip=127.0.0.1
rpcbind=127.0.0.1
rpcport=18332

# Security
rpcssl=0

# Consensus rules (testnet)
excessiveblocksize=4000000000
maxstackmemoryusageconsensus=100000000

# Mempool settings
maxmempool=3000
maxmempoolsizedisk=10000
mempoolexpiry=336
minrelaytxfee=0.00000001

# Performance and caching
dbcache=2000
maxorphantx=1000
maxscriptcachesize=250
maxsigcachesize=250

# Block production (if mining)
blockmaxsize=4000000000
blockassembler=journaling

# Logging
debug=net
debug=mempool
debug=rpc
logips=1
logtimestamps=1
shrinkdebugfile=1

# Pruning settings
EOF

    if [[ "$NODE_TYPE" == "pruned" ]]; then
        cat << EOF
prune=1
pruneheight=10000
pruneafterheight=10000

EOF
    else
        cat << EOF
# Full node - no pruning
prune=0

EOF
    fi

    cat << EOF
# Additional options
printtoconsole=0
daemon=1

# Index options (full node only)
EOF

    if [[ "$NODE_TYPE" == "full" ]]; then
        cat << EOF
txindex=1
addressindex=1
timestampindex=1
spentindex=1
EOF
    else
        cat << EOF
# Indexes disabled for pruned node
txindex=0
EOF
    fi
}


generate_regtest_config() {
    cat << EOF
# Bitcoin SV Node Configuration
# Network: Regtest (Regression Test)
# Generated: $(date)

# Network
regtest=1

# Data directory (use absolute path)
datadir=$DATA_DIR

# Connection settings
listen=0
server=1

# RPC settings
rpcuser=$RPC_USER
rpcpassword=$RPC_PASSWORD
rpcallowip=127.0.0.1
rpcbind=127.0.0.1
rpcport=18443

# Regtest specific settings
listenonion=0

# Consensus rules (regtest - very permissive)
excessiveblocksize=1000000000
maxstackmemoryusageconsensus=100000000

# Mempool settings
maxmempool=1000
mempoolexpiry=336
minrelaytxfee=0.00000000

# Mining settings for regtest
blockmaxsize=1000000000
blockassembler=journaling

# Performance (minimal for regtest)
dbcache=500

# Logging
debug=rpc
debug=net
logips=1
logtimestamps=1

# No pruning in regtest
prune=0
txindex=1

# Additional options
printtoconsole=0
daemon=1
EOF
}

create_config_file() {
    local config_file="${DATA_DIR}/bitcoin.conf"
    
    echo_info "Generating configuration for: $NETWORK ($NODE_TYPE node)"
    
    # Create data directory if it doesn't exist
    if ! sudo mkdir -p "$DATA_DIR"; then
        echo_error "Failed to create data directory: $DATA_DIR"
        return 1
    fi
    
    # Generate appropriate configuration
    local config_content
    case "$NETWORK" in
        mainnet)
            config_content=$(generate_mainnet_config)
            ;;
        testnet)
            config_content=$(generate_testnet_config)
            ;;
        regtest)
            config_content=$(generate_regtest_config)
            ;;
        *)
            echo_error "Unknown network: $NETWORK"
            return 1
            ;;
    esac
    
    # Write configuration file
    echo "$config_content" | sudo tee "$config_file" > /dev/null
    
    if [ $? -eq 0 ]; then
        # Set proper permissions
        sudo chmod 600 "$config_file"
        echo_success "Configuration file created: $config_file"
        
        # Display important settings
        echo ""
        echo_info "Configuration Summary:"
        echo "  Network:      $NETWORK"
        echo "  Node Type:    $NODE_TYPE"
        echo "  Data Dir:     $DATA_DIR"
        echo "  RPC User:     $RPC_USER"
        echo "  RPC Port:     $(grep rpcport "$config_file" | cut -d= -f2)"
        
        if [[ "$NODE_TYPE" == "pruned" ]]; then
            echo_warning "Pruning is enabled. Historical blockchain data will be deleted."
            echo_warning "This saves disk space but limits functionality."
        fi
        
        return 0
    else
        echo_error "Failed to create configuration file."
        return 1
    fi
}

validate_inputs() {
    # Validate network
    case "$NETWORK" in
        mainnet|testnet|regtest)
            ;;
        *)
            echo_error "Invalid network: $NETWORK"
            echo_info "Valid options: mainnet, testnet, regtest"
            return 1
            ;;
    esac
    
    # Validate node type
    case "$NODE_TYPE" in
        pruned|full)
            ;;
        *)
            echo_error "Invalid node type: $NODE_TYPE"
            echo_info "Valid options: pruned, full"
            return 1
            ;;
    esac
    
    # Validate data directory
    if [[ -z "$DATA_DIR" ]]; then
        echo_error "Data directory cannot be empty"
        return 1
    fi
    
    # Validate RPC credentials
    if [[ -z "$RPC_USER" ]] || [[ -z "$RPC_PASSWORD" ]]; then
        echo_error "RPC credentials cannot be empty"
        return 1
    fi
    
    if [[ "$RPC_PASSWORD" == "changeme" ]]; then
        echo_warning "Using default RPC password. This is insecure!"
    fi
    
    return 0
}

main() {
    echo_green "=== Bitcoin Configuration Generator ==="
    echo ""
    
    # Validate inputs
    if ! validate_inputs; then
        echo_error "Invalid configuration parameters"
        return 1
    fi
    
    # Create configuration file
    if create_config_file; then
        echo ""
        echo_green "Configuration generated successfully!"
        return 0
    else
        echo_error "Configuration generation failed!"
        return 1
    fi
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi