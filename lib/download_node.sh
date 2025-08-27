#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/colors.sh"
source "${SCRIPT_DIR}/verify_checksum.sh"

# Generate download and checksum URLs from version
get_download_url() {
    local version="$1"
    echo "https://releases-svnode.bsvblockchain.org/svnode-${version}/bitcoin-sv-${version}-x86_64-linux-gnu.tar.gz"
}

get_checksum_url() {
    local version="$1"
    echo "https://releases-svnode.bsvblockchain.org/svnode-${version}/SHA256SUMS.asc"
}

VERSION="$1"
INSTALL_DIR="$2"

# Check required parameters
if [ -z "$VERSION" ]; then
    echo_error "Version parameter is required"
    echo_info "Usage: $0 <version> <install_dir>"
    echo_info "Example: $0 1.1.1 ./bsv"
    exit 1
fi

if [ -z "$INSTALL_DIR" ]; then
    echo_error "Install directory parameter is required"
    echo_info "Usage: $0 <version> <install_dir>"
    exit 1
fi


download_with_progress() {
    local url="$1"
    local output="$2"
    
    echo_info "Downloading from: $url"
    
    if command -v wget &> /dev/null; then
        wget --progress=bar:force -O "$output" "$url" 2>&1 | \
            grep --line-buffered "%" | \
            sed -u -e "s,.*\([0-9]\+%\).*,\1,"
    elif command -v curl &> /dev/null; then
        curl -L --progress-bar -o "$output" "$url"
    else
        echo_error "Neither wget nor curl is available."
        return 1
    fi
}


extract_archive() {
    local archive="$1"
    local dest_dir="$2"
    
    echo_info "Extracting archive..."
    
    if ! tar -xzf "$archive" -C "$dest_dir"; then
        echo_error "Failed to extract archive."
        return 1
    fi
    
    echo_success "Archive extracted successfully."
    return 0
}

download_node() {
    local version="$1"
    local install_dir="$2"
    
    # Generate URLs from version
    local download_url=$(get_download_url "$version")
    local checksum_url=$(get_checksum_url "$version")
    local downloads_dir="$(dirname "$SCRIPT_DIR")/downloads"
    mkdir -p "$downloads_dir"
    local archive_file="${downloads_dir}/bitcoin-sv-${version}-x86_64-linux-gnu.tar.gz"
    
    echo_green "=== Downloading Bitcoin SV Node v${version} ==="
    echo ""
    
    # Download the archive
    if ! download_with_progress "$download_url" "$archive_file"; then
        echo_error "Download failed."
        rm -rf "$temp_dir"
        return 1
    fi
    
    echo_success "Download complete."
    echo ""
    
    # Verify checksum
    if ! verify_checksum "$archive_file" "$checksum_url" "$version"; then
        echo_warning "Checksum verification failed or unavailable."
        echo_warning "Proceeding without verification."
    fi
    echo ""
    
    # Clean and prepare installation directory
    echo_info "Installing to: $install_dir"
    
    if ! mkdir -p "$install_dir"; then
        echo_error "Failed to create installation directory."
        return 1
    fi
    
    # Clean existing installation (but keep .gitkeep)
    echo_info "Cleaning existing installation..."
    find "$install_dir" -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true
    
    # Extract archive contents directly to install_dir
    if ! tar -xzf "$archive_file" -C "$install_dir" --strip-components=1; then
        echo_error "Failed to extract archive."
        return 1
    fi
    
    echo_success "Installation complete."
    
    # Set proper permissions
    echo_info "Setting permissions..."
    chmod -R 755 "$install_dir"
    
    # Verify binary exists and is executable
    local binary_path="${install_dir}/bin/bitcoind"
    if [[ -x "$binary_path" ]]; then
        echo_success "Binary verified: $binary_path"
        
        # Display version info
        echo_info "Installed version information:"
        "$binary_path" --version | head -n1 || true
    else
        echo_warning "Could not verify binary at: $binary_path"
    fi
    
    # Clean up checksum file if it exists
    rm -f "${downloads_dir}/SHA256SUMS.asc"
    
    echo ""
    echo_green "Bitcoin SV Node v${version} installed successfully!"
    
    return 0
}

# Function to list available versions
list_versions() {
    echo_info "Available Bitcoin SV versions:"
    for version in "${!VERSIONS[@]}"; do
        echo "  - $version"
    done
}

# Function to get latest version
get_latest_version() {
    # In production, this would fetch from an API or check the website
    # For now, return hardcoded latest
    echo "1.1.1"
}

main() {
    local version="${1:-$(get_latest_version)}"
    local install_dir="${2:-/opt/bsv}"
    
    if [[ "$version" == "list" ]]; then
        list_versions
        exit 0
    fi
    
    download_node "$version" "$install_dir"
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi