#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/devbox-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ======================================================
# Parse command-line arguments
# ======================================================

INSTALL_DESKTOP=false

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

OPTIONS:
  --with-desktop    Install XFCE desktop, XRDP, and Firefox
  --help            Show this help message

Examples:
  sudo $0
  sudo $0 --with-desktop
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-desktop)
      INSTALL_DESKTOP=true
      shift
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# ======================================================
# Header
# ======================================================

echo "======================================================"
echo " Remote DevOps Workstation (Ultra Minimal)"
echo " Ubuntu 22.04"
echo " Started: $(date)"

if [[ "$INSTALL_DESKTOP" == true ]]; then
  echo " Mode: WITH Desktop (XFCE + XRDP + Firefox)"
else
  echo " Mode: Server-only (no desktop)"
fi

echo "======================================================"

# ======================================================
# Root check
# ======================================================

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run with sudo: sudo $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

REAL_USER="${SUDO_USER:-ubuntu}"

# ======================================================
# Detect system
# ======================================================

echo
echo ">>> Detecting system..."

echo "Architecture: $(uname -m)"
grep -E '^(NAME|VERSION|PRETTY_NAME)=' /etc/os-release || true

# ======================================================
# Additional NVMe disk
# ======================================================

DISK="/dev/nvme1n1"
MOUNT_POINT="/demo_mnt"

echo
echo ">>> Checking for additional disk: $DISK"

if [[ -b "$DISK" ]]; then

  echo "Found block device $DISK"

  # Detect partitions
  if lsblk -n -o NAME "$DISK" | grep -qE "${DISK##*/}p[0-9]+"; then

    echo "Disk $DISK contains partitions."
    echo "Skipping automatic formatting to avoid data loss."

    echo
    echo "Detected partitions:"
    lsblk "$DISK"

  else

    FSTYPE="$(blkid -s TYPE -o value "$DISK" || true)"

    if [[ -z "$FSTYPE" ]]; then

      echo "Disk appears unformatted."

      echo "Showing partition table:"
      fdisk -l "$DISK" || true

      echo
      echo "Formatting $DISK as ext4."
      echo "WARNING: this will destroy any data on the device."

      mkfs.ext4 -F "$DISK"

      echo
      echo "Creating mount point:"
      mkdir -p "$MOUNT_POINT"

      echo "Mounting $DISK -> $MOUNT_POINT"
      mount "$DISK" "$MOUNT_POINT"

      # Use UUID for persistent mounting
      DISK_UUID="$(blkid -s UUID -o value "$DISK")"

      if [[ -n "$DISK_UUID" ]]; then

        if ! grep -q "$DISK_UUID" /etc/fstab; then
          echo "UUID=$DISK_UUID $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
        fi

      fi

      echo "Mounted $DISK at $MOUNT_POINT"
      echo "fstab updated."

    else

      echo "Disk already has filesystem type: $FSTYPE"

      mkdir -p "$MOUNT_POINT"

      if mountpoint -q "$MOUNT_POINT"; then

        echo "$MOUNT_POINT is already mounted."

      else

        echo "Mounting existing filesystem from $DISK..."

        mount "$DISK" "$MOUNT_POINT"

      fi

      # Persist existing filesystem using UUID
      DISK_UUID="$(blkid -s UUID -o value "$DISK" || true)"

      if [[ -n "$DISK_UUID" ]]; then

        if ! grep -q "$DISK_UUID" /etc/fstab; then
          echo "UUID=$DISK_UUID $MOUNT_POINT $FSTYPE defaults,nofail 0 2" >> /etc/fstab
          echo "Added persistent mount to /etc/fstab."
        fi

      fi

    fi

  fi

else

  echo "$DISK not present — skipping disk setup."

fi

# ======================================================
# APT update
# ======================================================

echo
echo ">>> Updating apt metadata..."

apt-get update -y

# ======================================================
# Minimal base packages
# ======================================================

echo
echo ">>> Installing minimal base packages..."

apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  wget \
  gnupg \
  lsb-release \
  software-properties-common \
  apt-transport-https \
  unzip \
  jq \
  git \
  vim \
  htop \
  net-tools \
  build-essential \
  python3 \
  python3-pip \
  python3-venv \
  ansible \
  ufw

# ======================================================
# Desktop + XRDP + Firefox
# ======================================================

if [[ "$INSTALL_DESKTOP" == true ]]; then

  echo
  echo ">>> Installing desktop + XRDP packages..."

  apt-get install -y --no-install-recommends \
    xrdp \
    xorgxrdp \
    xfce4 \
    xfce4-terminal \
    dbus-x11 \
    policykit-1

  # ----------------------------------------------------
  # Firefox
  #
  # Ubuntu 22.04 provides Firefox as a Snap transitional
  # package. We intentionally install the Mozilla DEB
  # package instead.
  # ----------------------------------------------------

  echo
  echo ">>> Configuring Mozilla Firefox APT repository..."

  install -d -m 0755 /etc/apt/keyrings

  wget -q \
    https://packages.mozilla.org/apt/repo-signing-key.gpg \
    -O /etc/apt/keyrings/packages.mozilla.org.asc

  # Verify Mozilla signing key
  echo
  echo ">>> Verifying Mozilla repository signing key..."

  KEY_FINGERPRINT="$(
    gpg --show-keys --with-colons \
      /etc/apt/keyrings/packages.mozilla.org.asc 2>/dev/null |
      awk -F: '$1=="fpr" {print $10; exit}'
  )"

  EXPECTED_FINGERPRINT="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"

  if [[ "$KEY_FINGERPRINT" != "$EXPECTED_FINGERPRINT" ]]; then
    echo "ERROR: Mozilla signing key fingerprint does not match."
    echo "Expected: $EXPECTED_FINGERPRINT"
    echo "Found:    $KEY_FINGERPRINT"
    exit 1
  fi

  echo "Mozilla signing key verified."

  # Add Mozilla repository
  cat > /etc/apt/sources.list.d/mozilla.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main
EOF

  # Prefer Mozilla Firefox DEB
  cat > /etc/apt/preferences.d/mozilla <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000

# Prevent Ubuntu's transitional Firefox package
# from pulling Firefox back in as a Snap.
Package: firefox
Pin: release o=Ubuntu
Pin-Priority: -1
EOF

  # ----------------------------------------------------
  # Remove existing Firefox Snap if present
  # ----------------------------------------------------

  if command -v snap >/dev/null 2>&1; then

    if snap list firefox >/dev/null 2>&1; then

      echo
      echo ">>> Removing existing Firefox Snap..."

      snap remove firefox || true

    fi

  fi

  # Remove Ubuntu transitional Firefox package if present
  apt-get remove -y firefox 2>/dev/null || true

  echo
  echo ">>> Updating APT after adding Mozilla repository..."

  apt-get update -y

  echo
  echo ">>> Installing Firefox DEB from Mozilla..."

  apt-get install -y --no-install-recommends firefox

  echo
  echo ">>> Firefox installation result:"

  command -v firefox || true
  firefox --version || true

  # ----------------------------------------------------
  # XRDP / XFCE configuration
  # ----------------------------------------------------

  echo
  echo ">>> Configuring XRDP for XFCE..."

  systemctl enable xrdp

  usermod -a -G ssl-cert xrdp || true

  cat > /etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh

# Load system profile
if [ -r /etc/profile ]; then
    . /etc/profile
fi

# Load user profile
if [ -r "$HOME/.profile" ]; then
    . "$HOME/.profile"
fi

# XFCE environment
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_DESKTOP=xfce
export XDG_CONFIG_DIRS=/etc/xdg/xdg-xfce:/etc/xdg
export XDG_DATA_DIRS=/usr/share/xfce4:/usr/local/share:/usr/share

# Avoid inheriting stale DBus/runtime information
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR

