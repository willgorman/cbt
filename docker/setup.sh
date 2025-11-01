#!/bin/bash
# CBT Docker Setup Script
# Automates the setup of SSH keys and container configuration

set -e

echo "=== CBT Docker Setup ==="
echo ""

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed. Please install Docker first."
    exit 1
fi

# Check if docker-compose is installed
if ! command -v docker-compose &> /dev/null; then
    print_error "docker-compose is not installed. Please install docker-compose first."
    exit 1
fi

print_info "Docker and docker-compose are installed."

# Create necessary directories
print_info "Creating directory structure..."
mkdir -p ceph-config configs archive

# Check if Ceph config exists
if [ ! -f "ceph-config/ceph.conf" ]; then
    print_warn "No ceph.conf found in ceph-config/"
    if [ -f "/etc/ceph/ceph.conf" ]; then
        read -p "Copy from /etc/ceph/ceph.conf? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            cp /etc/ceph/ceph.conf ceph-config/
            print_info "Copied ceph.conf"
        fi
    else
        print_warn "Please place your ceph.conf in ceph-config/ directory"
        print_info "Example: cp /etc/ceph/ceph.conf ceph-config/"
    fi
fi

# Check if keyring exists
if [ ! -f "ceph-config/ceph.client.admin.keyring" ]; then
    print_warn "No Ceph keyring found in ceph-config/"
    if [ -f "/etc/ceph/ceph.client.admin.keyring" ]; then
        read -p "Copy from /etc/ceph/ceph.client.admin.keyring? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            cp /etc/ceph/ceph.client.admin.keyring ceph-config/
            print_info "Copied keyring"
        fi
    else
        print_warn "Please place your Ceph keyring in ceph-config/ directory"
        print_info "Example: cp /etc/ceph/ceph.client.admin.keyring ceph-config/"
    fi
fi

# Generate SSH key for CBT if it doesn't exist
SSH_KEY="$HOME/.ssh/cbt_rsa"
if [ ! -f "$SSH_KEY" ]; then
    print_info "Generating SSH key for CBT..."
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "" -C "cbt-docker"
    print_info "SSH key generated: $SSH_KEY"
else
    print_info "Using existing SSH key: $SSH_KEY"
fi

# Copy example configurations if configs directory is empty
if [ -z "$(ls -A configs/)" ]; then
    print_info "Copying example configurations to configs/..."
    cp docker/examples/*.yaml configs/ 2>/dev/null || true
fi

# Build Docker image
print_info "Building Docker image..."
docker build -t cbt:latest .

# Start containers
print_info "Starting Docker containers..."
docker-compose up -d

# Wait for containers to be ready
print_info "Waiting for containers to start..."
sleep 5

# Check if containers are running
if ! docker ps | grep -q cbt-head; then
    print_error "cbt-head container is not running"
    exit 1
fi

print_info "Containers are running"

# Generate SSH key inside head container if it doesn't exist
print_info "Setting up SSH keys in head container..."
docker exec cbt-head bash -c "
    if [ ! -f /root/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N '' -C 'cbt-head'
    fi
"

# Get the public key from head container
HEAD_PUBKEY=$(docker exec cbt-head cat /root/.ssh/id_rsa.pub)

# Distribute SSH key to all client containers
print_info "Distributing SSH keys to client containers..."
for container in $(docker ps --filter "name=cbt-client" --format "{{.Names}}"); do
    print_info "  -> $container"
    docker exec "$container" bash -c "
        mkdir -p /root/.ssh
        echo '$HEAD_PUBKEY' >> /root/.ssh/authorized_keys
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys
    "
done

# Test SSH connectivity
print_info "Testing SSH connectivity..."
SUCCESS=true
for container in $(docker ps --filter "name=cbt-client" --format "{{.Names}}"); do
    hostname=$(docker exec "$container" hostname)
    if docker exec cbt-head ssh -o StrictHostKeyChecking=no "$hostname" hostname &>/dev/null; then
        print_info "  ✓ Can SSH to $hostname"
    else
        print_error "  ✗ Cannot SSH to $hostname"
        SUCCESS=false
    fi
done

if [ "$SUCCESS" = true ]; then
    echo ""
    print_info "=== Setup Complete ==="
    print_info "You can now run benchmarks:"
    echo ""
    echo "  1. Access the head node:"
    echo "     docker exec -it cbt-head bash"
    echo ""
    echo "  2. Run a benchmark:"
    echo "     python3 cbt.py --archive=/cbt/archive /cbt/configs/librbdfio-simple.yaml"
    echo ""
    echo "  3. View results:"
    echo "     ls -la archive/"
    echo ""
    print_info "To stop containers: docker-compose down"
    print_info "To view logs: docker-compose logs -f"
else
    print_error "Setup completed with errors. Please check SSH connectivity."
    exit 1
fi
