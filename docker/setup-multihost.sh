#!/bin/bash
# CBT Docker Multi-Host Setup Script
# Sets up CBT Docker environment across multiple hosts
# Run this on the HEAD NODE

set -e

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Multi-host CBT Docker setup script. Run this on the HEAD NODE.

OPTIONS:
    -c, --clients HOSTS     Comma-separated list of client hostnames/IPs
                           Example: client1.example.com,client2.example.com,192.168.1.101

    -u, --user USER        SSH user for client hosts (default: root)

    -k, --key PATH         Path to SSH private key for head node (default: ~/.ssh/id_rsa)

    -h, --help             Display this help message

EXAMPLES:
    # Setup with two clients
    $0 --clients client1.example.com,client2.example.com

    # Setup with custom SSH user and key
    $0 --clients 192.168.1.10,192.168.1.11 --user cbt --key ~/.ssh/cbt_rsa

PREREQUISITES:
    1. Docker installed on head and all client hosts
    2. SSH access from head to all client hosts
    3. Ceph cluster accessible from all hosts
    4. ceph.conf and keyring available

EOF
    exit 1
}

# Parse command line arguments
CLIENTS=""
SSH_USER="root"
SSH_KEY="$HOME/.ssh/id_rsa"

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--clients)
            CLIENTS="$2"
            shift 2
            ;;
        -u|--user)
            SSH_USER="$2"
            shift 2
            ;;
        -k|--key)
            SSH_KEY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate inputs
if [ -z "$CLIENTS" ]; then
    print_error "Client hosts not specified. Use --clients option."
    usage
fi

if [ ! -f "$SSH_KEY" ]; then
    print_error "SSH key not found: $SSH_KEY"
    exit 1
fi

print_header "CBT Multi-Host Docker Setup"
echo ""
print_info "Head node: $(hostname)"
print_info "Client hosts: $CLIENTS"
print_info "SSH user: $SSH_USER"
print_info "SSH key: $SSH_KEY"
echo ""

# Convert comma-separated list to array
IFS=',' read -ra CLIENT_ARRAY <<< "$CLIENTS"

# Check prerequisites
print_header "Checking Prerequisites"

# Check Docker on head
if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed on head node"
    exit 1
fi
print_info "✓ Docker installed on head node"

# Check docker-compose on head
if ! command -v docker-compose &> /dev/null; then
    print_error "docker-compose is not installed on head node"
    exit 1
fi
print_info "✓ docker-compose installed on head node"

# Test SSH connectivity to clients and check Docker
print_info "Checking client hosts..."
for client in "${CLIENT_ARRAY[@]}"; do
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        ${SSH_USER}@${client} "command -v docker" &>/dev/null; then
        print_info "  ✓ $client - SSH OK, Docker installed"
    else
        print_error "  ✗ $client - Cannot SSH or Docker not installed"
        exit 1
    fi
done

# Create local directories
print_header "Creating Directories"
mkdir -p ceph-config configs archive ssh-auth
print_info "Created local directories"

# Check for Ceph configuration
print_header "Checking Ceph Configuration"
if [ ! -f "ceph-config/ceph.conf" ]; then
    print_warn "No ceph.conf found in ceph-config/"
    if [ -f "/etc/ceph/ceph.conf" ]; then
        read -p "Copy from /etc/ceph/ceph.conf? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            cp /etc/ceph/ceph.conf ceph-config/
            print_info "Copied ceph.conf"
        fi
    fi
fi

if [ ! -f "ceph-config/ceph.client.admin.keyring" ]; then
    print_warn "No Ceph keyring found in ceph-config/"
    if [ -f "/etc/ceph/ceph.client.admin.keyring" ]; then
        read -p "Copy from /etc/ceph/ceph.client.admin.keyring? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            cp /etc/ceph/ceph.client.admin.keyring ceph-config/
            print_info "Copied keyring"
        fi
    fi
fi

# Generate SSH key for head container if needed
print_header "Setting Up SSH Keys"
HEAD_SSH_KEY="ssh-auth/cbt_head_rsa"
if [ ! -f "$HEAD_SSH_KEY" ]; then
    print_info "Generating SSH key for head container..."
    ssh-keygen -t rsa -b 4096 -f "$HEAD_SSH_KEY" -N "" -C "cbt-head-docker"
    print_info "SSH key generated: $HEAD_SSH_KEY"
else
    print_info "Using existing SSH key: $HEAD_SSH_KEY"
fi

# Create authorized_keys file for clients
cat "${HEAD_SSH_KEY}.pub" > ssh-auth/authorized_keys
chmod 644 ssh-auth/authorized_keys
print_info "Created authorized_keys file"

# Build Docker image on head
print_header "Building Docker Image on Head Node"
docker build -t cbt:latest .
print_info "Docker image built on head node"

