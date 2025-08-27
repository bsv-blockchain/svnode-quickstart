#!/bin/bash

cd $(dirname "$0")

# Source helper libraries
source "./lib/colors.sh"

# Check if bitcoin.conf exists
if [ ! -f ./bsv-data/bitcoin.conf ]; then
    echo_error "$(date -u '+%Y-%m-%d %H:%M:%S'): bitcoin.conf not found in ./bsv-data/"
    echo_error "This does not appear to be a properly configured SVNode installation."
    exit 1
fi

# Check current status
PID=$(pidof bitcoind)

# Skip shutdown if NOKILL is set (for testing/development)
if [ ! -z "$NOKILL" ]; then
    if [ ! -z "$PID" ]; then
        echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): Skipping shutdown of Bitcoin [PID: $PID] (NOKILL set)"
    else
        echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin not running, NOKILL set"
    fi
else
    if [ ! -z "$PID" ]; then
        echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Shutting down Bitcoin SV Node [PID: $PID]"
        
        # Try graceful shutdown first using bitcoin-cli
        if [ -x ./bsv/bin/bitcoin-cli ]; then
            echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Sending stop command via RPC..."
            ./bsv/bin/bitcoin-cli -conf=./bsv-data/bitcoin.conf stop 2>/dev/null || {
                echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): RPC stop failed, using kill signal"
                kill $PID
            }
        else
            echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): bitcoin-cli not found, using kill signal"
            kill $PID
        fi

        # Wait for shutdown
        TIMEOUT=60
        COUNT=0
        
        while true; do
            sleep 1
            COUNT=$((COUNT + 1))
            
            # Check if process is still running
            CHECK=$(ps -ef | grep bitcoind | grep $PID | wc -l)
            
            if [ $CHECK -eq 0 ]; then
                echo_success "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin SV Node stopped [PID: $PID]"
                break
            elif [ $COUNT -ge $TIMEOUT ]; then
                echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): Graceful shutdown timeout, forcing kill..."
                kill -9 $PID 2>/dev/null || true
                sleep 2
                echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin SV Node force killed [PID: $PID]"
                break
            else
                if [ $((COUNT % 5)) -eq 0 ]; then
                    echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin $PID still running... (${COUNT}s)"
                fi
            fi
        done
    else
        echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin was not running"
    fi
fi

# Wait a moment before starting
sleep 2

# Start Bitcoin SV Node
echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Starting Bitcoin SV Node..."

if [ ! -x ./bsv/bin/bitcoind ]; then
    echo_error "$(date -u '+%Y-%m-%d %H:%M:%S'): bitcoind binary not found at ./bsv/bin/bitcoind"
    exit 1
fi

./bsv/bin/bitcoind -conf=./bsv-data/bitcoin.conf -datadir=./bsv-data

# Wait for startup
sleep 5

# Check if started successfully
NEW_PID=$(pidof bitcoind)
if [ ! -z "$NEW_PID" ]; then
    echo_success "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin SV Node started successfully [PID: $NEW_PID]"
    
    # Try to get basic info
    echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Checking node status..."
    sleep 2
    
    if ./bsv/bin/bitcoin-cli -conf=./bsv-data/bitcoin.conf getblockchaininfo 2>/dev/null | head -3; then
        echo_success "$(date -u '+%Y-%m-%d %H:%M:%S'): Node is responding to RPC calls"
    else
        echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): Node started but may still be initializing"
        echo_info "Monitor startup with: tail -f ./bsv-data/debug.log"
    fi
else
    echo_error "$(date -u '+%Y-%m-%d %H:%M:%S'): Failed to start Bitcoin SV Node"
    echo_info "Check logs: tail -f ./bsv-data/debug.log"
    exit 1
fi