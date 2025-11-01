# Running CBT with Docker

This guide explains how to run CBT (Ceph Benchmarking Tool) using Docker containers for consistent and reproducible benchmark environments.

## Overview

The CBT Docker setup provides:
- A single Docker image that can serve as both head node and client nodes
- Support for librbdfio benchmarks using FIO with librbd
- Easy orchestration with docker-compose
- Consistent environment across different systems
- **Support for both single-host and multi-host deployments**

## Deployment Modes

CBT Docker supports two deployment modes:

1. **Single-Host Deployment** - All containers (head + clients) run on one host
   - Good for: Development, testing, small-scale benchmarks
   - Uses: `docker-compose.yml`
   - Setup: `./docker/setup.sh`

2. **Multi-Host Deployment** - Head on one host, clients on separate hosts (RECOMMENDED for production)
   - Good for: Production benchmarks, distributed workloads, realistic testing
   - Uses: `docker-compose.head.yml` (head) and `docker-compose.client.yml` (clients)
   - Setup: `./docker/setup-multihost.sh`

## Prerequisites

1. Docker Engine (version 20.10 or later)
2. Docker Compose (version 2.0 or later)
3. A running Ceph cluster with:
   - Accessible MONs
   - Client keyring with appropriate permissions
   - Network connectivity from Docker containers to Ceph cluster

## Using Pre-Built Images

Pre-built Docker images are automatically published to GitHub Container Registry (ghcr.io) for every release and main branch push.

### Available Image Tags

- `latest` - Latest build from the main branch
- `v*.*.*` - Specific version tags (e.g., v1.0.0)
- `main` - Latest build from main branch
- `<branch>-<sha>` - Specific commit builds

### Pulling the Image

```bash
# Pull the latest version
docker pull ghcr.io/ceph/cbt:latest

# Pull a specific version
docker pull ghcr.io/cbt:v1.0.0

# Pull from main branch
docker pull ghcr.io/cbt:main
```

**Note:** The repository name in the image URL should match your GitHub repository. If this is a fork or different repo, replace `ceph/cbt` with `owner/repo`.

### Using Pre-Built Images with Docker Compose

You can use the pre-built images instead of building locally by modifying the docker-compose files:

```yaml
services:
  cbt-head:
    image: ghcr.io/ceph/cbt:latest  # Use pre-built image
    # Remove or comment out 'build: .' line
    container_name: cbt-head
    # ... rest of configuration
```

This eliminates the need to run `docker build` locally.

### Quick Start with Pre-Built Image

```bash
# Pull the latest image
docker pull ghcr.io/ceph/cbt:latest

# Run single-host setup (will use pre-built image)
./docker/setup.sh

# Or for multi-host deployment
./docker/setup-multihost.sh --clients client1,client2
```

The setup scripts will automatically use the pre-built image if available, falling back to local build if needed.

## Quick Start (Single-Host)

**Note:** This section covers single-host deployment. For multi-host deployment (RECOMMENDED for production), see the [Multi-Host Deployment](#multi-host-deployment) section below.

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
├── Dockerfile                    # Docker image definition
├── docker-compose.yml            # Single-host orchestration
├── docker-compose.head.yml       # Multi-host: head node
├── docker-compose.client.yml     # Multi-host: client node
├── docker/
│   ├── README.md                # This file
│   ├── setup.sh                 # Single-host setup script
│   ├── setup-multihost.sh       # Multi-host setup script
│   └── examples/                # Example configurations
│       ├── librbdfio-simple.yaml
│       ├── librbdfio-workloads.yaml
│       └── ceph.conf.example
└── ceph-config/                 # Your Ceph configuration (not in repo)
    ├── ceph.conf
    └── ceph.client.admin.keyring
```

## Multi-Host Deployment

**This is the RECOMMENDED deployment method for production benchmarks** as it distributes the workload across multiple physical/virtual machines, providing more realistic and accurate performance measurements.

### Architecture

```
┌─────────────────────┐
│   Head Node Host    │
│  ┌───────────────┐  │
│  │  cbt-head     │  │──┐
│  │  container    │  │  │
│  └───────────────┘  │  │ SSH (pdsh)
└─────────────────────┘  │
                         │
         ┌───────────────┼───────────────┐
         │               │               │
         ▼               ▼               ▼
┌─────────────────┐ ┌─────────────┐ ┌─────────────┐
│ Client Host 1   │ │ Client 2    │ │ Client 3    │
│ ┌─────────────┐ │ │ ┌─────────┐ │ │ ┌─────────┐ │
│ │ cbt-client  │ │ │ │cbt-client││ │ │cbt-client││
│ │ container   │ │ │ │container ││ │ │container ││
│ └─────────────┘ │ │ └─────────┘ │ │ └─────────┘ │
└─────────────────┘ └─────────────┘ └─────────────┘
         │               │               │
         └───────────────┴───────────────┘
                         │
                         ▼
                 ┌──────────────┐
                 │ Ceph Cluster │
                 │   (MONs/OSDs)│
                 └──────────────┘
```

### Prerequisites for Multi-Host

1. **Head Node** - One machine to run CBT commands
   - Docker and docker-compose installed
   - SSH access to all client hosts
   - Network connectivity to Ceph cluster

2. **Client Nodes** - One or more machines to run benchmarks
   - Docker and docker-compose installed
   - SSH server running (will use container SSH)
   - Network connectivity to Ceph cluster
   - Network reachable from head node

3. **Ceph Configuration**
   - `ceph.conf` and keyring files available
   - MONs and OSDs accessible from all hosts

### Automated Multi-Host Setup

The easiest way to set up multi-host deployment is using the automated script:

```bash
# On the head node, run:
./docker/setup-multihost.sh --clients client1.example.com,client2.example.com,client3.example.com

# With custom SSH user and key:
./docker/setup-multihost.sh \
  --clients 192.168.1.10,192.168.1.11,192.168.1.12 \
  --user root \
  --key ~/.ssh/id_rsa
```

This script will:
1. Check Docker installation on all hosts
2. Copy necessary files to client hosts
3. Build Docker images on all hosts
4. Set up SSH keys for passwordless access
5. Start containers on all hosts
6. Test connectivity
7. Create a sample configuration file

### Manual Multi-Host Setup

If you prefer to set up manually or need more control:

#### Step 1: Prepare Head Node

```bash
# On head node
cd /path/to/cbt

# Create directories
mkdir -p ceph-config configs archive ssh-auth

# Copy Ceph configuration
cp /etc/ceph/ceph.conf ceph-config/
cp /etc/ceph/ceph.client.admin.keyring ceph-config/

# Generate SSH key for head container
ssh-keygen -t rsa -b 4096 -f ssh-auth/cbt_head_rsa -N ""

# Create authorized_keys for clients
cp ssh-auth/cbt_head_rsa.pub ssh-auth/authorized_keys

# Build Docker image
docker build -t cbt:latest .
```

#### Step 2: Deploy to Client Hosts

For each client host, run these commands:

```bash
# Set client hostname
CLIENT_HOST="client1.example.com"

# Create directory on client
ssh $CLIENT_HOST "mkdir -p ~/cbt-docker/{ceph-config,ssh-auth}"

# Copy necessary files
scp Dockerfile requirements.txt *.py $CLIENT_HOST:~/cbt-docker/
scp -r benchmark cluster client_endpoints $CLIENT_HOST:~/cbt-docker/
scp ceph-config/* $CLIENT_HOST:~/cbt-docker/ceph-config/
scp ssh-auth/authorized_keys $CLIENT_HOST:~/cbt-docker/ssh-auth/
scp docker-compose.client.yml $CLIENT_HOST:~/cbt-docker/

# Build and start container on client
ssh $CLIENT_HOST "cd ~/cbt-docker && docker build -t cbt:latest ."
ssh $CLIENT_HOST "cd ~/cbt-docker && \
  CLIENT_HOSTNAME=$CLIENT_HOST \
  CEPH_CONF_DIR=./ceph-config \
  SSH_AUTH_DIR=./ssh-auth \
  docker-compose -f docker-compose.client.yml up -d"
```

#### Step 3: Start Head Container

```bash
# On head node
HEAD_HOSTNAME=$(hostname)
CEPH_CONF_DIR=./ceph-config \
SSH_KEY_DIR=./ssh-auth \
docker-compose -f docker-compose.head.yml up -d
```

#### Step 4: Verify Connectivity

```bash
# Test SSH from head to clients
docker exec cbt-head ssh -i /root/.ssh/cbt_head_rsa root@client1.example.com hostname
docker exec cbt-head ssh -i /root/.ssh/cbt_head_rsa root@client2.example.com hostname

# Test pdsh
docker exec cbt-head pdsh -w client1.example.com,client2.example.com hostname
```

### Creating Multi-Host Configuration

Create a CBT YAML configuration that uses your actual hostnames:

```yaml
cluster:
  user: 'root'
  # Use actual hostname/IP of head node container host
  head: "head.example.com"
  # Use actual hostnames/IPs of client container hosts
  clients: ["client1.example.com", "client2.example.com", "client3.example.com"]
  use_existing: True
  conf_file: '/etc/ceph/ceph.conf'
  iterations: 1
  tmp_dir: "/tmp/cbt"
  archive_dir: "/cbt/archive"

benchmarks:
  librbdfio:
    time: 300
    vol_size: 16384
    mode: [write, read, randwrite, randread]
    op_size: [4194304, 4096]
    iodepth: [64]
    numjobs: [1]
    cmd_path: '/usr/bin/fio'
    volumes_per_client: 1
```

**Important:** The `clients` list must contain the actual hostnames or IP addresses where the client containers are running, NOT Docker container names.

### Running Multi-Host Benchmarks

```bash
# Access head container
docker exec -it cbt-head bash

# Inside container, verify you can reach clients
pdsh -w client1.example.com,client2.example.com hostname

# Run benchmark
python3 cbt.py --archive=/cbt/archive /cbt/configs/your-config.yaml

# Results will be in the archive directory on the head node
```

### Stopping Multi-Host Deployment

```bash
# On head node
docker-compose -f docker-compose.head.yml down

# On each client host
ssh client1.example.com "cd ~/cbt-docker && docker-compose -f docker-compose.client.yml down"
ssh client2.example.com "cd ~/cbt-docker && docker-compose -f docker-compose.client.yml down"
```

### Multi-Host Networking Considerations

1. **Host Networking Mode**: Both head and client containers use `network_mode: "host"` to:
   - Avoid NAT and port mapping complexity
   - Allow direct access to Ceph cluster
   - Enable containers to be reachable by their host's hostname/IP

2. **DNS/Hostname Resolution**: Ensure client hostnames are resolvable from the head node:
   ```bash
   # Test from head node host
   ping client1.example.com
   ping client2.example.com
   ```

3. **Firewall**: Ensure SSH (port 22) is allowed between hosts

4. **Ceph Network**: All hosts must be able to reach Ceph MONs and OSDs directly

### Multi-Host Troubleshooting

#### SSH Connection Fails

```bash
# Check if client container is running
ssh client1.example.com "docker ps | grep cbt-client"

# Check if SSH daemon is running in container
ssh client1.example.com "docker exec cbt-client ps aux | grep sshd"

# Test SSH directly
docker exec cbt-head ssh -v -i /root/.ssh/cbt_head_rsa root@client1.example.com hostname
```

#### Hostname Not Resolving

```bash
# Use IP addresses instead of hostnames in CBT config
clients: ["192.168.1.10", "192.168.1.11"]

# Or add to /etc/hosts on head node host
echo "192.168.1.10 client1.example.com" >> /etc/hosts
```

#### Ceph Connection Issues

```bash
# Verify Ceph config is correct on all hosts
ssh client1.example.com "docker exec cbt-client cat /etc/ceph/ceph.conf"

# Test Ceph connectivity from client
ssh client1.example.com "docker exec cbt-client ceph -s"
ssh client1.example.com "docker exec cbt-client rbd ls"
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