# Start a proper DBus session for XFCE
exec dbus-launch --exit-with-session startxfce4
EOF

  chmod +x /etc/xrdp/startwm.sh

  # Restart XRDP
  systemctl restart xrdp

  echo
  echo "XRDP status:"
  systemctl --no-pager --full status xrdp | head -20 || true

else

  echo
  echo ">>> Skipping desktop packages."
  echo "    Use --with-desktop to install XFCE + XRDP + Firefox."

fi

# ======================================================
# Docker
# ======================================================

echo
echo ">>> Installing Docker..."

if ! command -v docker >/dev/null 2>&1; then

  curl -fsSL https://get.docker.com | sh

fi

systemctl enable docker
systemctl start docker

echo
echo "Docker version:"
docker --version || true

echo
echo "Docker Root Dir:"
docker info 2>/dev/null | grep -i "Docker Root Dir" || true

# Add user to Docker group
usermod -aG docker "$REAL_USER" || true

# ======================================================
# Node.js
# ======================================================

echo
echo ">>> Installing Node.js LTS..."

if ! command -v node >/dev/null 2>&1; then

  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -

  apt-get install -y --no-install-recommends nodejs

fi

node --version || true
npm --version || true

# ======================================================
# AWS CLI
# ======================================================

echo
echo ">>> Installing AWS CLI..."

if ! command -v aws >/dev/null 2>&1; then

  ARCH="$(uname -m)"

  case "$ARCH" in
    x86_64)
      AWS_ARCH="x86_64"
      ;;
    aarch64)
      AWS_ARCH="aarch64"
      ;;
    *)
      AWS_ARCH=""
      ;;
  esac

  if [[ -n "$AWS_ARCH" ]]; then

    curl -fsSL \
      -o /tmp/awscliv2.zip \
      "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip"

    rm -rf /tmp/aws

    unzip -q /tmp/awscliv2.zip -d /tmp

    /tmp/aws/install --update

    rm -rf /tmp/aws /tmp/awscliv2.zip

  else

    echo "Unsupported architecture for AWS CLI: $ARCH"

  fi

fi

aws --version || true

# ======================================================
# kubectl
# ======================================================

echo
echo ">>> Installing kubectl..."

if ! command -v kubectl >/dev/null 2>&1; then

  KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"

  KARCH="$(
    uname -m |
    sed 's/x86_64/amd64/;s/aarch64/arm64/'
  )"

  curl -fsSL \
    -o /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/${KVER}/bin/linux/${KARCH}/kubectl"

  chmod +x /usr/local/bin/kubectl

fi

kubectl version --client || true

# ======================================================
# Helm
# ======================================================

echo
echo ">>> Installing Helm..."

if ! command -v helm >/dev/null 2>&1; then

  curl -fsSL \
    https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 |
    bash

fi

helm version || true

# ======================================================
# Terraform
# ======================================================

echo
echo ">>> Installing Terraform..."

if ! command -v terraform >/dev/null 2>&1; then

  install -d -m 0755 /etc/apt/keyrings

  curl -fsSL \
    https://apt.releases.hashicorp.com/gpg |
    gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/hashicorp.list

  apt-get update -y

  apt-get install -y --no-install-recommends terraform

fi

terraform version || true

# ======================================================
# Minikube
# ======================================================

echo
echo ">>> Installing Minikube..."

if ! command -v minikube >/dev/null 2>&1; then

  ARCH="$(uname -m)"

  case "$ARCH" in
    x86_64)
      MK_ARCH="amd64"
      ;;
    aarch64)
      MK_ARCH="arm64"
      ;;
    *)
      MK_ARCH=""
      ;;
  esac

  if [[ -n "$MK_ARCH" ]]; then

    curl -fsSL \
      -o /usr/local/bin/minikube \
      "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${MK_ARCH}"

    chmod +x /usr/local/bin/minikube

  else

    echo "Unsupported architecture for Minikube: $ARCH"

  fi

fi

minikube version || true

# ======================================================
# k9s
# ======================================================

echo
echo ">>> Installing k9s..."

