#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# Source helper libraries
source "${LIB_DIR}/colors.sh"

echo_red "=== SVNode Cleanup Script ==="
echo ""
echo_warning "This will remove ALL files from:"
echo "  - ./bsv/ (except .gitkeep)"
echo "  - ./bsv-data/ (except .gitkeep)"
echo "  - ./downloads/"
echo ""
echo_warning "This action cannot be undone!"
echo ""

read -p "$(echo_yellow "Are you sure you want to proceed? [y/N]: ")" response
if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo_info "Cleanup cancelled."
    exit 0
fi

echo ""
echo_info "Cleaning up directories..."

# Clean bsv directory (keep .gitkeep)
if [ -d "./bsv" ]; then
    echo_info "Cleaning ./bsv/"
    find ./bsv -mindepth 1 ! -name '.gitkeep' -delete
fi

# Clean bsv-data directory (keep .gitkeep)
if [ -d "./bsv-data" ]; then
    echo_info "Cleaning ./bsv-data/"
    find ./bsv-data -mindepth 1 ! -name '.gitkeep' -delete
fi

# Clean downloads directory entirely
if [ -d "./downloads" ]; then
    echo_info "Cleaning ./downloads/"
    rm -rf ./downloads
fi

echo ""
echo_green "Cleanup complete!"
echo_info "All SVNode files have been removed."
echo_info "You can run ./setup.sh to reinstall."