# SV Node Quick Setup

A comprehensive setup script and template collection for quickly deploying SV Node on the BSV Blockchain with
interactive configuration, automatic installation, and flexible deployment options.

## Quick Start

1. Clone this repository:

```bash
git clone https://github.com/bsv-blockchain/svnode-quickstart.git
cd svnode-quickstart
```

2. Run the interactive setup:

```bash
./setup.sh
```

3. Follow the prompts to configure your node:
    - Select network (mainnet/testnet/regtest)
    - Choose node type (pruned/full)
    - Choose sync method (snapshot/genesis)
    - Configure RPC credentials

4. Start your node:

```bash
./start.sh
```

5. Check status:

```bash
./cli.sh getinfo
```

## Configuration Options

### Networks

- **Mainnet**: Production BSV Blockchain network
- **Testnet**: Test network for development
- **Regtest**: Local regression testing network

### Node Types

- **Pruned Node**: Reduces disk usage by removing old spent transaction data (recommended for most users)
    - Disk requirement: ~500GB
    - Retains all unspent transaction outputs (UTXOs) - critical for validation
    - Only removes historical spent transaction data from old blocks
    - Cannot serve complete historical blocks to other nodes
    - Suitable for applications, services, and wallet operations

- **Full Node**: Maintains complete blockchain history
    - Disk requirement: ~15TB and growing
    - Can serve the entire blockchain to other nodes
    - Required for block explorers and archival purposes

### Sync Methods

- **Snapshot Sync**: Downloads pruned blockchain data via HTTP using wget (recommended)
    - Source: https://svnode-snapshots.bsvb.tech/ (provided as-is by the BSV Association)
    - Both mainnet and testnet snapshots are pruned (contain recent blockchain data only)
    - Incremental updates: Only downloads new files on subsequent syncs
    - Resume support: Continues from where it left off if interrupted
    - Mainnet: ~160GB of pruned blockchain data
    - Testnet: ~30GB of pruned blockchain data

  **Note on Pruned Snapshots**: Pruned snapshots contain all unspent transaction outputs (UTXOs) but have removed
  historical spent transaction data from old blocks. This preserves your node's ability to validate new transactions and
  blocks while significantly reducing storage requirements. All consensus-critical data remains intact - only historical
  spent transactions that are no longer needed for validation are removed. Your node maintains full security and
  validation capabilities.

- **Genesis Sync**: Start from block 0 and sync the entire blockchain (slower but builds complete history)

## Usage

### Node Management

Simple commands to manage your SV Node:

```bash
# Start the node
./start.sh

# Stop the node
./stop.sh

# Restart the node
./restart.sh

# Use bitcoin-cli
./cli.sh getinfo
./cli.sh getblockchaininfo
./cli.sh getpeerinfo

# View logs (network-specific)
# Mainnet:
tail -f ./bsv-data/bitcoind.log
# Testnet:
tail -f ./bsv-data/testnet3/bitcoind.log  
# Regtest:
tail -f ./bsv-data/regtest/bitcoind.log
```

## File Locations

Default installation paths (in the script directory):

- **Installation Directory**: `./bsv/`
- **Data Directory**: `./bsv-data/`
- **Downloads Directory**: `./downloads/` (temporary files, snapshots)
- **Configuration File**: `./bsv-data/bitcoin.conf`
- **Log Files**:
    - **Mainnet**: `./bsv-data/bitcoind.log`
    - **Testnet**: `./bsv-data/testnet3/bitcoind.log`
    - **Regtest**: `./bsv-data/regtest/bitcoind.log`

## RPC Access

The node's RPC interface is configured during setup with secure defaults:

### Default Configuration (Secure)

- **Mainnet RPC Port**: 8332
- **Testnet RPC Port**: 18332
- **Regtest RPC Port**: 18443
- **Bind Address**: `127.0.0.1` (localhost only)
- **Allowed IPs**: `127.0.0.1` (localhost only)

This configuration ensures the RPC interface is only accessible from the local machine, providing maximum security.

### Local Access

```bash
# Using the provided CLI wrapper
./cli.sh getblockchaininfo

# Or directly with bitcoin-cli
./bsv/bin/bitcoin-cli -conf=./bsv-data/bitcoin.conf getinfo
```

### Remote Access (Advanced - Use with Caution)

If you need to access the RPC interface from other machines, you can modify the configuration in
`./bsv-data/bitcoin.conf`:

```ini
# Allow connections from any IP (DANGEROUS - use with firewall)
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0

# Or allow specific networks only (recommended for remote access)
rpcallowip=192.168.1.0/24  # Allow local network
rpcbind=0.0.0.0
```

**⚠️ Security Warning**: When enabling remote RPC access:

