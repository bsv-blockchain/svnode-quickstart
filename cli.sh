#!/bin/bash

# Bitcoin CLI wrapper script
# Usage: ./cli.sh [bitcoin-cli arguments]

cd $(dirname "$0")

# Check if bitcoin.conf exists
if [ ! -f ./bsv-data/bitcoin.conf ]; then
    echo "Error: bitcoin.conf not found in ./bsv-data/"
    echo "This does not appear to be a properly configured SVNode installation."
    exit 1
fi

# Check if bitcoin-cli binary exists
if [ ! -x ./bsv/bin/bitcoin-cli ]; then
    echo "Error: bitcoin-cli not found at ./bsv/bin/bitcoin-cli"
    echo "Please ensure SVNode is properly installed."
    exit 1
fi

# Pass all arguments to bitcoin-cli
./bsv/bin/bitcoin-cli -conf=$(realpath ./bsv-data/bitcoin.conf) "$@"