# Copy files to client hosts and build image
print_header "Deploying to Client Hosts"
for client in "${CLIENT_ARRAY[@]}"; do
    print_info "Setting up $client..."

    # Create remote directory
    ssh -i "$SSH_KEY" ${SSH_USER}@${client} "mkdir -p ~/cbt-docker"

    # Copy necessary files
    print_info "  Copying files to $client..."
    scp -i "$SSH_KEY" -r \
        Dockerfile requirements.txt \
        *.py benchmark/ cluster/ client_endpoints/ \
        monitoring.py common.py settings.py log_support.py \
        ${SSH_USER}@${client}:~/cbt-docker/ 2>&1 | grep -v "^$" || true

    # Copy Ceph config
    ssh -i "$SSH_KEY" ${SSH_USER}@${client} "mkdir -p ~/cbt-docker/ceph-config"
    scp -i "$SSH_KEY" ceph-config/* ${SSH_USER}@${client}:~/cbt-docker/ceph-config/ 2>&1 | grep -v "^$" || true

    # Copy SSH authorized_keys
    ssh -i "$SSH_KEY" ${SSH_USER}@${client} "mkdir -p ~/cbt-docker/ssh-auth"
    scp -i "$SSH_KEY" ssh-auth/authorized_keys ${SSH_USER}@${client}:~/cbt-docker/ssh-auth/

    # Copy docker-compose file
    scp -i "$SSH_KEY" docker-compose.client.yml ${SSH_USER}@${client}:~/cbt-docker/

    # Build image on client
    print_info "  Building Docker image on $client..."
    ssh -i "$SSH_KEY" ${SSH_USER}@${client} "cd ~/cbt-docker && docker build -t cbt:latest ."

    # Start container
    print_info "  Starting container on $client..."
    ssh -i "$SSH_KEY" ${SSH_USER}@${client} \
        "cd ~/cbt-docker && CLIENT_HOSTNAME=$client CEPH_CONF_DIR=./ceph-config SSH_AUTH_DIR=./ssh-auth docker-compose -f docker-compose.client.yml up -d"

    print_info "  ✓ $client setup complete"
done

# Start head container
print_header "Starting Head Container"
HEAD_HOSTNAME=$(hostname)
CEPH_CONF_DIR=./ceph-config SSH_KEY_DIR=./ssh-auth \
    docker-compose -f docker-compose.head.yml up -d
print_info "Head container started"

# Wait for containers to be ready
print_info "Waiting for containers to be ready..."
sleep 5

# Test SSH connectivity from head to clients
print_header "Testing SSH Connectivity"
SUCCESS=true
for client in "${CLIENT_ARRAY[@]}"; do
    if docker exec cbt-head ssh -i /root/.ssh/cbt_head_rsa -o StrictHostKeyChecking=no \
        root@${client} hostname &>/dev/null; then
        print_info "  ✓ Can SSH to $client"
    else
        print_error "  ✗ Cannot SSH to $client"
        print_warn "    Make sure the client container is accessible at $client"
        print_warn "    You may need to use the actual hostname/IP of the host"
        SUCCESS=false
    fi
done

# Create example configuration with actual hostnames
print_header "Creating Configuration Files"
cat > configs/librbdfio-multihost.yaml << EOF
# Multi-host librbdfio configuration
# Generated by setup-multihost.sh

cluster:
  user: 'root'
  head: "${HEAD_HOSTNAME}"
  clients: [$(IFS=,; echo "${CLIENT_ARRAY[*]}" | sed 's/,/", "/g' | sed 's/^/"/' | sed 's/$/"/')]
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
    use_existing_volumes: False
    pool_profile: 'default'
    volumes_per_client: 1
    procs_per_volume: 1
    time_based: True
    ramp: 30
    prefill:
      blocksize: '4M'
      numjobs: '1'
EOF

print_info "Created configs/librbdfio-multihost.yaml"

# Print summary
echo ""
print_header "Setup Complete!"
echo ""
if [ "$SUCCESS" = true ]; then
    print_info "All checks passed. You can now run benchmarks:"
    echo ""
    echo "  1. Access the head container:"
    echo "     docker exec -it cbt-head bash"
    echo ""
    echo "  2. Test connectivity to clients:"
    echo "     pdsh -w $(IFS=,; echo "${CLIENT_ARRAY[*]}") hostname"
    echo ""
    echo "  3. Run a benchmark:"
    echo "     python3 cbt.py --archive=/cbt/archive /cbt/configs/librbdfio-multihost.yaml"
    echo ""
    echo "  4. View results:"
    echo "     ls -la archive/"
    echo ""
else
    print_warn "Setup completed with warnings. Please resolve SSH connectivity issues."
fi

print_info "To stop all containers:"
echo "  Head:    docker-compose -f docker-compose.head.yml down"
for client in "${CLIENT_ARRAY[@]}"; do
    echo "  $client: ssh ${SSH_USER}@${client} 'cd ~/cbt-docker && docker-compose -f docker-compose.client.yml down'"
done
