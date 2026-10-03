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
    if [[ "$json" =~ \"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$json" =~ \"$key\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
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

    if [[ ! "$SNAP_HEIGHT" =~ ^[0-9]+$ || "$SNAP_FILE" != "svnode-${network}-${SNAP_HEIGHT}.tar.gz" \
          || ! "$SNAP_BYTES" =~ ^[1-9][0-9]*$ || ! "$SNAP_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
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

SNAPSHOT_FOLDERS=(blocks chainstate frozentxos merkle)

# Download tuning; overridable for tests.
RESUME_DELAY="${RESUME_DELAY:-2}"                 # seconds between resume attempts
STALL_SECONDS="${STALL_SECONDS:-60}"              # below 1KB/s for this long = stalled
MAX_TRIES_WITHOUT_PROGRESS="${MAX_TRIES_WITHOUT_PROGRESS:-5}"

# fetch_resumable URL TOTAL_BYTES CTL_DIR: writes the object to stdout. When a
# connection drops or stalls mid-download it continues with an HTTP Range
# request from the last byte received, so one long stream survives network
# hiccups. Bytes are only ever appended in order, a resumed response must be
# 206, and the checksum over the whole stream catches anything that still goes
# wrong. Errors that a retry cannot fix (HTTP 4xx, a failed write because the
# unpacking side died, e.g. a full disk) stop at once.
fetch_resumable() {
    local url="$1"
    local total="$2"
    local ctl="$3"
    local offset=0
    local stuck=0
    local rc code got

    while (( offset < total )); do
        if (( offset > 0 || stuck > 0 )); then
            echo_warning "Connection dropped. Resuming at byte ${offset} of ${total}..." >&2
            sleep "$RESUME_DELAY"
        fi
        # Body to fd 3 (the pipeline), transfer stats to a file: works with any curl.
        rc=0
        curl --silent --show-error --fail --globoff \
             --connect-timeout 30 --speed-limit 1024 --speed-time "$STALL_SECONDS" \
             --range "${offset}-$(( total - 1 ))" \
             --output /dev/fd/3 --write-out '%{http_code} %{size_download}' \
             "$url" 3>&1 >"$ctl/curl.out" 2>"$ctl/curl.err" || rc=$?
        code=000; got=0
        read -r code got < "$ctl/curl.out" || true
        cat "$ctl/curl.err" >&2

        # A resumed request answered with anything but 206 would restart the
        # body from byte 0 and corrupt the stream.
        if (( offset > 0 )) && [[ "$code" != 206 && "$code" != 000 ]]; then
            echo_error "The server did not resume at byte ${offset} (HTTP ${code})." >&2
            return 1
        fi
        case "$rc" in
            0|7|18|28|35|52|55|56|92) ;;   # done, or a transient network failure
            22)
                if [[ "$code" != 5* ]]; then
                    echo_error "Download failed: HTTP ${code}." >&2
                    return 1
                fi ;;
            23)
                echo_error "Writing the download failed (is the disk full?)." >&2
                return 1 ;;
            *)
                echo_error "Download failed (curl error ${rc})." >&2
                return 1 ;;
        esac

        offset=$(( offset + got ))
        if (( got > 0 )); then
            stuck=0
        else
            stuck=$(( stuck + 1 ))
            if (( stuck >= MAX_TRIES_WITHOUT_PROGRESS )); then
                echo_error "No progress after ${stuck} attempts at byte ${offset} of ${total}." >&2
                return 1
            fi
        fi
    done
    return 0
}

# kill_tree PID: stop a process and everything it started.
kill_tree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        kill_tree "$child"
    done
    kill "$1" 2>/dev/null || true
}

# check_contents STAGING: only the four snapshot folders, as real directories,
# holding only regular files and directories, nothing setuid or setgid.
check_contents() {
    local staging="$1"
    local entry name
    shopt -s dotglob nullglob
    for entry in "$staging"/*; do
        name=$(basename "$entry")
        case " ${SNAPSHOT_FOLDERS[*]} " in
            *" $name "*) ;;
            *) shopt -u dotglob nullglob; return 1 ;;
        esac
        if [ -L "$entry" ] || [ ! -d "$entry" ]; then
            shopt -u dotglob nullglob
            return 1
        fi
    done
    shopt -u dotglob nullglob
    [ -d "$staging/blocks" ] && [ -d "$staging/chainstate" ] || return 1
    [ -z "$(find "$staging" \( \( ! -type f ! -type d \) -o -perm /6000 \) -print -quit)" ]
}

# prepare_data_dir DATA_DIR NETWORK: clear leftovers of an interrupted run.
# .snapshot-staging is always disposable. .snapshot-previous holds the data a
# swap moved aside; markers record how far the swap got, so a recovery never
# mixes old and new folders.
prepare_data_dir() {
    local data_dir="$1"
    local network="$2"
    local target prev d
    target=$(network_dir "$data_dir" "$network")
    prev="${data_dir}/.snapshot-previous"

    rm -rf "${data_dir:?}/.snapshot-staging"
    [ -d "$prev" ] || return 0

    if [ -e "$prev/.complete" ]; then
        :   # the new snapshot is fully in place; the old copy can go
    elif [ -e "$prev/.moving-in" ]; then
        echo_warning "A previous snapshot swap was interrupted; restoring the old data." >&2
        mkdir -p "$target"
        for d in "${SNAPSHOT_FOLDERS[@]}"; do
            rm -rf "${target:?}/$d"
            if [ -e "$prev/$d" ]; then
                mv "$prev/$d" "$target/$d" || return 1
            fi
        done
    else
        echo_warning "A previous snapshot swap was interrupted; restoring the old data." >&2
        mkdir -p "$target"
        for d in "${SNAPSHOT_FOLDERS[@]}"; do
            if [ -e "$prev/$d" ] && [ ! -e "$target/$d" ]; then
                mv "$prev/$d" "$target/$d" || return 1
            fi
        done
    fi
    rm -rf "$prev"
}

# swap_in STAGING TARGET DATA_DIR: replace all four folders with the verified
# ones. Old folders are moved aside first; any failure puts them back.
swap_in() {
    local staging="$1"
    local target="$2"
    local prev="${3}/.snapshot-previous"
    local d

    rm -rf "$prev" && mkdir -p "$prev" || return 1
    for d in "${SNAPSHOT_FOLDERS[@]}"; do
        if [ -e "$target/$d" ] || [ -L "$target/$d" ]; then
            if ! mv "$target/$d" "$prev/$d"; then
                prepare_data_dir "$3" "$SWAP_NETWORK"
                return 1
            fi
        fi
    done
    touch "$prev/.moving-in"
    for d in "${SNAPSHOT_FOLDERS[@]}"; do
        if [ -d "$staging/$d" ]; then
            if ! mv "$staging/$d" "$target/$d"; then
                echo_error "Could not move the new ${d} into place; restoring the old data."
                prepare_data_dir "$3" "$SWAP_NETWORK"
                return 1
            fi
        fi
    done
    touch "$prev/.complete"
    rm -rf "$prev" || echo_warning "Could not remove ${prev}; it holds the replaced data and can be deleted."
    return 0
}

# State for the INT/TERM handler of sync_snapshot.
SNAP_STAGING=""
SNAP_CTL=""
SNAP_PIDS=()

snapshot_cleanup() {
    local pid
    for pid in "${SNAP_PIDS[@]}"; do
        kill_tree "$pid"
    done
    SNAP_PIDS=()
    [ -n "$SNAP_STAGING" ] && rm -rf "$SNAP_STAGING"
    [ -n "$SNAP_CTL" ] && rm -rf "$SNAP_CTL"
    SNAP_STAGING=""
    SNAP_CTL=""
}

snapshot_interrupted() {
    trap - INT TERM
    snapshot_cleanup
    echo "" >&2
    echo_error "Snapshot sync interrupted; nothing was changed." >&2
    exit 130
}

# Streams the archive once: curl | tee (into sha256sum) | gunzip | tar. It
# unpacks into a staging directory and only replaces the node's folders after
# the checksum matches and the content checks out, so a failed, interrupted or
# corrupt download leaves the data as it was.
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
    local size_gb=$(( 10#${SNAP_BYTES} / 1000000000 ))

    echo_info "Downloading ${network} snapshot: ${url}"
    echo_info "Snapshot height: ${SNAP_HEIGHT}, download size: ~${size_gb}GB"
    echo_info "Destination: ${target_dir}"
    echo_warning "This may take a while depending on your connection speed."
    echo ""

    if check_existing_data "$data_dir" "$network"; then
        echo_info "The existing data stays in place until the new snapshot is verified."
    else
        echo_info "Performing initial blockchain sync..."
    fi

    prepare_data_dir "$data_dir" "$network" || return 1

    local unpack="gzip -dc"
    command -v pigz &> /dev/null && unpack="pigz -dc"

    # Control files (FIFO, checksum, curl output) live outside the directory
    # tar writes into, so the archive cannot overwrite them.
    local ctl
    if ! ctl=$(mktemp -d) || ! mkfifo "$ctl/sha256.fifo"; then
        echo_error "Could not create a temporary directory with a FIFO."
        [ -n "${ctl:-}" ] && rm -rf "$ctl"
        return 1
    fi
    if ! mkdir -p "$staging" "$target_dir"; then
        rm -rf "$ctl"
        return 1
    fi
    SNAP_STAGING="$staging"
    SNAP_CTL="$ctl"
    SNAP_PIDS=()
    trap snapshot_interrupted INT TERM

    sha256sum < "$ctl/sha256.fifo" > "$ctl/sha256" &
    local sha_pid=$!
    SNAP_PIDS+=("$sha_pid")

    # Progress: report the unpacked size every minute while it runs.
    local progress_pid=""
    if [ -t 1 ]; then
        ( while sleep 60; do
              done_bytes=$(du -sb "$staging" 2>/dev/null | cut -f1)
              echo_info "Unpacked so far: $(( ${done_bytes:-0} / 1000000000 ))GB"
          done ) &
        progress_pid=$!
        SNAP_PIDS+=("$progress_pid")
    fi

    # Run in the background and wait, so INT/TERM are handled at once.
    ( set -o pipefail
      fetch_resumable "$url" "$SNAP_BYTES" "$ctl" \
        | tee "$ctl/sha256.fifo" \
        | $unpack \
        | tar -x --no-same-owner --no-same-permissions -f - -C "$staging" ) &
    local pipe_pid=$!
    SNAP_PIDS+=("$pipe_pid")
    local ok=true
    wait "$pipe_pid" || ok=false

    [ -n "$progress_pid" ] && kill_tree "$progress_pid"
    if $ok; then
        wait "$sha_pid" || ok=false
    else
        kill_tree "$sha_pid"
    fi
    local got
    got=$(cut -c1-64 "$ctl/sha256" 2>/dev/null)

    local result=1
    if ! $ok; then
        echo_error "Download or extraction failed."
    elif [[ "$got" != "$SNAP_SHA256" ]]; then
        echo_error "Checksum mismatch: expected ${SNAP_SHA256}, got ${got:-none}."
    elif ! check_contents "$staging"; then
        echo_error "The snapshot has unexpected content; it was not used."
    else
        echo_success "Checksum verified."
        SWAP_NETWORK="$network"
        if swap_in "$staging" "$target_dir" "$data_dir"; then
            result=0
        fi
    fi

    trap - INT TERM
    snapshot_cleanup
    if (( result == 0 )); then
        echo ""
        echo_success "Snapshot download completed successfully."
    fi
    return $result
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

    # Leftovers of an interrupted run would otherwise count against free space.
    prepare_data_dir "$DATA_DIR" "$NETWORK" || true

    echo_info "Checking disk space requirements..."

    if ! check_disk_space "$required_space"; then
        echo_error "Insufficient disk space for snapshot."
        if check_existing_data "$DATA_DIR" "$NETWORK" >/dev/null; then
            echo_info "The existing blockchain data is kept until the new snapshot is verified,"
            echo_info "so a refresh needs room for a second copy (${required_space}GB free)."
            echo_info "To refresh in place, stop the node and remove blocks/ and chainstate/ first."
        fi
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
