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

# Check if running (use pgrep for more reliable detection)
PID=$(pgrep -f "bitcoind.*conf.*bitcoin.conf" | head -n1)
if [ -z "$PID" ]; then
    echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin is not currently running"
    exit 0
fi

# Check if it's a zombie/defunct process
PROCESS_STATE=$(ps -p $PID -o stat= 2>/dev/null | tr -d ' ')
if [[ "$PROCESS_STATE" == *"Z"* ]] || ps -p $PID -o comm= 2>/dev/null | grep -q "<defunct>"; then
    echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin process [PID: $PID] is zombie/defunct, force killing..."
    kill -9 $PID 2>/dev/null || true
    sleep 1
    echo_success "$(date -u '+%Y-%m-%d %H:%M:%S'): Zombie process cleaned up"
    exit 0
fi

echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Shutting down Bitcoin SV Node gracefully [PID: $PID]"

# Check if this is regtest (should be instant)
IS_REGTEST=false
if grep -q "^regtest=1" ./bsv-data/bitcoin.conf; then
    IS_REGTEST=true
    TIMEOUT=10  # Only wait 10 seconds for regtest
else
    TIMEOUT=60  # Normal timeout for mainnet/testnet
fi

# Try graceful shutdown first using bitcoin-cli
if [ -x ./bsv/bin/bitcoin-cli ]; then
    echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Sending stop command via RPC..."
    ./bsv/bin/bitcoin-cli -conf=$(realpath ./bsv-data/bitcoin.conf) stop 2>/dev/null || {
        echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): RPC stop failed, using kill signal"
        kill $PID
    }
else
    echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): bitcoin-cli not found, using kill signal"
    kill $PID
fi

# Wait for graceful shutdown
echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Waiting for graceful shutdown..."
COUNT=0

while true; do
    sleep 1
    COUNT=$((COUNT + 1))
    
    # Check if process is still running or became zombie
    CHECK=$(ps -p $PID -o pid= 2>/dev/null | wc -l)
    PROCESS_STATE=$(ps -p $PID -o stat= 2>/dev/null | tr -d ' ')
    
    if [ $CHECK -eq 0 ]; then
        echo_success "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin SV Node stopped gracefully [PID: $PID]"
        break
    elif [[ "$PROCESS_STATE" == *"Z"* ]] || ps -p $PID -o comm= 2>/dev/null | grep -q "<defunct>"; then
        echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): Process became zombie, force killing..."
        kill -9 $PID 2>/dev/null || true
        sleep 1
        echo_success "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin SV Node stopped [PID: $PID]"
        break
    elif [ $COUNT -ge $TIMEOUT ]; then
        if [ "$IS_REGTEST" = true ]; then
            echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): Regtest should stop instantly, force killing..."
        else
            echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): Graceful shutdown timeout, forcing kill..."
        fi
        kill -9 $PID 2>/dev/null || true
        sleep 2
        if [ $(ps -p $PID -o pid= 2>/dev/null | wc -l) -eq 0 ]; then
            echo_warning "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin SV Node force killed [PID: $PID]"
        else
            echo_error "$(date -u '+%Y-%m-%d %H:%M:%S'): Failed to stop Bitcoin SV Node"
            exit 1
        fi
        break
    else
        if [ $((COUNT % 3)) -eq 0 ] || [ "$IS_REGTEST" = true ]; then
            echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Bitcoin $PID still running... (${COUNT}s)"
        fi
    fi
done