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

# Snapshot sources (these would be real URLs in production)
declare -A SNAPSHOT_URLS=(
    ["mainnet"]="https://download.bitcoinsv.io/snapshots/mainnet-pruned-latest.tar.gz"
    ["testnet"]="https://download.bitcoinsv.io/snapshots/testnet-pruned-latest.tar.gz"
)

declare -A SNAPSHOT_SIZES=(
    ["mainnet"]="160GB"
    ["testnet"]="200GB"
)

check_disk_space() {
    local required_space="$1"
    local available_space=$(df "$DATA_DIR" | awk 'NR==2 {print int($4/1048576)}')
    
    echo_info "Checking available disk space..."
    echo_info "Required: ${required_space}, Available: ${available_space}GB"
    
    if [ "$available_space" -lt "$required_space" ]; then
        echo_error "Insufficient disk space for snapshot download and extraction."
        return 1
    fi
    
    echo_success "Sufficient disk space available."
    return 0
}

download_snapshot() {
    local url="$1"
    local output_file="$2"
    
    echo_info "Downloading snapshot from: $url"
    echo_warning "This may take several hours depending on your connection speed."
    echo ""
    
    # Check if partial download exists
    if [ -f "$output_file" ]; then
        local existing_size=$(stat -c%s "$output_file" 2>/dev/null || stat -f%z "$output_file" 2>/dev/null)
        echo_info "Found partial download ($(numfmt --to=iec $existing_size)). Attempting resume..."
    fi
    
    # Download with resume support and better error handling
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        echo_info "Download attempt $((retry_count + 1)) of $max_retries..."
        
        if command -v wget &> /dev/null; then
            if wget -c --timeout=30 --tries=1 --progress=bar:force -O "$output_file" "$url"; then
                break
            fi
        elif command -v curl &> /dev/null; then
            if curl -C - -L --connect-timeout 30 --max-time 0 --retry 0 -o "$output_file" "$url"; then
                break
            fi
        else
            echo_error "Neither wget nor curl is available."
            return 1
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo_warning "Download failed. Retrying in 10 seconds..."
            sleep 10
        fi
    done
    
    if [ $retry_count -eq $max_retries ]; then
        echo_error "Download failed after $max_retries attempts."
        return 1
    fi
    
    echo_success "Download complete."
    return 0
}

verify_snapshot() {
    local snapshot_file="$1"
    local checksum_url="${snapshot_file%.tar.gz}.tar.gz.sha256"
    
    echo_info "Verifying snapshot integrity..."
    
    # Download checksum file
    local checksum_file="${snapshot_file}.sha256"
    if curl -s -o "$checksum_file" "$checksum_url" 2>/dev/null; then
        if sha256sum -c "$checksum_file" 2>/dev/null; then
            echo_success "Snapshot verified successfully."
            return 0
        else
            echo_error "Snapshot verification failed!"
            return 1
        fi
    else
        echo_warning "Could not download checksum file. Skipping verification."
        echo_warning "This is not recommended for security reasons."
        return 0
    fi
}


extract_snapshot() {
    local snapshot_file="$1"
    local target_dir="$2"
    
    echo_info "Extracting snapshot to $target_dir..."
    echo_warning "This may take 30-60 minutes depending on disk speed."
    echo ""
    
    # For testnet, we need to extract to the testnet3 subdirectory
    local extract_dir="$target_dir"
    if [[ "$NETWORK" == "testnet" ]]; then
        extract_dir="$target_dir/testnet3"
        mkdir -p "$extract_dir"
    fi
    
    # Create extraction progress indicator
    show_extraction_progress() {
        local dir="$1"
        while [ ! -f "${dir}/.extraction_done" ]; do
            if [ -d "$dir" ]; then
                local count=$(find "$dir" -type f 2>/dev/null | wc -l)
                echo -ne "\rFiles extracted: $count"
            fi
            sleep 5
        done
        echo ""
    }
    
    # Start progress indicator
    show_extraction_progress "$extract_dir" &
    local progress_pid=$!
    
    # Extract with progress (handles gzip automatically)
    if ! tar -xzf "$snapshot_file" -C "$extract_dir" --checkpoint=1000 --checkpoint-action=dot; then
        kill $progress_pid 2>/dev/null || true
        echo_error "Failed to extract snapshot."
        return 1
    fi
    
    # Mark extraction as complete
    touch "${extract_dir}/.extraction_done"
    kill $progress_pid 2>/dev/null || true
    wait $progress_pid 2>/dev/null || true
    
    echo ""
    echo_success "Snapshot extracted successfully."
    
    # Clean up extraction marker
    rm -f "${extract_dir}/.extraction_done"
    
    return 0
}

cleanup_snapshot() {
    local snapshot_file="$1"
    
    echo_info "Cleaning up temporary files..."
    rm -f "$snapshot_file" "${snapshot_file}.done" "${snapshot_file}.sha256"
    echo_success "Cleanup complete."
}

download_from_alternative_source() {
    local network="$1"
    local output_file="$2"
    
    echo_info "Checking alternative snapshot sources..."
    
    # List of alternative sources (community mirrors, etc.)
    local alt_sources=(
        "https://mirror1.bsv-snapshots.com/${network}/latest.tar.gz"
        "https://mirror2.bsv-snapshots.com/${network}/latest.tar.gz"
        "torrent:magnet:?xt=urn:btih:HASH_HERE"
    )
    
    for source in "${alt_sources[@]}"; do
        echo_info "Trying: $source"
        
        if [[ "$source" == torrent:* ]]; then
            # Handle torrent downloads
            echo_info "Torrent download support not yet implemented."
            continue
        fi
        
        if curl --head --silent --fail "$source" 2>/dev/null; then
            echo_success "Found working mirror: $source"
            download_snapshot "$source" "$output_file"
            return $?
        fi
    done
    
    echo_error "No working snapshot sources found."
    return 1
}

interactive_snapshot_selection() {
    local network="$1"
    
    echo_yellow "Select snapshot source:"
    echo "  1. Official BSV snapshot (recommended)"
    echo "  2. Community mirror #1"
    echo "  3. Community mirror #2"
    echo "  4. Skip snapshot (sync from genesis)"
    echo ""
    
    read -p "$(echo_yellow "Enter choice [1-4]: ")" choice
    
    case $choice in
        1|2|3)
            echo_info "Selected snapshot source #$choice"
            return 0
            ;;
        4)
            echo_info "Skipping snapshot download. Will sync from genesis."
            return 1
            ;;
        *)
            echo_error "Invalid choice."
            return 1
            ;;
    esac
}

estimate_sync_time() {
    local network="$1"
    local method="$2"
    
    echo ""
    echo_info "Estimated sync times for $network:"
    
    if [[ "$method" == "snapshot" ]]; then
        echo "  Download: 2-8 hours (depends on connection speed)"
        echo "  Extraction: 30-60 minutes"
        echo "  Validation: 1-2 hours"
        echo "  Total: 4-12 hours"
    else
        echo "  Initial sync from genesis: 3-7 days"
        echo "  (Highly dependent on network speed and peer availability)"
    fi
    echo ""
}

main() {
    echo_green "=== Blockchain Snapshot Download ==="
    echo ""
    
    # Check if snapshot URL exists for network
    if [[ ! "${SNAPSHOT_URLS[$NETWORK]}" ]]; then
        echo_warning "No snapshot available for network: $NETWORK"
        echo_info "The node will sync from the genesis block."
        return 0
    fi
    
    local snapshot_url="${SNAPSHOT_URLS[$NETWORK]}"
    local snapshot_size="${SNAPSHOT_SIZES[$NETWORK]}"
    local downloads_dir="$(dirname "$SCRIPT_DIR")/downloads"
    mkdir -p "$downloads_dir"
    local snapshot_file="${downloads_dir}/${NETWORK}-snapshot.tar.gz"
    
    echo_info "Network: $NETWORK"
    echo_info "Estimated snapshot size: $snapshot_size"
    echo_info "Target directory: $DATA_DIR"
    echo ""
    
    # Estimate sync time
    estimate_sync_time "$NETWORK" "snapshot"
    
    # Ask for confirmation
    echo_yellow "Download and extract blockchain snapshot?"
    echo_yellow "This will speed up initial sync significantly."
    read -p "$(echo_yellow "Continue? [Y/n]: ")" response
    response=${response:-Y}
    
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo_info "Skipping snapshot download."
        echo_info "The node will sync from the genesis block."
        estimate_sync_time "$NETWORK" "genesis"
        return 0
    fi
    
    # Check disk space (download + extraction requires 2x space)
    local required_space=350  # GB for mainnet (160GB snapshot + 160GB extracted + buffer)
    [[ "$NETWORK" == "testnet" ]] && required_space=500  # 200GB snapshot + 300GB extracted
    
    echo_info "Snapshot will be downloaded and then extracted."
    echo_info "This requires temporary space for both the download and extracted data.""
    
    if ! check_disk_space "$required_space"; then
        echo_error "Insufficient disk space for snapshot."
        return 1
    fi
    
    # Ensure downloads directory exists
    mkdir -p "$downloads_dir"
    
    # Download snapshot
    echo ""
    if ! download_snapshot "$snapshot_url" "$snapshot_file"; then
        echo_warning "Failed to download from primary source."
        
        # Try alternative sources
        if ! download_from_alternative_source "$NETWORK" "$snapshot_file"; then
            echo_error "Could not download snapshot from any source."
            echo_info "The node will sync from the genesis block instead."
            return 0
        fi
    fi
    
    # Verify snapshot if downloaded
    echo ""
    verify_snapshot "$snapshot_file"
    
    # Extract snapshot
    echo ""
    if ! extract_snapshot "$snapshot_file" "$DATA_DIR"; then
        echo_error "Failed to extract snapshot."
        cleanup_snapshot "$snapshot_file"
        return 1
    fi
    
    # Clean up downloaded file
    cleanup_snapshot "$snapshot_file"
    
    # Set proper permissions
    echo_info "Setting permissions..."
    chmod -R 755 "$DATA_DIR" 2>/dev/null || true
    
    echo ""
    echo_green "=== Snapshot Setup Complete ==="
    echo_info "The blockchain data has been extracted to: $DATA_DIR"
    echo_info "When you start the node, it will validate the data and continue syncing."
    echo_warning "Initial validation may take 1-2 hours."
    echo ""
    
    return 0
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi