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

# Check if running
PID=$(pidof bitcoind)
if [ -z "$PID" ]; then
    echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin is not currently running"
    exit 0
fi

echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Shutting down Bitcoin SV Node gracefully [PID: $PID]"

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

# Wait for graceful shutdown
echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Waiting for graceful shutdown..."
TIMEOUT=60
COUNT=0

while true; do
    sleep 1
    COUNT=$((COUNT + 1))
    
    # Check if process is still running
    CHECK=$(ps -ef | grep bitcoind | grep $PID | wc -l)
    
    if [ $CHECK -eq 0 ]; then
        echo_success "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin SV Node stopped gracefully [PID: $PID]"
        break
    elif [ $COUNT -ge $TIMEOUT ]; then
        echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): Graceful shutdown timeout, forcing kill..."
        kill -9 $PID 2>/dev/null || true
        sleep 2
        if [ $(ps -ef | grep bitcoind | grep $PID | wc -l) -eq 0 ]; then
            echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin SV Node force killed [PID: $PID]"
        else
            echo_error "$(date -u '+%Y-%m-%d %H:%M:%S'): Failed to stop Bitcoin SV Node"
            exit 1
        fi
        break
    else
        if [ $((COUNT % 5)) -eq 0 ]; then
            echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin $PID still running... (${COUNT}s)"
        fi
    fi
done