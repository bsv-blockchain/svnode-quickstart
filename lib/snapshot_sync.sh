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

# Snapshots are published by the BSV Association to public, S3-compatible
# object storage (OVHcloud):
#   <network>/latest.json                          height, file, bytes, sha256
#   <network>/<height>/svnode-<network>-<height>.tar.gz(.sha256)
#   <network>/<height>/snapshot_date.txt           written last: completion marker
# Override for testing: SNAPSHOT_BASE_URL=http://... ./lib/snapshot_sync.sh ...
SNAPSHOT_BASE_URL="${SNAPSHOT_BASE_URL:-https://bsva-svnode-snapshots.s3.gra.io.cloud.ovh.net}"

# Unpacked snapshot sizes (approximate) and the free space needed to unpack.
# The archive is streamed and unpacked on the fly, so it never sits on disk.
declare -A SNAPSHOT_SIZES=(
    ["mainnet"]="~600GB"
    ["testnet"]="~30GB"
)
declare -A SNAPSHOT_SPACE_GB=(
    ["mainnet"]=650
    ["testnet"]=35
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

# Directory the snapshot folders belong in for a network.
network_dir() {
    local data_dir="$1"
    local network="$2"
    case "$network" in
        testnet) echo "$data_dir/testnet3" ;;
        regtest) echo "$data_dir/regtest" ;;
        *)       echo "$data_dir" ;;
    esac
}

check_existing_data() {
    local data_dir="$1"
    local network="$2"
    local target_dir
    target_dir=$(network_dir "$data_dir" "$network")

    if [ -d "$target_dir/blocks" ] && [ "$(ls -A "$target_dir/blocks" 2>/dev/null | wc -l)" -gt 0 ]; then
        echo_info "Found existing blockchain data in $target_dir"
        echo_yellow "It will be replaced by the snapshot once the download has been verified."
        echo ""
        return 0
    fi

    return 1
}

