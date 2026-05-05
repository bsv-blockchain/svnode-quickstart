#!/bin/bash

# Generic Teranode Seed Creation Script
# Generates Teranode-format UTXO seed (<hash>.utxo-set, <hash>.utxo-headers)
# from a shut-down SV Node data directory using the Teranode Docker image.
# Supports mainnet, testnet, and teratestnet with block height subdirectories.
#
# Pre-flight requirements (LevelDB WAL must be flushed before seeding):
#   https://bsv-blockchain.github.io/teranode/howto/miners/kubernetes/minersHowToSyncTheNode/#optional-ensure-data-consistency

set -e  # Exit on any error

# Pinned Teranode image. Bump deliberately when validated.
TERANODE_IMAGE="ghcr.io/bsv-blockchain/teranode:v0.14.5"

# Parse command line arguments
NETWORK="$1"
SOURCE_DIR="$2"
DEST_BASE_DIR="$3"

# Show usage if parameters missing
if [ -z "$NETWORK" ] || [ -z "$SOURCE_DIR" ] || [ -z "$DEST_BASE_DIR" ]; then
    echo "Error: Missing required parameters"
    echo ""
    echo "Usage: $0 <network> <source_dir> <dest_base_dir>"
    echo ""
    echo "Parameters:"
    echo "  network:       Network type (mainnet, testnet, or teratestnet)"
    echo "  source_dir:    Source SV Node data directory (must be shut down)"
    echo "  dest_base_dir: Base destination directory for seeds"
    echo ""
    echo "Block height and tip hash are derived from bitcoind.log."
    echo ""
    echo "Examples:"
    echo "  $0 mainnet     /mnt/bitcoin-data/bitcoin-data-mainnet     /mnt/bitcoin-data/snapshots"
    echo "  $0 testnet     /mnt/bitcoin-data/bitcoin-data-testnet     /mnt/bitcoin-data/snapshots"
    echo "  $0 teratestnet /mnt/bitcoin-data/bitcoin-data-teratestnet /mnt/bitcoin-data/snapshots"
    exit 1
fi

# Validate network parameter
if [[ "$NETWORK" != "mainnet" ]] && [[ "$NETWORK" != "testnet" ]] && [[ "$NETWORK" != "teratestnet" ]]; then
    echo "Error: Invalid network '$NETWORK'"
    echo "Valid options: mainnet, testnet, teratestnet"
    exit 1
fi

# Check if source directory exists
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Error: Source directory $SOURCE_DIR not found!"
    exit 1
fi

# Determine the bitcoin data root the container should mount.
# Mainnet:     blocks/, chainstate/ live at SOURCE_DIR root.
# Testnet:     same dirs live under testnet3/.
# Teratestnet: same dirs live under teratestnet/.
case "$NETWORK" in
    mainnet)     BITCOIN_SRC="$SOURCE_DIR" ;;
    testnet)     BITCOIN_SRC="${SOURCE_DIR}/testnet3" ;;
    teratestnet) BITCOIN_SRC="${SOURCE_DIR}/teratestnet" ;;
esac

# Validate the expected SV Node layout exists at the resolved path
if [[ ! -d "${BITCOIN_SRC}/blocks" ]] || [[ ! -d "${BITCOIN_SRC}/chainstate" ]]; then
    echo "Error: Expected SV Node layout not found under $BITCOIN_SRC"
    echo "Required subdirectories: blocks/ and chainstate/"
    exit 1
fi

# Validate Docker is available
if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker is not installed or not in PATH"
    exit 1
fi

# bitcoind.log is the sole source of truth for block height + tip hash.
# Log can be many GB — read from the tail (tac/grep -m 1) instead of full scan.
BITCOIND_LOG="${BITCOIN_SRC}/bitcoind.log"
if [[ ! -f "$BITCOIND_LOG" ]]; then
    echo "Error: $BITCOIND_LOG not found"
    echo "Cannot derive block height/hash without it. Aborting."
    exit 1
fi

# Verify the node was shut down gracefully.
# Last non-empty line of bitcoind.log should look like:
#   2026-04-28 17:28:12 [shutoff] Shutdown: done
LAST_LOG_LINE=$(tail -n 50 "$BITCOIND_LOG" | grep -v '^[[:space:]]*$' | tail -n 1 || true)
if ! echo "$LAST_LOG_LINE" | grep -q 'Shutdown: done'; then
    echo "WARNING: bitcoind.log does not end with 'Shutdown: done'."
    echo "Node may not have been shut down gracefully — chainstate could be inconsistent."
    echo "Recommended: run 'bitcoin-cli stop' first, wait for full flush, then re-run."
    echo ""
    echo "Last log line: $LAST_LOG_LINE"
    echo ""
    read -r -p "Continue anyway? [y/N] " CONFIRM
    case "$CONFIRM" in
        [yY]|[yY][eE][sS]) echo "Continuing at user request." ;;
        *) echo "Aborted."; exit 1 ;;
    esac
else
    echo "bitcoind.log ends with: $LAST_LOG_LINE"
fi

# Verify LevelDB WAL files are flushed.
# bitcointoutxoset opens chainstate/ and blocks/index/ read-only — it cannot
# replay the WAL. Unflushed *.log files (multi-MB) hide recent writes and
# trigger "chainstate tip block not found in index" errors.
# See: https://bsv-blockchain.github.io/teranode/howto/miners/kubernetes/minersHowToSyncTheNode/#optional-ensure-data-consistency
WAL_THRESHOLD_BYTES=1024   # 1 KB — sub-kilobyte is the normal empty-WAL state
WAL_DIRS=("${BITCOIN_SRC}/blocks/index" "${BITCOIN_SRC}/chainstate")
LARGE_WALS=()
for dir in "${WAL_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] && LARGE_WALS+=("$f")
        done < <(find "$dir" -maxdepth 1 -name '*.log' -size +"${WAL_THRESHOLD_BYTES}c" 2>/dev/null)
    fi
done
if [[ ${#LARGE_WALS[@]} -gt 0 ]]; then
    echo ""
    echo "WARNING: LevelDB WAL files larger than 1KB detected:"
    ls -lh "${LARGE_WALS[@]}"
    echo ""
    echo "bitcointoutxoset opens these LevelDBs read-only and will NOT replay the WAL."
    echo "Unflushed entries are invisible — seeder can fail with"
    echo "  'chainstate tip block not found in index'."
    echo ""
    echo "Recommended: bounce bitcoind offline to force a WAL seal:"
    echo "  bitcoind -datadir=$SOURCE_DIR -listen=0 -connect=0 -daemon"
    echo "  # wait for 'init message: Done loading' in bitcoind.log"
    echo "  bitcoin-cli -datadir=$SOURCE_DIR stop"
    echo "  # wait for 'Shutdown: done', then re-check WAL sizes"
    echo ""
    echo "Docs: https://bsv-blockchain.github.io/teranode/howto/miners/kubernetes/minersHowToSyncTheNode/#optional-ensure-data-consistency"
    echo ""
    read -r -p "Continue anyway? [y/N] " CONFIRM
    case "$CONFIRM" in
        [yY]|[yY][eE][sS]) echo "Continuing at user request." ;;
        *) echo "Aborted."; exit 1 ;;
    esac
else
    echo "LevelDB WAL files are flushed (all *.log under blocks/index/ and chainstate/ are sub-1KB)."
fi

# Extract last UpdateTip — gives authoritative tip height + hash.
# UpdateTip fires on every accepted block, so the last 10000 log lines are
# guaranteed to contain a recent one. tail seeks from EOF — cheap on huge files.
LAST_TIP_LINE=$(tail -n 10000 "$BITCOIND_LOG" | grep -a 'UpdateTip:' | tail -n 1 || true)
if [[ -z "$LAST_TIP_LINE" ]]; then
    echo "Error: no 'UpdateTip:' line found in $BITCOIND_LOG"
    exit 1
fi

EXPECTED_HASH=$(echo "$LAST_TIP_LINE" | sed -E -n 's/.*best=([0-9a-f]+).*/\1/p')
BLOCK_HEIGHT=$(echo "$LAST_TIP_LINE" | sed -E -n 's/.*height=([0-9]+).*/\1/p')
if [[ -z "$EXPECTED_HASH" ]] || [[ -z "$BLOCK_HEIGHT" ]]; then
    echo "Error: could not parse height/hash from UpdateTip line"
    echo "Line: $LAST_TIP_LINE"
    exit 1
fi
echo "Last UpdateTip: height=$BLOCK_HEIGHT hash=$EXPECTED_HASH"
echo ""

# Construct destination directory with network and height
DEST_DIR="${DEST_BASE_DIR}/${NETWORK}-teranode/${BLOCK_HEIGHT}"

echo "=== Bitcoin ${NETWORK} Teranode Seed Creation ==="
echo "Image: $TERANODE_IMAGE"
echo "Bitcoin source: $BITCOIN_SRC"
echo "Destination: $DEST_DIR"
echo "Block Height: $BLOCK_HEIGHT"
echo "Tip hash:     $EXPECTED_HASH"
echo ""

# Create destination directory if it doesn't exist
mkdir -p "$DEST_DIR"

# Best-effort image pull. If offline / already cached, fall through.
echo "Pulling Teranode image (best-effort)..."
docker pull "$TERANODE_IMAGE" || echo "WARNING: docker pull failed; using local image if available"
echo ""

echo "Running bitcointoutxoset..."
docker run --rm \
    -v "${BITCOIN_SRC}:/bitcoin-data:ro" \
    -v "${DEST_DIR}:/seed" \
    --entrypoint="" \
    "$TERANODE_IMAGE" \
    /app/teranode-cli bitcointoutxoset \
        -bitcoinDir=/bitcoin-data \
        -outputDir=/seed

echo ""
echo "Locating seed output files..."

# Glob for the produced .utxo-set; the basename is the block hash.
shopt -s nullglob
UTXO_SETS=("$DEST_DIR"/*.utxo-set)
shopt -u nullglob

if [[ ${#UTXO_SETS[@]} -eq 0 ]]; then
    echo "Error: no *.utxo-set produced in $DEST_DIR"
    exit 1
fi
if [[ ${#UTXO_SETS[@]} -gt 1 ]]; then
    echo "Error: multiple *.utxo-set files in $DEST_DIR — refusing to guess:"
    printf '  %s\n' "${UTXO_SETS[@]}"
    exit 1
fi

UTXO_SET_FILE="${UTXO_SETS[0]}"
BLOCK_HASH=$(basename "$UTXO_SET_FILE" .utxo-set)
HEADERS_FILE="${DEST_DIR}/${BLOCK_HASH}.utxo-headers"

if [[ ! -f "$HEADERS_FILE" ]]; then
    echo "Error: matching headers file missing: $HEADERS_FILE"
    exit 1
fi

echo "Produced block hash: $BLOCK_HASH"
echo ""

# Cross-check against bitcoind.log tip — must match for cleanly shut-down node.
if [[ "$EXPECTED_HASH" != "$BLOCK_HASH" ]]; then
    echo "Error: produced hash differs from bitcoind.log tip"
    echo "       bitcoind.log: $EXPECTED_HASH"
    echo "       produced    : $BLOCK_HASH"
    echo "       Chainstate is ahead of or behind the log. Investigate before reusing."
    exit 1
fi
echo "Hash matches bitcoind.log tip."
echo ""

echo "Setting proper permissions for web server..."

# Directories: 755, files: 644 — match create_snapshot.sh conventions
find "$DEST_DIR" -type d -exec chmod 755 {} \;
find "$DEST_DIR" -type f -exec chmod 644 {} \;

# Also fix permissions for parent directories
chmod 755 "$DEST_BASE_DIR" 2>/dev/null || true
chmod 755 "${DEST_BASE_DIR}/${NETWORK}-teranode" 2>/dev/null || true
chmod 755 "$DEST_DIR"

echo "Permissions updated successfully!"
echo ""

# Create completion marker file with timestamp + provenance
COMPLETION_FILE="${DEST_DIR}/snapshot_date.txt"
{
    date -u +"%Y-%m-%d %H:%M:%S UTC"
    echo "network: ${NETWORK}"
    echo "height: ${BLOCK_HEIGHT}"
    echo "hash: ${BLOCK_HASH}"
    echo "image: ${TERANODE_IMAGE}"
} > "$COMPLETION_FILE"
chmod 644 "$COMPLETION_FILE"

echo "Seed created successfully!"
echo "Completion marker: $(basename "$COMPLETION_FILE")"
echo ""

# Show what was produced
echo "=== Seed directory contents ==="
ls -lh "$DEST_DIR"
echo ""

# Show sizes
echo "=== File sizes ==="
du -h "$DEST_DIR"/* 2>/dev/null || true
echo ""
echo "Total seed size: $(du -sh "$DEST_DIR" | cut -f1)"
echo ""

echo "Seed available at: ${DEST_BASE_DIR}/${NETWORK}-teranode/${BLOCK_HEIGHT}/"
echo "Completion date: $(head -n 1 "$COMPLETION_FILE")"
