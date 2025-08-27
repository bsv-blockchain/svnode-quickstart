verify_checksum() {
    local file="$1"
    local checksum_url="$2"
    local version="$3"
    
    echo_info "Verifying checksum for version $version..."
    
    if ! command -v sha256sum &> /dev/null; then
        echo_warning "sha256sum not found. Skipping verification."
        echo_warning "Install coreutils package for checksum verification."
        return 0
    fi
    
    local downloads_dir=$(dirname "$file")
    local checksum_file="${downloads_dir}/SHA256SUMS.asc"
    local filename=$(basename "$file")
    
    
    # Download checksum file
    echo_info "Downloading checksum file..."
    if command -v wget &> /dev/null; then
        wget -q -O "$checksum_file" "$checksum_url" 2>/dev/null
    elif command -v curl &> /dev/null; then
        curl -s -o "$checksum_file" "$checksum_url" 2>/dev/null
    else
        echo_warning "Neither wget nor curl available for checksum download."
        return 0
    fi
    
    if [ ! -f "$checksum_file" ]; then
        echo_warning "Could not download checksum file from: $checksum_url"
        echo_warning "Proceeding without verification."
        return 1
    fi
    
    # Extract checksum for our specific file (exact match)
    local expected_checksum=$(grep " $filename$" "$checksum_file" 2>/dev/null | awk '{print $1}')
    
    if [ -z "$expected_checksum" ]; then
        echo_warning "Checksum not found for $filename in checksum file."
        echo_info "Available checksums in file:"
        head -5 "$checksum_file" 2>/dev/null || echo "  (could not read checksum file)"
        echo_warning "Proceeding without verification."
        return 1
    fi
    
    # Calculate actual checksum
    echo_info "Calculating file checksum..."
    local actual_checksum=$(sha256sum "$file" | awk '{print $1}')
    
    # Compare checksums
    if [[ "$actual_checksum" == "$expected_checksum" ]]; then
        echo_success "Checksum verified successfully."
        echo_info "Expected: $expected_checksum"
        echo_info "Actual:   $actual_checksum"
        return 0
    else
        echo_error "Checksum verification failed!"
        echo_error "Expected: $expected_checksum"
        echo_error "Actual:   $actual_checksum"
        echo_error "This could indicate file corruption or a security issue."
        return 1
    fi
}