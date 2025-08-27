#!/bin/bash

cd $(dirname "$0")

# Source helper libraries
source "./lib/colors.sh"

# Function to get log file path based on network
get_log_path() {
    if [ ! -f ./bsv-data/bitcoin.conf ]; then
        echo "./bsv-data/bitcoind.log"  # fallback
        return
    fi
    
    if grep -q "^testnet=1" ./bsv-data/bitcoin.conf; then
        echo "./bsv-data/testnet3/bitcoind.log"
    elif grep -q "^regtest=1" ./bsv-data/bitcoin.conf; then
        echo "./bsv-data/regtest/bitcoind.log"
    else
        echo "./bsv-data/bitcoind.log"
    fi
}

# Check if bitcoin.conf exists
if [ ! -f ./bsv-data/bitcoin.conf ]; then
    echo_error "$(date -u '+%Y-%m-%d %H:%M:%S'): bitcoin.conf not found in ./bsv-data/"
    echo_error "This does not appear to be a properly configured SVNode installation."
    exit 1
fi

# Check if bitcoind binary exists
if [ ! -x ./bsv/bin/bitcoind ]; then
    echo_error "$(date -u '+%Y-%m-%d %H:%M:%S'): bitcoind binary not found at ./bsv/bin/bitcoind"
    echo_error "Please ensure SVNode is properly installed."
    exit 1
fi

# Check if already running
PID=$(pgrep -f "bitcoind.*conf.*bitcoin.conf" | head -n1)
if [ ! -z "$PID" ]; then
    echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin is already running [PID: $PID]"
    echo_info "Use ./stop.sh to stop or ./restart.sh to restart"
    exit 1
fi

echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Starting Bitcoin SV Node..."

# Start bitcoind with daemon mode
./bsv/bin/bitcoind -conf=$(realpath ./bsv-data/bitcoin.conf)

# Wait a moment for startup
sleep 3

# Check if it started successfully
PID=$(pgrep -f "bitcoind.*conf.*bitcoin.conf" | head -n1)
if [ ! -z "$PID" ]; then
    echo_success "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin SV Node started successfully [PID: $PID]"
    
    # Try to get basic info
    echo_info "Checking node status..."
    sleep 2
    
    if ./bsv/bin/bitcoin-cli -conf=$(realpath ./bsv-data/bitcoin.conf) getblockchaininfo 2>/dev/null | head -5; then
        echo_success "Node is responding to RPC calls"
    else
        echo_warning "Node started but may still be initializing (RPC not ready yet)"
        echo_info "Monitor with: tail -f $(get_log_path)"
    fi
else
    echo_error "$(date -u '+%Y-%m-%d %H:%M:%S'): Failed to start Bitcoin SV Node"
    echo_info "Check logs: tail -f $(get_log_path)"
    exit 1
fi