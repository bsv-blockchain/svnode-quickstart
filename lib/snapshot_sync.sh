#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/colors.sh"

NETWORK="$1"
DATA_DIR="$2"

# Check required parameters
if [ -z "$NETWORK" ] || [ -z "$DATA_DIR" ]; then
    echo_error "Missing required parameters"
    echo_info "Usage: $0 <network> <data_dir>"
    echo_info "  network: mainnet, testnet, or regtest"
    echo_info "  data_dir: Path to data directory (e.g., ./bsv-data)"
    echo_info ""
    echo_info "Example: $0 mainnet ./bsv-data"
    exit 1
fi

# Snapshot base URL
SNAPSHOT_BASE_URL="https://svnode-snapshots.bsvb.tech"

# Snapshot sizes (approximate)
declare -A SNAPSHOT_SIZES=(
    ["mainnet"]="160GB"
    ["testnet"]="200GB"
)

check_disk_space() {
    local required_space="$1"
    local available_space=$(df "$DATA_DIR" | awk 'NR==2 {print int($4/1048576)}')

    echo_info "Checking available disk space..."
    echo_info "Required: ${required_space}GB, Available: ${available_space}GB"

    if [ "$available_space" -lt "$required_space" ]; then
        echo_error "Insufficient disk space for snapshot sync."
        return 1
    fi

    echo_success "Sufficient disk space available."
    return 0
}

check_existing_data() {
    local data_dir="$1"
    local network="$2"

    # Check for existing blockchain data
    local target_dir="$data_dir"
    if [[ "$network" == "testnet" ]]; then
        target_dir="$data_dir/testnet3"
    elif [[ "$network" == "regtest" ]]; then
        target_dir="$data_dir/regtest"
    fi

    if [ -d "$target_dir/blocks" ] && [ "$(ls -A "$target_dir/blocks" 2>/dev/null | wc -l)" -gt 0 ]; then
        echo_info "Found existing blockchain data in $target_dir"
        echo_yellow "This will update your existing data with the latest snapshot."
        echo_yellow "New and updated files will be downloaded."
        echo ""
        return 0
    fi

    return 1
}

install_rclone() {
    echo_warning "rclone is required for snapshot sync but is not installed."
    echo_info "rclone can be installed automatically using the official installer:"
    echo_info "  curl https://rclone.org/install.sh | sudo bash"
    echo ""

    read -p "$(echo_yellow "Install rclone automatically? [y/N]: ")" response
    response=${response:-N}

    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo_info "Skipping rclone installation."
        echo_info "Please install rclone manually and run the sync again:"
        echo_info "  curl https://rclone.org/install.sh | sudo bash"
        return 1
    fi

    echo_info "Installing rclone..."
    if command -v sudo &> /dev/null; then
        if curl -s https://rclone.org/install.sh | sudo bash; then
            echo_success "rclone installed successfully."
            return 0
        else
            echo_error "Failed to install rclone automatically."
            echo_info "Please install rclone manually:"
            echo_info "  curl https://rclone.org/install.sh | sudo bash"
            return 1
        fi
    else
        echo_error "sudo not available. Please install rclone manually:"
        echo_info "  curl https://rclone.org/install.sh | bash"
        return 1
    fi
}

check_snapshot_complete() {
    local network="$1"
    local height="$2"
    local check_url="${SNAPSHOT_BASE_URL}/${network}/${height}/snapshot_date.txt"
    
    # Use curl to check if completion marker exists (HTTP 200 = complete)
    if curl --head --silent --fail "${check_url}" >/dev/null 2>&1; then
        return 0  # Snapshot is complete
    else
        return 1  # Snapshot is incomplete or in progress
    fi
}

get_latest_snapshot_height() {
    local network="$1"
    local network_url="${SNAPSHOT_BASE_URL}/${network}/"

    echo_info "Finding latest completed snapshot for ${network}..." >&2

    # List the network directory to find available heights
    local heights_list
    if ! heights_list=$(rclone lsf ":http:" --http-url "${network_url}" 2>/dev/null); then
        echo_error "Failed to list available snapshots for ${network}" >&2
        return 1
    fi

    # Extract heights and sort them in descending order
    local heights_array=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^([0-9]+)/$ ]]; then
            heights_array+=("${BASH_REMATCH[1]}")
        fi
    done <<< "$heights_list"
    
    # Sort heights in descending order
    IFS=$'\n' sorted_heights=($(sort -rn <<<"${heights_array[*]}"))
    unset IFS
    
    # Check each height starting from the latest to find a completed snapshot
    local valid_height=0
    for height in "${sorted_heights[@]}"; do
        echo_info "Checking snapshot at height ${height}..." >&2
        if check_snapshot_complete "$network" "$height"; then
            echo_info "Found completed snapshot at height ${height}" >&2
            valid_height="$height"
            break
        else
            echo_warning "Snapshot at height ${height} is incomplete or in progress, skipping..." >&2
        fi
    done
    
    if [[ "$valid_height" -eq 0 ]]; then
        echo_error "No completed snapshots found for ${network}" >&2
        return 1
    fi

    echo "$valid_height"
    return 0
}

sync_snapshot() {
    local network="$1"
    local data_dir="$2"

    # Check if rclone is available, install if needed (before using it)
    if ! command -v rclone &> /dev/null; then
        if ! install_rclone; then
            echo_error "Cannot proceed without rclone."
            return 1
        fi
    fi

    # Get the latest snapshot height (now that rclone is available)
    local snapshot_height
    if ! snapshot_height=$(get_latest_snapshot_height "$network"); then
        echo_error "Cannot determine latest snapshot height"
        return 1
    fi

    local base_url="${SNAPSHOT_BASE_URL}/${network}/${snapshot_height}/"

    echo_info "Syncing ${network} snapshot from: ${base_url}"
    echo_info "Snapshot height: ${snapshot_height}"
    echo_info "Destination: ${data_dir}"
    echo_warning "This may take several hours depending on your connection speed."
    echo ""

    # Determine if this is an update
    if check_existing_data "$data_dir" "$network"; then
        echo_info "Updating existing blockchain data..."
    else
        echo_info "Performing initial blockchain sync..."
    fi

    echo_info "Starting rclone sync with progress display..."
    echo_info "Source: ${base_url}"
    echo ""

    # Use rclone sync with HTTP backend
    # Use --http-url parameter with :http: remote

    if ! rclone sync ":http:" "${data_dir}" \
                    --http-url "${base_url}" \
                    --progress \
                    --transfers 4 \
                    --checkers 8 \
                    --retries 3 \
                    --low-level-retries 3 \
                    --timeout 30s \
                    --contimeout 10s \
                    --filter "+ blocks/**" \
                    --filter "+ chainstate/**" \
                    --filter "+ frozentxos/**" \
                    --filter "+ merkle/**" \
                    --filter "+ testnet3/" \
                    --filter "+ testnet3/blocks/**" \
                    --filter "+ testnet3/chainstate/**" \
                    --filter "+ testnet3/frozentxos/**" \
                    --filter "+ testnet3/merkle/**" \
                    --filter "- *"; then
        echo_error "rclone sync failed."
        return 1
    fi

    echo ""
    echo_success "Snapshot sync completed successfully."
    return 0
}

# rclone handles orphan cleanup automatically with sync command
# No separate cleanup function needed

verify_sync() {
    local data_dir="$1"
    local network="$2"

    echo_info "Verifying synced data..."

    # Check for essential directories
    local target_dir="$data_dir"
    if [[ "$network" == "testnet" ]]; then
        target_dir="$data_dir/testnet3"
    elif [[ "$network" == "regtest" ]]; then
        echo_info "Regtest doesn't use snapshots."
        return 0
    fi

    local required_dirs=("blocks" "chainstate")
    local missing_dirs=()

    for dir in "${required_dirs[@]}"; do
        if [ ! -d "$target_dir/$dir" ] || [ -z "$(ls -A "$target_dir/$dir" 2>/dev/null)" ]; then
            missing_dirs+=("$dir")
        fi
    done

    if [ ${#missing_dirs[@]} -gt 0 ]; then
        echo_error "Missing or empty directories: ${missing_dirs[*]}"
        echo_error "Snapshot sync may have been incomplete."
        return 1
    fi

    echo_success "Verification passed. Essential directories are present."
    return 0
}

main() {
    echo_green "=== Blockchain Snapshot Sync ==="
    echo ""

    # Check if network supports snapshots
    if [[ "$NETWORK" == "regtest" ]]; then
        echo_info "Regtest network doesn't use snapshots."
        echo_info "The node will generate blocks locally."
        return 0
    fi

    # Check if snapshot is available for the network
    local snapshot_url="${SNAPSHOT_BASE_URL}/${NETWORK}/"
    local snapshot_size="${SNAPSHOT_SIZES[$NETWORK]:-Unknown}"

    echo_info "Network: $NETWORK"
    echo_info "Estimated snapshot size: $snapshot_size"
    echo_info "Target directory: $DATA_DIR"
    echo ""

    # Ask for confirmation
    echo_yellow "Sync blockchain snapshot from the server?"
    echo_yellow "This will download blockchain data to speed up initial sync."
    read -p "$(echo_yellow "Continue? [Y/n]: ")" response
    response=${response:-Y}

    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo_info "Skipping snapshot sync."
        echo_info "The node will sync from the genesis block."
        return 0
    fi

    # Check disk space
    local required_space=200  # GB for mainnet
    [[ "$NETWORK" == "testnet" ]] && required_space=30  # GB for testnet (full node)

    echo_info "Checking disk space requirements..."

    if ! check_disk_space "$required_space"; then
        echo_error "Insufficient disk space for snapshot."
        return 1
    fi

    # Sync the snapshot
    echo ""
    if ! sync_snapshot "$NETWORK" "$DATA_DIR"; then
        echo_error "Failed to sync snapshot."
        echo_info "The node will sync from the genesis block instead."
        return 0
    fi

    # Verify the synced data
    echo ""
    if ! verify_sync "$DATA_DIR" "$NETWORK"; then
        echo_warning "Verification failed, but you can try starting the node anyway."
        echo_warning "The node will re-download any missing or corrupted files."
    fi

    # Set proper permissions
    echo_info "Setting permissions..."
    chmod -R 755 "$DATA_DIR" 2>/dev/null || true

    echo ""
    echo_green "=== Snapshot Sync Complete ==="
    echo_info "The blockchain data has been synced to: $DATA_DIR"
    echo_info "When you start the node, it will validate the data and continue syncing."
    echo_warning "Initial validation may take 30-60 minutes."
    echo_info "The node automatically verifies blockchain integrity on startup."
    echo_info "For additional verification, you can run: ./cli.sh verifychain"
    echo ""

    return 0
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi
