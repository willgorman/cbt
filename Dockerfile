# CBT (Ceph Benchmarking Tool) Docker Image
# Supports both head node and client node roles for librbdfio benchmarks

FROM ubuntu:22.04

# Build arguments for metadata
ARG BUILD_DATE
ARG VCS_REF
ARG VERSION

# Image metadata following OCI annotations
LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.authors="Ceph Community" \
      org.opencontainers.image.url="https://github.com/ceph/cbt" \
      org.opencontainers.image.documentation="https://github.com/ceph/cbt/blob/master/docker/README.md" \
      org.opencontainers.image.source="https://github.com/ceph/cbt" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.vendor="Ceph Community" \
      org.opencontainers.image.title="CBT - Ceph Benchmarking Tool" \
      org.opencontainers.image.description="Docker container for running Ceph benchmarks with librbdfio support"

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    # Python and pip
    python3 \
    python3-pip \
    # SSH for remote operations (both client and server)
    openssh-client \
    openssh-server \
    # Parallel shell tools
    pdsh \
    # Ceph client tools and libraries
    ceph-common \
    librbd-dev \
    python3-rados \
    python3-rbd \
    # FIO with RBD support
    fio \
    # System utilities
    sudo \
    wget \
    curl \
    procps \
    sysstat \
    util-linux \
    # Network utilities
    net-tools \
    iputils-ping \
    # Monitoring tools (optional but recommended)
    collectl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /cbt

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

# Copy CBT source code
COPY . .

# Make cbt.py executable
RUN chmod +x cbt.py

# Create directories for Ceph configuration and results
RUN mkdir -p /etc/ceph /cbt/archive /root/.ssh

# Configure pdsh to use ssh
ENV PDSH_RCMD_TYPE=ssh

# Set Python path
ENV PYTHONPATH=/cbt:$PYTHONPATH

# Configure SSH for passwordless operation (host keys will be added at runtime)
RUN echo "Host *\n    StrictHostKeyChecking no\n    UserKnownHostsFile=/dev/null" > /root/.ssh/config && \
    chmod 600 /root/.ssh/config

# Configure SSH server for client nodes
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    mkdir -p /run/sshd

# Default command - can be overridden
CMD ["/bin/bash"]
