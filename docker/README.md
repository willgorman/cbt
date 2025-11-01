# Running CBT with Docker

This guide explains how to run CBT (Ceph Benchmarking Tool) using Docker containers for consistent and reproducible benchmark environments.

## Overview

The CBT Docker setup provides:
- A single Docker image that can serve as both head node and client nodes
- Support for librbdfio benchmarks using FIO with librbd
- Easy orchestration with docker-compose
- Consistent environment across different systems

## Prerequisites

1. Docker Engine (version 20.10 or later)
2. Docker Compose (version 2.0 or later)
3. A running Ceph cluster with:
   - Accessible MONs
   - Client keyring with appropriate permissions
   - Network connectivity from Docker containers to Ceph cluster

## Quick Start

### 1. Prepare Ceph Configuration

Create a directory with your Ceph configuration files:

```bash
mkdir -p ceph-config
# Copy your ceph.conf
cp /etc/ceph/ceph.conf ceph-config/
# Copy your client keyring
cp /etc/ceph/ceph.client.admin.keyring ceph-config/
```

### 2. Set Up SSH Keys

The head node needs to access client nodes via SSH. Generate or use existing SSH keys:

```bash
# Generate SSH key if you don't have one
ssh-keygen -t rsa -b 4096 -f ~/.ssh/cbt_rsa -N ""

# The docker-compose setup will mount your SSH directory
```

### 3. Create Test Configuration Directory

```bash
mkdir -p configs
# Copy or create your CBT YAML configuration files here
```

### 4. Build and Start Containers

```bash
# Build the Docker image
docker build -t cbt:latest .

# Start all containers
docker-compose up -d
```

### 5. Set Up SSH Access Between Containers

```bash
# Copy SSH public key to client containers
docker exec cbt-head cat /root/.ssh/id_rsa.pub > /tmp/cbt_key.pub
docker exec cbt-client-1 bash -c "mkdir -p /root/.ssh && cat >> /root/.ssh/authorized_keys" < /tmp/cbt_key.pub
docker exec cbt-client-2 bash -c "mkdir -p /root/.ssh && cat >> /root/.ssh/authorized_keys" < /tmp/cbt_key.pub
rm /tmp/cbt_key.pub
```

Or use the provided setup script (see below).

### 6. Run Benchmarks

```bash
# Access the head node
docker exec -it cbt-head bash

# Inside the container, run CBT
python3 cbt.py --archive=/cbt/archive /cbt/configs/librbdfio-example.yaml
```

## Directory Structure

```
.
├── Dockerfile              # Docker image definition
├── docker-compose.yml      # Container orchestration
├── docker/
│   ├── README.md          # This file
│   ├── setup.sh           # Setup script for SSH keys
│   └── examples/          # Example configurations
│       ├── librbdfio-simple.yaml
│       └── ceph.conf.example
└── ceph-config/           # Your Ceph configuration (not in repo)
    ├── ceph.conf
    └── ceph.client.admin.keyring
```

## Configuration

### Environment Variables

You can customize the docker-compose setup using environment variables:

- `CEPH_CONF_DIR`: Path to Ceph configuration directory (default: `./ceph-config`)
- `SSH_KEY_DIR`: Path to SSH keys directory (default: `~/.ssh`)
- `ARCHIVE_DIR`: Path for storing benchmark results (default: `./archive`)
- `CONFIG_DIR`: Path to CBT configuration files (default: `./configs`)

Example:

```bash
CEPH_CONF_DIR=/etc/ceph ARCHIVE_DIR=/data/cbt-results docker-compose up -d
```

### CBT Configuration for Docker

When creating your CBT YAML configuration for Docker deployment, use container hostnames:

```yaml
cluster:
  user: 'root'
  head: "cbt-head"
  clients: ["cbt-client-1", "cbt-client-2"]
  # Use existing cluster (don't try to create OSDs)
  use_existing: True
  conf_file: '/etc/ceph/ceph.conf'
  iterations: 1
  tmp_dir: "/tmp/cbt"

benchmarks:
  librbdfio:
    time: 300
    vol_size: 16384
    mode: [read, write, randread, randwrite]
    op_size: [4194304]
    iodepth: [64]
    numjobs: [1]
    cmd_path: '/usr/bin/fio'
    use_existing_volumes: False
    pool_profile: 'default'
```

