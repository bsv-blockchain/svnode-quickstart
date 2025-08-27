#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/colors.sh"

NETWORK="$1"
NODE_TYPE="$2"
DATA_DIR="$3"
RPC_USER="$4"
RPC_PASSWORD="$5"

# Check required parameters
if [ -z "$NETWORK" ] || [ -z "$NODE_TYPE" ] || [ -z "$DATA_DIR" ] || [ -z "$RPC_USER" ] || [ -z "$RPC_PASSWORD" ]; then
    echo_error "Missing required parameters"
    echo_info "Usage: $0 <network> <node_type> <data_dir> <rpc_user> <rpc_password>"
    echo_info "  network: mainnet, testnet, or regtest"
    echo_info "  node_type: pruned or full"
    echo_info "  data_dir: Path to data directory"
    echo_info "  rpc_user: RPC username"
    echo_info "  rpc_password: RPC password"
    echo_info ""
    echo_info "Example: $0 mainnet pruned ./bsv-data myuser mypassword"
    exit 1
fi

generate_network_config() {
    local network_type="$1"

    cat << EOF
# Bitcoin SV Node Configuration
# Network: ${network_type^}
# Generated: $(date)

# Network
${network_type}=1

# Data directory (use absolute path)
datadir=$(realpath "$DATA_DIR")

# Basic settings
daemon=1
server=1

# Connection settings
maxconnections=300
maxconnectionsfromaddr=5
maxpendingresponses_getheaders=50
maxpendingresponses_gethdrsen=10
maxaddnodeconnections=25
maxoutboundconnections=100

# Ban unwanted clients
banclientua=bitcoin-cash-seeder
banclientua=bcash
banclientua=Bitcoin ABC
banclientua=Bitcoin Cash
banclientua=Bitcoin XT
banclientua=BUCash
banclientua=cashnodes
banclientua=bchd
banclientua=BCH

# RPC settings
rpcuser=$RPC_USER
rpcpassword=$RPC_PASSWORD
rpcallowip=127.0.0.1
rpcbind=127.0.0.1
rpcworkqueue=600
rpcthreads=16

# Required Consensus Rules for Genesis
excessiveblocksize=10GB
maxstackmemoryusageconsensus=100MB

# Transaction index (supported in pruned mode in 1.1.1+)
txindex=1

EOF

    # Add network-specific tuning options
    if [[ "$network_type" == "mainnet" ]]; then
        cat << EOF
# Tuning options (Mainnet)
maxmempool=16GB
dbcache=32GB
maxsigcachesize=256MB
maxscriptcachesize=256MB
threadsperblock=16
txnthreadsperblock=16
recvinvqueuefactor=100
maxprotocolrecvpayloadlength=1000000000
maxstdtxvalidationduration=50
maxnonstdtxvalidationduration=5000
maxtxnvalidatorasynctasksrunduration=30000
numstdtxvalidationthreads=8
numnonstdtxvalidationthreads=8
txnvalidationqueuesmaxmemory=8GB

EOF
    else
        # Testnet - use lower values
        cat << EOF
# Tuning options (Testnet - reduced)
maxmempool=4GB
dbcache=8GB
maxsigcachesize=128MB
maxscriptcachesize=128MB
threadsperblock=8
txnthreadsperblock=8
recvinvqueuefactor=50
maxprotocolrecvpayloadlength=1000000000
maxstdtxvalidationduration=50
maxnonstdtxvalidationduration=5000
maxtxnvalidatorasynctasksrunduration=15000
numstdtxvalidationthreads=4
numnonstdtxvalidationthreads=4
txnvalidationqueuesmaxmemory=4GB

EOF
    fi

    cat << EOF
# Minimum mining transaction fee, 1 sat/kb
minminingtxfee=0.00000001
mintxfee=0.00000001

# ZeroMQ notification options (uncomment to enable)
#zmqpubhashtx=tcp://127.0.0.1:28332
#zmqpubhashblock=tcp://127.0.0.1:28332

# Debug options
# Options: net, tor, mempool, http, bench, zmq, db, rpc, addrman, selectcoins,
#         reindex, cmpctblock, rand, prune, proxy, mempoolrej, libevent,
#         coindb, leveldb, txnprop, txnsrc, journal, txnval
# 1 = all options enabled, 0 = all off (default)
debug=doublespend
logips=1

# Store block data in 2GB files (default is 128MB)
preferredblockfilesize=2GB

# Mining - biggest block size you want to mine
blockmaxsize=4GB

# Pruning settings
EOF

    if [[ "$NODE_TYPE" == "pruned" ]]; then
        cat << EOF
prune=1000 # 1GB, but at least last 288 blocks
EOF
    else
        cat << EOF
# Full node - no pruning
prune=0
EOF
    fi
}

generate_mainnet_config() {
    generate_network_config "mainnet"
}

generate_testnet_config() {
    generate_network_config "testnet"
}


generate_regtest_config() {
    cat << EOF
# Bitcoin SV Node Configuration
# Network: Regtest (Regression Test)
# Generated: $(date)

# Network
regtest=1

# Data directory (use absolute path)
datadir=$(realpath "$DATA_DIR")

# Basic settings
daemon=1
server=1
listen=0

# Connection settings (minimal for regtest)
maxconnections=50

# RPC settings
rpcuser=$RPC_USER
rpcpassword=$RPC_PASSWORD
rpcallowip=127.0.0.1
rpcbind=127.0.0.1
rpcworkqueue=100
rpcthreads=4

# Consensus rules (regtest - permissive)
excessiveblocksize=1GB
maxstackmemoryusageconsensus=100MB

# Mempool settings (minimal)
maxmempool=1GB
dbcache=500MB

# Minimum fees
minminingtxfee=0.00000001
mintxfee=0.00000001

# Mining - block size for regtest
blockmaxsize=1GB

# Debug options
debug=rpc
logips=1

# No pruning in regtest, enable indexes
prune=0
txindex=1
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