check_snapshot_complete() {
    local network="$1"
    local height="$2"
    local check_url="${SNAPSHOT_BASE_URL}/${network}/${height}/snapshot_date.txt"

    # The completion marker is written last; HTTP 200 means the snapshot is complete.
    if curl --head --silent --fail "${check_url}" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# json_field JSON KEY: the value of a flat string or number field.
json_field() {
    local json="$1"
    local key="$2"
    if [[ "$json" =~ \"$key\":\"([^\"]*)\" ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$json" =~ \"$key\":([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# Reads <network>/latest.json into SNAP_HEIGHT, SNAP_FILE, SNAP_BYTES,
# SNAP_SHA256 and SNAP_CREATED, and checks the snapshot is complete.
fetch_latest_info() {
    local network="$1"
    local json

    echo_info "Finding the latest snapshot for ${network}..." >&2
    if ! json=$(curl --silent --show-error --fail --retry 3 "${SNAPSHOT_BASE_URL}/${network}/latest.json" 2>/dev/null); then
        echo_error "No snapshot is published for ${network}" >&2
        return 1
    fi

    SNAP_HEIGHT=$(json_field "$json" height)
    SNAP_FILE=$(json_field "$json" file)
    SNAP_BYTES=$(json_field "$json" bytes)
    SNAP_SHA256=$(json_field "$json" sha256)
    SNAP_CREATED=$(json_field "$json" created)

    if [[ ! "$SNAP_HEIGHT" =~ ^[0-9]+$ || -z "$SNAP_FILE" || ! "$SNAP_BYTES" =~ ^[0-9]+$ || ! "$SNAP_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
        echo_error "The snapshot information for ${network} is incomplete" >&2
        return 1
    fi

    if ! check_snapshot_complete "$network" "$SNAP_HEIGHT"; then
        echo_error "The snapshot at height ${SNAP_HEIGHT} is not complete yet" >&2
        return 1
    fi

    echo_info "Latest snapshot: height ${SNAP_HEIGHT}, created ${SNAP_CREATED:-unknown}" >&2
    return 0
}

# fetch_resumable URL TOTAL_BYTES ERRFILE: writes the object to stdout. When a
# connection drops mid-download it continues with an HTTP Range request from
# the last byte received, so one long stream survives network hiccups. Bytes
# are only ever appended in order; the checksum over the whole stream catches
# anything that still goes wrong.
fetch_resumable() {
    local url="$1"
    local total="$2"
    local errfile="$3"
    local offset=0
    local attempt=0
    local got

    while (( offset < total )); do
        attempt=$((attempt + 1))
        if (( attempt > 10 )); then
            echo_error "Giving up after 10 attempts at byte ${offset} of ${total}." >&2
            return 1
        fi
        if (( attempt > 1 )); then
            echo_warning "Connection dropped. Resuming at byte ${offset} of ${total} (attempt ${attempt})..." >&2
            sleep 2
        fi
        # %{stderr} sends the -w output to stderr, after any error message.
        curl --silent --show-error --fail --range "${offset}-" \
             --write-out '%{stderr}bytes=%{size_download}\n' "$url" 2>"$errfile"
        got=$(grep -oE '^bytes=[0-9]+' "$errfile" | tail -1 | cut -d= -f2)
        grep -v '^bytes=' "$errfile" >&2 || true
        offset=$(( offset + ${got:-0} ))
    done
    return 0
}

# Streams the archive once: curl | tee (into sha256sum) | gunzip | tar. It
# unpacks into a staging directory and only replaces the node's folders after
# the checksum matches, so a failed or corrupt download leaves the data as it was.
sync_snapshot() {
    local network="$1"
    local data_dir="$2"

    if ! fetch_latest_info "$network"; then
        echo_error "Cannot determine the latest snapshot"
        return 1
    fi

    local target_dir
    target_dir=$(network_dir "$data_dir" "$network")
    local url="${SNAPSHOT_BASE_URL}/${network}/${SNAP_HEIGHT}/${SNAP_FILE}"
    local staging="${data_dir}/.snapshot-staging"
    local size_gb=$(( ${SNAP_BYTES:-0} / 1000000000 ))

    echo_info "Downloading ${network} snapshot: ${url}"
    echo_info "Snapshot height: ${SNAP_HEIGHT}, download size: ~${size_gb}GB"
    echo_info "Destination: ${target_dir}"
    echo_warning "This may take a while depending on your connection speed."
    echo ""

    if check_existing_data "$data_dir" "$network"; then
        echo_info "Updating existing blockchain data..."
    else
        echo_info "Performing initial blockchain sync..."
    fi

    local unpack="gzip -dc"
    command -v pigz &> /dev/null && unpack="pigz -dc"

    rm -rf "$staging"
    mkdir -p "$staging" "$target_dir"
    mkfifo "$staging/.sha256.fifo"
    sha256sum < "$staging/.sha256.fifo" | cut -c1-64 > "$staging/.sha256" &
    local sha_pid=$!

    # Progress: report the downloaded share every minute while it runs.
    local progress_pid=""
    if [ -t 1 ]; then
        ( while sleep 60; do
              local done_bytes
              done_bytes=$(du -sb "$staging" 2>/dev/null | cut -f1)
              echo_info "Unpacked so far: $(( ${done_bytes:-0} / 1000000000 ))GB"
          done ) &
        progress_pid=$!
    fi

    local ok=true
    if ! (set -o pipefail
          fetch_resumable "$url" "${SNAP_BYTES:-0}" "$staging/.curl.err" \
            | tee "$staging/.sha256.fifo" \
            | $unpack \
            | tar -xf - -C "$staging"); then
        ok=false
    fi
    [ -n "$progress_pid" ] && kill "$progress_pid" 2>/dev/null
    wait "$sha_pid" || true
    local got
    got=$(cat "$staging/.sha256" 2>/dev/null)

    if ! $ok; then
        echo_error "Download or extraction failed."
        rm -rf "$staging"
        return 1
    fi
    if [[ "$got" != "$SNAP_SHA256" ]]; then
        echo_error "Checksum mismatch: expected ${SNAP_SHA256}, got ${got:-none}."
        rm -rf "$staging"
        return 1
    fi
    if [ ! -d "$staging/blocks" ] || [ ! -d "$staging/chainstate" ]; then
        echo_error "The snapshot does not contain blocks and chainstate."
        rm -rf "$staging"
        return 1
    fi
    echo_success "Checksum verified."

    # Replace, not merge: files left over from older data must not mix in.
    local dir
    for dir in blocks chainstate frozentxos merkle; do
        if [ -d "$staging/$dir" ]; then
            rm -rf "${target_dir:?}/$dir"
            mv "$staging/$dir" "$target_dir/$dir"
        fi
    done
    rm -rf "$staging"

    echo ""
    echo_success "Snapshot download completed successfully."
    return 0
}

verify_sync() {
    local data_dir="$1"
    local network="$2"

    echo_info "Verifying synced data..."

    if [[ "$network" == "regtest" ]]; then
        echo_info "Regtest doesn't use snapshots."
        return 0
    fi
    local target_dir
    target_dir=$(network_dir "$data_dir" "$network")

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

    local snapshot_size="${SNAPSHOT_SIZES[$NETWORK]:-Unknown}"

    echo_info "Network: $NETWORK"
    echo_info "Source: ${SNAPSHOT_BASE_URL}/${NETWORK}/"
    echo_info "Estimated size once unpacked: $snapshot_size"
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

    # Check disk space (the archive is unpacked as it streams, so only the
    # unpacked size is needed)
    local required_space="${SNAPSHOT_SPACE_GB[$NETWORK]:-650}"

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