## Scaling Clients

To add more client nodes, edit `docker-compose.yml` and add additional client services:

```yaml
  cbt-client-3:
    build: .
    image: cbt:latest
    container_name: cbt-client-3
    hostname: cbt-client-3
    networks:
      - cbt-network
    volumes:
      - ${CEPH_CONF_DIR:-./ceph-config}:/etc/ceph:ro
      - ${SSH_KEY_DIR:-~/.ssh}:/root/.ssh:ro
    privileged: true
    command: |
      bash -c '
        mkdir -p /run/sshd
        /usr/sbin/sshd -D
      '
```

Then update your CBT configuration to include the new client in the `clients` list.

## Networking

The Docker containers use a bridge network (`cbt-network`) for internal communication. Ensure your Ceph cluster is accessible from this network. You may need to configure Docker networking or use host networking mode for direct access to Ceph MONs and OSDs.

### Using Host Network (Alternative)

If you encounter networking issues with Ceph connectivity, you can modify the docker-compose.yml to use host networking:

```yaml
services:
  cbt-head:
    network_mode: "host"
    # Remove 'networks' section
```

Note: Host networking removes network isolation and may cause port conflicts.

## Troubleshooting

### SSH Connection Issues

If the head node cannot SSH to client nodes:

```bash
# Check SSH daemon is running on clients
docker exec cbt-client-1 ps aux | grep sshd

# Test SSH connection from head
docker exec cbt-head ssh cbt-client-1 hostname
```

### Ceph Connection Issues

```bash
# Verify Ceph configuration is mounted
docker exec cbt-head cat /etc/ceph/ceph.conf

# Test Ceph connectivity
docker exec cbt-head ceph -s

# Test RBD operations
docker exec cbt-head rbd ls
```

### FIO/librbd Issues

```bash
# Verify FIO has rbd engine
docker exec cbt-head fio --enghelp=rbd

# Test RBD directly with FIO
docker exec cbt-head fio --ioengine=rbd --clientname=admin \
  --pool=rbd --rbdname=test --bs=4k --runtime=10 --name=test \
  --rw=randwrite --iodepth=16 --numjobs=1
```

### Permission Issues

The containers run as root by default. Ensure:
- Ceph keyring has appropriate permissions
- SSH keys have correct permissions (600 for private keys)
- Archive directory is writable

## Advanced Usage

### Running Multiple Test Configurations

```bash
# Create multiple test configs
configs/
  ├── test1-seq-write.yaml
  ├── test2-rand-read.yaml
  └── test3-mixed.yaml

# Run each test
for config in /cbt/configs/*.yaml; do
  docker exec cbt-head python3 cbt.py --archive=/cbt/archive "$config"
done
```

### Custom FIO Version

If you need a specific FIO version, modify the Dockerfile:

```dockerfile
# Instead of using apt package
RUN apt-get remove -y fio && \
    cd /tmp && \
    git clone https://github.com/axboe/fio.git && \
    cd fio && \
    git checkout fio-3.35 && \
    ./configure && \
    make && \
    make install
```

### Mounting Additional Ceph Keyrings

For multiple Ceph users:

```yaml
volumes:
  - ./ceph-config:/etc/ceph:ro
  - ./additional-keyrings:/etc/ceph/keyrings:ro
```

## Cleanup

```bash
# Stop and remove containers
docker-compose down

# Remove volumes and images
docker-compose down -v
docker rmi cbt:latest

# Clean up results
rm -rf archive/*
```

## Security Considerations

1. **SSH Keys**: The setup uses passwordless SSH. Ensure SSH keys are properly secured.
2. **Ceph Keyrings**: Mount keyrings as read-only and with minimal permissions.
3. **Privileged Mode**: Client containers run in privileged mode for block device access. This is necessary for RBD operations but reduces isolation.
4. **Network Isolation**: The containers are on a bridge network. For production, consider additional network security measures.

## Performance Considerations

1. **Docker Storage Driver**: Use overlay2 for best performance
2. **Resource Limits**: Set appropriate CPU and memory limits in docker-compose.yml
3. **Network Performance**: Consider using host networking or SR-IOV for high-performance benchmarks
4. **Storage**: Mount the archive directory on fast storage (SSD/NVMe)

## Contributing

When adding support for additional benchmark modules, update this documentation and provide example configurations.