if ! command -v k9s >/dev/null 2>&1; then

  ARCH="$(uname -m)"

  case "$ARCH" in
    x86_64)
      K9S_ARCH="amd64"
      ;;
    aarch64)
      K9S_ARCH="arm64"
      ;;
    *)
      K9S_ARCH=""
      ;;
  esac

  if [[ -n "$K9S_ARCH" ]]; then

    K9S_VERSION="$(
      curl -fsSL \
        https://api.github.com/repos/derailed/k9s/releases/latest |
      jq -r .tag_name
    )"

    curl -fsSL \
      -o /tmp/k9s.tar.gz \
      "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${K9S_ARCH}.tar.gz"

    tar -xzf /tmp/k9s.tar.gz -C /tmp

    install -m 0755 /tmp/k9s /usr/local/bin/k9s

    rm -f \
      /tmp/k9s \
      /tmp/k9s.tar.gz \
      /tmp/README.md \
      /tmp/LICENSE

  else

    echo "Unsupported architecture for k9s: $ARCH"

  fi

fi

k9s version || true

# ======================================================
# Browser validation
# ======================================================

if [[ "$INSTALL_DESKTOP" == true ]]; then

  echo
  echo ">>> Browser check..."

  if command -v firefox >/dev/null 2>&1; then

    echo "[PASS] Firefox executable found:"
    command -v firefox

    echo "Firefox version:"
    firefox --version || true

  else

    echo "[FAIL] Firefox executable not found."

  fi

fi

# ======================================================
# Firewall
# ======================================================

echo
echo ">>> Firewall rules (not enabling automatically)..."

ufw allow 22/tcp

if [[ "$INSTALL_DESKTOP" == true ]]; then

  ufw allow 3389/tcp

  echo "UFW configured for SSH + RDP."

else

  echo "UFW configured for SSH only."

fi

# ======================================================
# Workspace
# ======================================================

echo
echo ">>> Creating workspace..."

mkdir -p /opt/workspace /opt/scripts

chown -R \
  "$REAL_USER:$REAL_USER" \
  /opt/workspace \
  /opt/scripts \
  2>/dev/null || true

# ======================================================
# Demo volume directories
# ======================================================

if [[ -d "$MOUNT_POINT" ]]; then

  echo
  echo ">>> Preparing DemoLab volume..."

  mkdir -p \
    "$MOUNT_POINT/workspace" \
    "$MOUNT_POINT/docker" \
    "$MOUNT_POINT/gitlab" \
    "$MOUNT_POINT/data"

  chown -R \
    "$REAL_USER:$REAL_USER" \
    "$MOUNT_POINT/workspace" \
    "$MOUNT_POINT/gitlab" \
    "$MOUNT_POINT/data" \
    2>/dev/null || true

  echo "DemoLab volume available at:"
  echo "  $MOUNT_POINT"

fi

# ======================================================
# Cleanup
# ======================================================

echo
echo ">>> Cleanup (space saving)..."

apt-get autoremove -y --purge
apt-get clean

