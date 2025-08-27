#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# Source helper libraries
source "${LIB_DIR}/colors.sh"

# Parse command line arguments
CLEAN_BSV=true
CLEAN_DATA=true
CLEAN_DOWNLOADS=true
QUIET=false
FORCE=false

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  --bsv-only      Clean only the ./bsv/ directory"
    echo "  --data-only     Clean only the ./bsv-data/ directory"
    echo "  --downloads-only Clean only the ./downloads/ directory"
    echo "  --no-bsv        Skip cleaning ./bsv/ directory"
    echo "  --no-data       Skip cleaning ./bsv-data/ directory"
    echo "  --no-downloads  Skip cleaning ./downloads/ directory"
    echo "  --quiet         Suppress prompts and run silently"
    echo "  --force         Force cleanup without confirmation"
    echo "  --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Clean all directories (interactive)"
    echo "  $0 --data-only        # Clean only blockchain data"
    echo "  $0 --no-downloads     # Clean bsv and data, but keep downloads"
    echo "  $0 --quiet --force    # Clean everything without prompts"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --bsv-only)
            CLEAN_BSV=true
            CLEAN_DATA=false
            CLEAN_DOWNLOADS=false
            ;;
        --data-only)
            CLEAN_BSV=false
            CLEAN_DATA=true
            CLEAN_DOWNLOADS=false
            ;;
        --downloads-only)
            CLEAN_BSV=false
            CLEAN_DATA=false
            CLEAN_DOWNLOADS=true
            ;;
        --no-bsv)
            CLEAN_BSV=false
            ;;
        --no-data)
            CLEAN_DATA=false
            ;;
        --no-downloads)
            CLEAN_DOWNLOADS=false
            ;;
        --quiet)
            QUIET=true
            ;;
        --force)
            FORCE=true
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
    shift
done

# Show banner unless quiet
if [ "$QUIET" != true ]; then
    echo_red "=== SVNode Cleanup Script ==="
    echo ""
fi

# Determine what will be cleaned
cleanup_targets=()
if [ "$CLEAN_BSV" = true ] && [ -d "./bsv" ]; then
    cleanup_targets+=("./bsv/ (except .gitkeep)")
fi
if [ "$CLEAN_DATA" = true ] && [ -d "./bsv-data" ]; then
    cleanup_targets+=("./bsv-data/ (except .gitkeep)")
fi
if [ "$CLEAN_DOWNLOADS" = true ] && [ -d "./downloads" ]; then
    cleanup_targets+=("./downloads/")
fi

# Check if anything to clean
if [ ${#cleanup_targets[@]} -eq 0 ]; then
    if [ "$QUIET" != true ]; then
        echo_info "No directories to clean or directories don't exist."
    fi
    exit 0
fi

# Show what will be cleaned and confirm
if [ "$QUIET" != true ]; then
    echo_warning "This will remove ALL files from:"
    for target in "${cleanup_targets[@]}"; do
        echo "  - $target"
    done
    echo ""
    echo_warning "This action cannot be undone!"
    echo ""
fi

# Get confirmation unless forced or quiet
if [ "$FORCE" != true ] && [ "$QUIET" != true ]; then
    read -p "$(echo_yellow "Are you sure you want to proceed? [y/N]: ")" response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo_info "Cleanup cancelled."
        exit 0
    fi
    echo ""
fi

# Perform cleanup
if [ "$QUIET" != true ]; then
    echo_info "Cleaning up directories..."
fi

# Clean bsv directory (keep .gitkeep)
if [ "$CLEAN_BSV" = true ] && [ -d "./bsv" ]; then
    if [ "$QUIET" != true ]; then
        echo_info "Cleaning ./bsv/"
    fi
    find ./bsv -mindepth 1 ! -name '.gitkeep' -delete
fi

# Clean bsv-data directory (keep .gitkeep)
if [ "$CLEAN_DATA" = true ] && [ -d "./bsv-data" ]; then
    if [ "$QUIET" != true ]; then
        echo_info "Cleaning ./bsv-data/"
    fi
    find ./bsv-data -mindepth 1 ! -name '.gitkeep' -delete
fi

# Clean downloads directory entirely
if [ "$CLEAN_DOWNLOADS" = true ] && [ -d "./downloads" ]; then
    if [ "$QUIET" != true ]; then
        echo_info "Cleaning ./downloads/"
    fi
    rm -rf ./downloads
fi

if [ "$QUIET" != true ]; then
    echo ""
    echo_green "Cleanup complete!"
    echo_info "Selected directories have been cleaned."
    echo_info "You can run ./setup.sh to reinstall."
fi