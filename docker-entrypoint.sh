#!/bin/bash
set -e

echo "Updating package lists..."
apt-get update > /dev/null 2>&1

echo "Installing required packages..."
apt-get install -y wget curl tar openssl sudo iputils-ping pigz pv > /dev/null 2>&1

echo "All packages installed successfully - container ready!"

# Keep container running
tail -f /dev/null