rm -rf /var/lib/apt/lists/*
rm -rf /tmp/* /var/tmp/*

# IMPORTANT:
# Do NOT automatically prune Docker volumes.
#
# This machine is intended for GitLab / DemoLab work.
# Docker volumes may contain persistent application data.
#
# Therefore we intentionally DO NOT run:
#
# docker system prune -af --volumes

docker system prune -af || true

# ======================================================
# DEVBOX INFO
# ======================================================

DEVBOX_MODE="Server-only"

if [[ "$INSTALL_DESKTOP" == true ]]; then
  DEVBOX_MODE="Desktop (XFCE + XRDP + Firefox)"
fi

cat > /opt/DEVBOX-INFO.txt <<EOF
========================================================
Remote DevOps Workstation (Ultra Minimal)
========================================================

Created: $(date)
Architecture: $(uname -m)
OS: $(grep '^PRETTY_NAME=' /etc/os-release)
Mode: $DEVBOX_MODE

Workspace:
  /opt/workspace

Demo volume:
  $MOUNT_POINT

Installed:
  - Docker
  - Docker Compose
  - Node.js
  - AWS CLI
  - kubectl
  - Helm
  - Terraform
  - Minikube
  - Ansible
  - k9s

EOF

if [[ "$INSTALL_DESKTOP" == true ]]; then

  cat >> /opt/DEVBOX-INFO.txt <<EOF
Desktop:
  - XFCE
  - XRDP
  - Firefox DEB from Mozilla APT repository

RDP:
  SERVER-IP:3389

XRDP session:
  XFCE + DBus

EOF

fi

cat >> /opt/DEVBOX-INFO.txt <<EOF
Docker Root:
  $(docker info 2>/dev/null | grep -i "Docker Root Dir" || echo "Unknown")

Installation log:
  /var/log/devbox-install.log

========================================================
EOF

chmod 600 /opt/DEVBOX-INFO.txt

# ======================================================
# FINAL VALIDATION
# ======================================================

STATUS_FILE="/opt/DEVBOX-STATUS.txt"

PASS_COUNT=0
FAIL_COUNT=0

check_cmd() {

  local name="$1"
  local cmd="$2"

  if eval "$cmd" >/dev/null 2>&1; then

    echo "[PASS] $name" | tee -a "$STATUS_FILE"

    PASS_COUNT=$((PASS_COUNT+1))

  else

    echo "[FAIL] $name" | tee -a "$STATUS_FILE"

    FAIL_COUNT=$((FAIL_COUNT+1))

  fi
}

echo "========================================================" > "$STATUS_FILE"
echo "DEVBOX FINAL STATUS REPORT" >> "$STATUS_FILE"
echo "Generated: $(date)" >> "$STATUS_FILE"
echo "Host: $(hostname)" >> "$STATUS_FILE"
echo "Mode: $DEVBOX_MODE" >> "$STATUS_FILE"
echo "========================================================" >> "$STATUS_FILE"
echo >> "$STATUS_FILE"

# ------------------------------------------------------
# Desktop
# ------------------------------------------------------

if [[ "$INSTALL_DESKTOP" == true ]]; then

  check_cmd \
    "XRDP service active" \
    "systemctl is-active --quiet xrdp"

  check_cmd \
    "Firefox" \
    "command -v firefox"

fi

# ------------------------------------------------------
# DevOps tools
# ------------------------------------------------------

check_cmd \
  "Docker service active" \
  "systemctl is-active --quiet docker"

check_cmd \
  "Docker CLI" \
  "command -v docker"

check_cmd \
  "Docker Compose" \
  "docker compose version"

check_cmd \
  "Node.js" \
  "command -v node"

check_cmd \
  "npm" \
  "command -v npm"

check_cmd \
  "AWS CLI" \
  "command -v aws"

check_cmd \
  "kubectl" \
  "command -v kubectl"

check_cmd \
  "Helm" \
  "command -v helm"

check_cmd \
  "Terraform" \
  "command -v terraform"

check_cmd \
  "Minikube" \
  "command -v minikube"

check_cmd \
  "Ansible" \
  "command -v ansible"

check_cmd \
  "k9s" \
  "command -v k9s"

# ======================================================
# Version details
# ======================================================

{
  echo
  echo "--------------------------------------------------------"
  echo "Version details"
  echo "--------------------------------------------------------"

  echo "Docker:      $(docker --version 2>/dev/null || echo N/A)"
  echo "Compose:     $(docker compose version 2>/dev/null || echo N/A)"
  echo "Node:        $(node --version 2>/dev/null || echo N/A)"
  echo "npm:         $(npm --version 2>/dev/null || echo N/A)"
  echo "AWS CLI:     $(aws --version 2>/dev/null || echo N/A)"

  echo "kubectl:      $(
    kubectl version --client --short 2>/dev/null ||
    kubectl version --client 2>/dev/null ||
    echo N/A
  )"

  echo "Helm:        $(helm version --short 2>/dev/null || echo N/A)"

  echo "Terraform:    $(
    terraform version 2>/dev/null |
    head -1 ||
    echo N/A
  )"

  echo "Minikube:     $(
    minikube version --short 2>/dev/null ||
    minikube version 2>/dev/null |
    head -1 ||
    echo N/A
  )"

  echo "Ansible:      $(
    ansible --version 2>/dev/null |
    head -1 ||
    echo N/A
  )"

  echo "k9s:          $(
    k9s version 2>/dev/null |
    head -1 ||
    echo N/A
  )"

  if [[ "$INSTALL_DESKTOP" == true ]]; then

    echo "Firefox:      $(
      firefox --version 2>/dev/null ||
      echo N/A
    )"

  fi

  echo
  echo "--------------------------------------------------------"
  echo "Disk / Volume"
  echo "--------------------------------------------------------"

  df -h

  echo

  if [[ -d "$MOUNT_POINT" ]]; then

    echo "Demo volume:"
    df -h "$MOUNT_POINT" || true

    echo
    lsblk "$DISK" 2>/dev/null || true

  fi

  echo
  echo "--------------------------------------------------------"
  echo "Docker"
  echo "--------------------------------------------------------"

  echo "Docker Root:"
  docker info 2>/dev/null |
    awk -F': ' '/Docker Root Dir/ {print $2}' ||
    echo "Unknown"

  echo

  docker system df 2>/dev/null || true

  echo
  echo "--------------------------------------------------------"
  echo "Network listeners"
  echo "--------------------------------------------------------"

  ss -lntp |
    grep -E ':(22|3389)\b' ||
    true

  echo
  echo "--------------------------------------------------------"
  echo "Summary"
  echo "--------------------------------------------------------"

  echo "PASS: ${PASS_COUNT}"
  echo "FAIL: ${FAIL_COUNT}"

} >> "$STATUS_FILE"

chmod 600 "$STATUS_FILE"

# ======================================================
# Status checks
# ======================================================

echo
echo ">>> Status checks"

if [[ "$INSTALL_DESKTOP" == true ]]; then

  systemctl \
    --no-pager \
    --full \
    status xrdp |
    head -15 ||
    true

fi

docker ps || true

ss -lntp |
  grep -E ':(22|3389)\b' ||
  true

# ======================================================
# Final report
# ======================================================

echo
echo ">>> Final report"

cat "$STATUS_FILE"

# ======================================================
# Completion
# ======================================================

echo
echo "======================================================"

if [[ "$INSTALL_DESKTOP" == true ]]; then

  echo " INSTALLATION COMPLETE"
  echo " XFCE + XRDP + Firefox + DevOps Tools"
  echo "======================================================"

  echo
  echo "Next:"
  echo "1) Reboot:"
  echo "   sudo reboot"

  echo
  echo "2) RDP to:"
  echo "   SERVER-IP:3389"

  echo
  echo "3) Login using your Ubuntu user."

  echo
  echo "4) Start Minikube:"
  echo "   minikube start --driver=docker --memory=2200 --cpus=2 --disk-size=6000mb"

  echo
  echo "5) Demo volume:"
  echo "   $MOUNT_POINT"

  echo
  echo "6) Review reports:"
  echo "   sudo cat /opt/DEVBOX-INFO.txt"
  echo "   sudo cat /opt/DEVBOX-STATUS.txt"

else

  echo " INSTALLATION COMPLETE"
  echo " SERVER-ONLY"
  echo "======================================================"

  echo
  echo "Next:"
  echo "1) Reboot:"
  echo "   sudo reboot"

  echo
  echo "2) Start Minikube:"
  echo "   minikube start --driver=docker --memory=2200 --cpus=2 --disk-size=6000mb"

  echo
  echo "3) Review reports:"
  echo "   sudo cat /opt/DEVBOX-INFO.txt"
  echo "   sudo cat /opt/DEVBOX-STATUS.txt"

fi

echo "======================================================"