- **Always use a firewall** to restrict access to trusted IPs only
- **Never expose RPC ports to the internet** without proper authentication and encryption
- **Use strong RPC credentials** (automatically generated during setup)
- **Consider using SSH tunneling** for remote access instead of opening RPC ports directly

Example firewall rules for remote access:

```bash
# Allow RPC access from specific IP only
sudo ufw allow from 192.168.1.100 to any port 8332

# Block public access
sudo ufw deny 8332
```

## Troubleshooting

### Node Won't Start

1. Check system requirements:

```bash
./lib/check_requirements.sh
```

2. Verify configuration:

```bash
cat ./bsv-data/bitcoin.conf
```

3. Check logs:

```bash
tail -f ./bsv-data/bitcoind.log
```

## Advanced Configuration

### Custom bitcoin.conf

Edit the configuration file after installation:

```bash
nano ./bsv-data/bitcoin.conf
./restart.sh
```

## Cleanup

To remove all SV Node files and start fresh:

```bash
# Remove all files (interactive)
./clean.sh

# Remove only blockchain data
./clean.sh --data-only

# Remove everything silently
./clean.sh --force --quiet

# See all cleanup options
./clean.sh --help
```

## Docker Testing Environment

A Docker Compose setup is provided for testing the installation scripts in a clean Ubuntu 24.04 x86_64 environment (
primarily for non-x86 development machines):

```bash
# Navigate to the docker test directory
cd lib/docker-test

# Start the test container
docker-compose up -d

# Access the container shell  
docker-compose exec svnode-test bash

# Inside the container, run the setup
cd /workspace
./setup.sh

# Test the installation
./start.sh
./cli.sh getblockchaininfo
./stop.sh

# Clean up when done
exit
docker-compose down
```

The Docker environment includes all required dependencies and provides an isolated testing environment that won't affect
your host system. The container automatically installs necessary packages during startup.

## Updates

To update your SV Node to a newer version:

1. Stop the current node
2. Download the new version using `lib/download_node.sh`
3. Start the node

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

For SV Node-specific support:

- [BSV Blockchain Documentation](https://docs.bsvblockchain.org/)
- [SV Node Documentation](https://docs.bsvblockchain.org/network-topology/nodes/sv-node)
- [SV Node GitHub](https://github.com/bitcoin-sv/bitcoin-sv)

## Disclaimer

This setup script is provided as-is without warranty. Always verify configurations and test thoroughly before using in
production environments. Ensure you understand the implications of running a blockchain node, including disk space,
bandwidth, and security considerations.

### Snapshot Trust and Security Considerations

The blockchain snapshots available at https://svnode-snapshots.bsvb.tech/ are provided as-is by the BSV Association.
While these snapshots can significantly speed up initial node setup, it's critical to understand the security
implications before using them in different environments.

#### **Usage Guidelines and Best Practices**

**Snapshots are suitable for:**
- **Quick deployment** for businesses to get operational faster
- **Development and testing environments**
- **Non-mining passive nodes**
- **Applications processing confirmed transactions**

**Important considerations for production use:**
- **0-confirmation transactions**: Do not rely on 0-confirmation transactions from snapshot-initialized nodes
- **Dual-node strategy**: Use snapshots for immediate deployment while simultaneously running a full genesis sync on a separate node
- **Network consensus**: Trust the network consensus mechanism - if invalid data exists in snapshots, the network will reject it

#### **How Snapshots Work with Network Consensus**

**Network Protection**: The Bitcoin SV network's consensus mechanism ensures that any invalid transactions or outputs in snapshots will be rejected by the network. If your snapshot-initialized node encounters invalid data, it will either:
- Reject the invalid data and continue following the valid chain
- Temporarily halt until the issue is resolved through network consensus

**Recommended Deployment Strategy**: 
- **Immediate operations**: Use snapshot sync for quick deployment to start operations
- **Parallel validation**: Run a separate node with full genesis sync for maximum validation
- **Migration path**: Once your genesis-synced node is ready, you can migrate operations or use it for additional validation

#### **Security Considerations**

**Trust Model**: Using snapshots requires trusting the snapshot provider has not included manipulated data, though the network's consensus mechanism provides protection against invalid data propagation.

**0-Confirmation Risk**: Applications relying on 0-confirmation transactions should use genesis-synced nodes, as snapshot initialization bypasses the historical validation that helps detect certain attack vectors.

**For Enhanced Security**: 
- Create and maintain your own snapshots from genesis-validated nodes
- Use `./cli.sh verifychain` for additional validation
- Monitor synchronization status and network consensus alignment

**Validation**: SV Node automatically validates loaded snapshot data on startup, verifying block headers, chain integrity, and the UTXO set. The network consensus mechanism provides ongoing protection against invalid data.
