#!/bin/bash

cd $(dirname "$0")

# Source helper libraries
source "./lib/colors.sh"

echo_info "$(date -u '+%Y-%m-%d %H:%M:%S'): Restarting Bitcoin SV Node..."

# Stop the node first
./stop.sh

# Wait a moment between stop and start
sleep 2

# Start the node
./start.sh