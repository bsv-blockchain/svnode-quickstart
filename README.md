# SVNode Quick Setup

A comprehensive setup script and template collection for quickly deploying Bitcoin SV (BSV) nodes with interactive configuration, automatic installation, and flexible deployment options.

## Features

- **Interactive Setup Wizard**: Guided configuration with sensible defaults
- **Multiple Network Support**: Mainnet, Testnet, and Regtest
- **Flexible Node Types**: Choose between pruned (minimal disk usage) or full node
- **Simple Deployment**: Direct binary execution with daemon mode and helper scripts
- **Blockchain Snapshots**: Optional pruned snapshot download for faster initial sync
- **System Requirements Check**: Validates prerequisites before installation
- **Automatic Configuration**: Generates optimized `bitcoin.conf` based on your choices
- **Management Scripts**: Convenient scripts for starting, stopping, and monitoring your node

## Prerequisites

- Linux operating system (Ubuntu, Debian, CentOS, Fedora, Arch, etc.)
- At least 200GB free disk space (pruned) or 15TB (full node)
- 8GB+ RAM recommended
- Basic command-line tools: `wget` or `curl`, `tar`, `sha256sum`, `openssl`
- `sudo` access or root privileges for installation

## Quick Start

1. Clone this repository:
```bash
git clone https://github.com/yourusername/svnode-quickstart.git
cd svnode-quickstart
```

2. Make the setup script executable:
```bash
chmod +x setup.sh
```

3. Run the interactive setup:
```bash
./setup.sh
```

4. Follow the prompts to configure your node:
   - Select network (mainnet/testnet/regtest)
   - Choose node type (pruned/full)
   - Choose sync method (snapshot/genesis)
   - Configure RPC credentials

## Directory Structure

```
svnode-quickstart/
├── setup.sh                    # Main interactive setup script
├── start.sh                    # Start the SVNode
├── stop.sh                     # Stop the SVNode gracefully
├── restart.sh                  # Restart the SVNode
├── b.sh                        # Bitcoin CLI wrapper
├── lib/
│   ├── check_requirements.sh   # System requirements validation
│   ├── download_node.sh        # Download and verify SVNode binaries
│   ├── config_generator.sh     # Generate bitcoin.conf
│   ├── snapshot_sync.sh        # Handle pruned snapshot downloads
│   └── colors.sh               # Terminal color formatting
├── bsv/                        # SVNode installation (created by setup)
├── bsv-data/                   # Node data directory (created by setup)
├── downloads/                  # Download cache (created by setup)
└── README.md                   # This file
```

## Configuration Options

### Networks

- **Mainnet**: Production Bitcoin SV network
- **Testnet**: Test network for development
- **Regtest**: Local regression testing network

### Node Types

- **Pruned Node**: Reduces disk usage by deleting old block data (recommended for most users)
  - Disk requirement: ~200GB
  - Cannot serve old blocks to other nodes
  - Suitable for applications and services

- **Full Node**: Maintains complete blockchain history
  - Disk requirement: ~15TB and growing
  - Can serve the entire blockchain to other nodes
  - Required for block explorers and archival purposes

### Simple Management

The setup creates a straightforward deployment using the bitcoind daemon mode with helper scripts:
- **Daemon Mode**: Uses `daemon=1` in bitcoin.conf for background operation
- **Helper Scripts**: Simple start/stop/restart scripts in the root directory
- **Graceful Shutdown**: Uses bitcoin-cli stop for clean shutdowns
- **CLI Access**: Convenient wrapper script for bitcoin-cli commands

## Usage

### Node Management

Simple commands to manage your SVNode:

```bash
# Start the node
./start.sh

# Stop the node
./stop.sh

# Restart the node
./restart.sh

# Use bitcoin-cli
./b.sh getinfo
./b.sh getblockchaininfo
./b.sh getpeerinfo

# View logs
tail -f ./bsv-data/debug.log
```

## File Locations

Default installation paths (in the script directory):

- **Installation Directory**: `./bsv`
- **Data Directory**: `./bsv-data`
- **Configuration File**: `./bsv-data/bitcoin.conf`
- **Debug Log**: `./bsv-data/debug.log`

## RPC Access

The node's RPC interface is configured during setup. Default settings:

- **Mainnet RPC Port**: 8332
- **Testnet RPC Port**: 18332
- **Regtest RPC Port**: 18443

Access the RPC interface:

```bash
# Using the provided CLI wrapper
./b.sh getblockchaininfo

# Or directly with bitcoin-cli
./bsv/bin/bitcoin-cli -conf=./bsv-data/bitcoin.conf getinfo
```

## Troubleshooting

### Node Won't Start

1. Check system requirements:
```bash
./lib/check_requirements.sh
```

2. Verify configuration:
```bash
cat /var/lib/bsv-data/bitcoin.conf
```

3. Check logs:
```bash
tail -f ./bsv-data/debug.log
```

### Insufficient Disk Space

- Consider using a pruned node instead of full node
- Move data directory to a larger disk
- Use the snapshot download option for faster initial sync

### Connection Issues

- Ensure ports 8333 (mainnet) or 18333 (testnet) are not blocked
- Check firewall settings
- Verify network connectivity

### High Memory Usage

- Adjust `dbcache` setting in bitcoin.conf
- Consider system memory limits in systemd service
- Use pruned mode to reduce memory requirements

## Advanced Configuration

### Custom bitcoin.conf

Edit the configuration file after installation:

```bash
nano ./bsv-data/bitcoin.conf
./restart.sh
```

### Performance Tuning

Key settings in bitcoin.conf:

```ini
# Cache size in MB (default: 4000)
dbcache=8000

# Maximum connections
maxconnections=125

# Memory pool size in MB
maxmempool=3000

# Upload limit in MB per day
maxuploadtarget=5000
```

### Security Hardening

1. Restrict RPC access:
```ini
rpcallowip=127.0.0.1
rpcbind=127.0.0.1
```

2. Use strong RPC credentials (generated automatically during setup)

3. Enable firewall rules (if needed):
```bash
sudo ufw allow 8333/tcp  # Mainnet P2P
sudo ufw allow 8332/tcp  # RPC (only if accessing externally)
```

## Backup and Recovery

### Backup Important Files

```bash
# Manual backup
tar -czf svnode_backup.tar.gz \
  ./bsv-data/bitcoin.conf \
  ./bsv-data/peers.dat
```

### Restore from Backup

```bash
# Stop the node first
./stop.sh

# Restore files
tar -xzf svnode_backup.tar.gz

# Start the node
./start.sh
```

## Updates

To update your SVNode to a newer version:

1. Stop the current node
2. Download the new version using `lib/download_node.sh`
3. Update the symlinks
4. Start the node

```bash
# Example update process
./stop.sh
./lib/download_node.sh 1.2.0 ./bsv
./start.sh
```

## Contributing

Contributions are welcome! Please feel free to submit issues, feature requests, or pull requests.


## Support

For issues with this setup script:
- Open an issue on GitHub
- Check existing issues for solutions

For SVNode-specific support:
- [Bitcoin SV Documentation](https://docs.bitcoinsv.io/)
- [Bitcoin SV Node GitHub](https://github.com/bitcoin-sv/bitcoin-sv)

## Creating Snapshots

If you want to create your own blockchain snapshots for distribution:

### Prerequisites
- A fully synced pruned SVNode
- Sufficient disk space for tar compression (approximately same size as data directory)
- Shell access to the server running the node

### Snapshot Creation Process

1. **Gracefully stop the SVNode**:
```bash
# Using these helper scripts
./stop.sh

# Or manually with bitcoin-cli
./bsv/bin/bitcoin-cli -conf=./bsv-data/bitcoin.conf stop

# Wait for complete shutdown (check that no bitcoind process exists)
ps aux | grep bitcoind
```

2. **Create the snapshot archive**:
```bash
# Navigate to the data directory
cd ./bsv-data

# Create compressed archive of essential blockchain data
tar -czf ../mainnet-snapshot-latest.tar.gz \
    blocks/ \
    chainstate/ \
    database/ \
    frozentxos/ \
    merkle/

# For testnet, use appropriate filename
tar -czf ../testnet-snapshot-latest.tar.gz \
    blocks/ \
    chainstate/ \
    database/ \
    frozentxos/ \
    merkle/
```

3. **Verify the archive**:
```bash
# Check archive contents
tar -tzf mainnet-snapshot-latest.tar.gz | head -20

# Check archive size
ls -lh mainnet-snapshot-latest.tar.gz
```

4. **Generate checksums** (recommended):
```bash
# Generate simple checksum file
sha256sum mainnet-snapshot-latest.tar.gz > mainnet-snapshot-latest.tar.gz.sha256

# For testnet
sha256sum testnet-snapshot-latest.tar.gz > testnet-snapshot-latest.tar.gz.sha256
```

### Important Notes
- **Only include these directories**: `blocks/`, `chainstate/`, `database/`, `frozentxos/`, `merkle/`
- **Exclude**: `bitcoin.conf`, `debug.log`, `peers.dat`, `banlist.dat`, and other config/log files
- **Node must be stopped**: Never create snapshots while the node is running
- **Pruned nodes only**: Full node snapshots would be prohibitively large
- **Verify integrity**: Test extraction on a separate system before distribution

### Checksum File Format
The `.sha256` files should contain a single line with the checksum and filename:
```
a1b2c3d4e5f6...  mainnet-snapshot-latest.tar.gz
```

The resulting archive contains only the essential blockchain data needed for a quick node startup, without any configuration or personal files.

## Disclaimer

This setup script is provided as-is without warranty. Always verify configurations and test thoroughly before using in production environments. Ensure you understand the implications of running a blockchain node, including disk space, bandwidth, and security considerations.
