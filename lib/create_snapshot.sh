#!/bin/bash

# Generic Bitcoin Data Snapshot Creation Script
# Syncs essential blockchain directories (blocks, chainstate, frozentxos, merkle)
# Supports both mainnet and testnet with block height subdirectories

set -e  # Exit on any error

# Parse command line arguments
NETWORK="$1"
SOURCE_DIR="$2" 
DEST_BASE_DIR="$3"
BLOCK_HEIGHT="$4"

# Show usage if parameters missing
if [ -z "$NETWORK" ] || [ -z "$SOURCE_DIR" ] || [ -z "$DEST_BASE_DIR" ] || [ -z "$BLOCK_HEIGHT" ]; then
    echo "Error: Missing required parameters"
    echo ""
    echo "Usage: $0 <network> <source_dir> <dest_base_dir> <block_height>"
    echo ""
    echo "Parameters:"
    echo "  network:       Network type (mainnet or testnet)"
    echo "  source_dir:    Source directory containing blockchain data"
    echo "  dest_base_dir: Base destination directory for snapshots"
    echo "  block_height:  Current block height for this snapshot"
    echo ""
    echo "Examples:"
    echo "  $0 mainnet /mnt/bitcoin-data/bitcoin-data-mainnet /mnt/bitcoin-data/snapshots 850123"
    echo "  $0 testnet /mnt/bitcoin-data/bitcoin-data-testnet /mnt/bitcoin-data/snapshots 1691058"
    exit 1
fi

# Validate network parameter
if [[ "$NETWORK" != "mainnet" ]] && [[ "$NETWORK" != "testnet" ]]; then
    echo "Error: Invalid network '$NETWORK'"
    echo "Valid options: mainnet, testnet"
    exit 1
fi

# Validate block height is numeric
if ! [[ "$BLOCK_HEIGHT" =~ ^[0-9]+$ ]]; then
    echo "Error: Block height must be a positive number: $BLOCK_HEIGHT"
    exit 1
fi

# Check if source directory exists
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Error: Source directory $SOURCE_DIR not found!"
    exit 1
fi

# Construct destination directory with network and height
DEST_DIR="${DEST_BASE_DIR}/${NETWORK}/${BLOCK_HEIGHT}"

echo "=== Bitcoin ${NETWORK^} Data Snapshot Creation ==="
echo "Source: $SOURCE_DIR"
echo "Destination: $DEST_DIR"
echo "Block Height: $BLOCK_HEIGHT"
echo ""

# Create destination directory if it doesn't exist
mkdir -p "$DEST_DIR"

echo "Starting sync..."

# Determine what to sync based on network
if [[ "$NETWORK" == "testnet" ]]; then
    echo "Including: testnet3/blocks, testnet3/chainstate, testnet3/frozentxos, testnet3/merkle"
else
    echo "Including: blocks, chainstate, frozentxos, merkle"
fi
echo ""

# Run rsync with appropriate filters based on network
if [[ "$NETWORK" == "testnet" ]]; then
    # For testnet, include testnet3 subdirectory structure
    rsync -av \
        --include="testnet3/" \
        --include="testnet3/blocks/***" \
        --include="testnet3/chainstate/***" \
        --include="testnet3/frozentxos/***" \
        --include="testnet3/merkle/***" \
        --exclude="*" \
        --stats \
        --human-readable \
        --delete-after \
        --progress \
        "$SOURCE_DIR/" "$DEST_DIR/"
else
    # For mainnet, sync directories at root level
    rsync -av \
        --include="blocks/***" \
        --include="chainstate/***" \
        --include="frozentxos/***" \
        --include="merkle/***" \
        --exclude="*" \
        --stats \
        --human-readable \
        --delete-after \
        --progress \
        "$SOURCE_DIR/" "$DEST_DIR/"
fi

echo ""
echo "Setting proper permissions for web server..."

# Set proper permissions for the synced files
# Directories: 755 (rwxr-xr-x) - readable and executable by web server
# Files: 644 (rw-r--r--) - readable by web server
find "$DEST_DIR" -type d -exec chmod 755 {} \;
find "$DEST_DIR" -type f -exec chmod 644 {} \;

# Also fix permissions for parent directories
chmod 755 "$DEST_BASE_DIR" 2>/dev/null || true
chmod 755 "${DEST_BASE_DIR}/${NETWORK}" 2>/dev/null || true
chmod 755 "$DEST_DIR"

echo "Permissions updated successfully!"
echo ""

echo "Sync completed successfully!"
echo ""

# Show what was synced
echo "=== Snapshot directory structure ==="
find "$DEST_DIR" -type d | head -20
if [ $(find "$DEST_DIR" -type d | wc -l) -gt 20 ]; then
    echo "... and more directories"
fi
echo ""

# Show sizes
echo "=== Directory sizes ==="
du -sh "$DEST_DIR"/* 2>/dev/null | head -10 || true
echo ""
echo "Total snapshot size: $(du -sh "$DEST_DIR" | cut -f1)"
echo ""

echo "Snapshot available at: ${DEST_BASE_DIR}/${NETWORK}/${BLOCK_HEIGHT}/"
