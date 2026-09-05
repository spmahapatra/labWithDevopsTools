#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/devbox-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Parse command-line arguments
INSTALL_DESKTOP=false

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

OPTIONS:
  --with-desktop    Install XFCE desktop, XRDP, and Firefox (optional)
  --help            Show this help message

Examples:
  sudo $0                    # Server-only installation
  sudo $0 --with-desktop     # Full installation with desktop environment
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

echo "======================================================"
echo " Remote DevOps Workstation Installer (Ultra Minimal)"
echo " Ubuntu 22.04"
echo " Started: $(date)"
if [[ "$INSTALL_DESKTOP" == true ]]; then
  echo " Mode: WITH Desktop (XFCE + XRDP)"
else
  echo " Mode: Server-only (no desktop)"
fi
echo "======================================================"

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run with sudo: sudo $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
REAL_USER="${SUDO_USER:-ubuntu}"

echo
echo ">>> Detecting system..."
echo "Architecture: $(uname -m)"
grep -E '^(NAME|VERSION|PRETTY_NAME)=' /etc/os-release || true

echo
echo ">>> Updating apt metadata..."
apt-get update -y

# Skipping full upgrade to reduce disk usage
# apt-get upgrade -y

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

if [[ "$INSTALL_DESKTOP" == true ]]; then
  echo
  echo ">>> Installing desktop + XRDP packages..."
  apt-get install -y --no-install-recommends \
    xrdp \
    xorgxrdp \
    xfce4 \
    xfce4-terminal \
    dbus-x11 \
    policykit-1 \
    firefox-esr

  echo
  echo ">>> Configuring XRDP for XFCE..."
  systemctl enable xrdp
  usermod -a -G ssl-cert xrdp || true

  cat > /etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
if [ -r /etc/profile ]; then
  . /etc/profile
fi
if [ -r "$HOME/.profile" ]; then
  . "$HOME/.profile"
fi
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_DESKTOP=xfce
exec startxfce4
EOF

  chmod +x /etc/xrdp/startwm.sh
  systemctl restart xrdp
else
  echo
  echo ">>> Skipping desktop packages (use --with-desktop to install)"
fi

echo
echo ">>> Installing Docker..."
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

systemctl enable docker
systemctl start docker

echo "Docker version:"
docker --version || true
docker info | grep -i "Docker Root Dir" || true

usermod -aG docker "$REAL_USER" || true

echo
echo ">>> Installing Node.js LTS..."
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y --no-install-recommends nodejs
fi
node --version || true
npm --version || true

echo
echo ">>> Installing AWS CLI..."
if ! command -v aws >/dev/null 2>&1; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) AWS_ARCH="x86_64" ;;
    aarch64) AWS_ARCH="aarch64" ;;
    *) AWS_ARCH="" ;;
  esac

  if [[ -n "$AWS_ARCH" ]]; then
    curl -fsSL -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip"
    rm -rf /tmp/aws
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install --update
    rm -rf /tmp/aws /tmp/awscliv2.zip
  else
    echo "Unsupported architecture for AWS CLI: $ARCH"
  fi
fi
aws --version || true

echo
echo ">>> Installing kubectl..."
if ! command -v kubectl >/dev/null 2>&1; then
  KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  KARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
  curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/${KARCH}/kubectl"
  chmod +x /usr/local/bin/kubectl
fi
kubectl version --client || true

echo
echo ">>> Installing Helm..."
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version || true

echo
echo ">>> Installing Terraform..."
if ! command -v terraform >/dev/null 2>&1; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/hashicorp.list
  apt-get update -y
  apt-get install -y --no-install-recommends terraform
fi
terraform version || true

echo
echo ">>> Installing Minikube..."
if ! command -v minikube >/dev/null 2>&1; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) MK_ARCH="amd64" ;;
    aarch64) MK_ARCH="arm64" ;;
    *) MK_ARCH="" ;;
  esac

  if [[ -n "$MK_ARCH" ]]; then
    curl -fsSL -o /usr/local/bin/minikube "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${MK_ARCH}"
    chmod +x /usr/local/bin/minikube
  else
    echo "Unsupported architecture for Minikube: $ARCH"
  fi
fi
minikube version || true

echo
echo ">>> Installing k9s..."
if ! command -v k9s >/dev/null 2>&1; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) K9S_ARCH="amd64" ;;
    aarch64) K9S_ARCH="arm64" ;;
    *) K9S_ARCH="" ;;
  esac

  if [[ -n "$K9S_ARCH" ]]; then
    K9S_VERSION="$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest | jq -r .tag_name)"
    curl -fsSL -o /tmp/k9s.tar.gz "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${K9S_ARCH}.tar.gz"
    tar -xzf /tmp/k9s.tar.gz -C /tmp
    install -m 0755 /tmp/k9s /usr/local/bin/k9s
    rm -f /tmp/k9s /tmp/k9s.tar.gz /tmp/README.md /tmp/LICENSE
  else
    echo "Unsupported architecture for k9s: $ARCH"
  fi
fi
k9s version || true

if [[ "$INSTALL_DESKTOP" == true ]]; then
  echo
  echo ">>> Browser check..."
  firefox --version || true
fi

echo
echo ">>> Firewall rules (not enabling automatically)..."
ufw allow 22/tcp
if [[ "$INSTALL_DESKTOP" == true ]]; then
  ufw allow 3389/tcp
  echo "UFW configured for SSH + RDP."
else
  echo "UFW configured for SSH only."
fi

echo
echo ">>> Creating workspace..."
mkdir -p /opt/workspace /opt/scripts
chown -R "$REAL_USER:$REAL_USER" /opt/workspace /opt/scripts 2>/dev/null || true

echo
echo ">>> Cleanup (space saving)..."
apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/* /var/tmp/*
docker system prune -af --volumes || true

DEVBOX_MODE="Server-only"
if [[ "$INSTALL_DESKTOP" == true ]]; then
  DEVBOX_MODE="Desktop (XFCE + XRDP)"
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

Installed:
- Docker
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
- Minimal XFCE
- XRDP (RDP access)
- Firefox ESR

RDP:
SERVER-IP:3389

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
# FINAL VALIDATION REPORT
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

if [[ "$INSTALL_DESKTOP" == true ]]; then
  check_cmd "XRDP service active" "systemctl is-active --quiet xrdp"
fi

check_cmd "Docker service active" "systemctl is-active --quiet docker"
check_cmd "Docker CLI" "command -v docker"
check_cmd "Docker Compose" "docker compose version"
check_cmd "Node.js" "command -v node"
check_cmd "npm" "command -v npm"
check_cmd "AWS CLI" "command -v aws"
check_cmd "kubectl" "command -v kubectl"
check_cmd "Helm" "command -v helm"
check_cmd "Terraform" "command -v terraform"
check_cmd "Minikube" "command -v minikube"
check_cmd "Ansible" "command -v ansible"
check_cmd "k9s" "command -v k9s"

if [[ "$INSTALL_DESKTOP" == true ]]; then
  check_cmd "Firefox" "command -v firefox"
fi

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
  echo "kubectl:     $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null || echo N/A)"
  echo "Helm:        $(helm version --short 2>/dev/null || echo N/A)"
  echo "Terraform:   $(terraform version 2>/dev/null | head -1 || echo N/A)"
  echo "Minikube:    $(minikube version --short 2>/dev/null || minikube version 2>/dev/null | head -1 || echo N/A)"
  echo "Ansible:     $(ansible --version 2>/dev/null | head -1 || echo N/A)"
  echo "k9s:         $(k9s version 2>/dev/null | head -1 || echo N/A)"
  if [[ "$INSTALL_DESKTOP" == true ]]; then
    echo "Firefox:     $(firefox --version 2>/dev/null || echo N/A)"
  fi
  echo
  echo "Docker Root: $(docker info 2>/dev/null | awk -F': ' '/Docker Root Dir/ {print $2}' || echo N/A)"
  echo
  echo "--------------------------------------------------------"
  echo "Network listeners"
  echo "--------------------------------------------------------"
  ss -lntp | grep -E ':(22|3389)\b' || true
  echo
  echo "--------------------------------------------------------"
  echo "Disk usage"
  echo "--------------------------------------------------------"
  df -h
  echo
  docker system df 2>/dev/null || true
  echo
  echo "--------------------------------------------------------"
  echo "Summary"
  echo "--------------------------------------------------------"
  echo "PASS: ${PASS_COUNT}"
  echo "FAIL: ${FAIL_COUNT}"
} >> "$STATUS_FILE"

chmod 600 "$STATUS_FILE"

echo
echo ">>> Status checks"
if [[ "$INSTALL_DESKTOP" == true ]]; then
  systemctl --no-pager --full status xrdp | head -15 || true
fi
docker ps || true
ss -lntp | grep -E ':(22|3389)\b' || true

echo
echo ">>> Final report"
cat "$STATUS_FILE"

echo
echo "======================================================"
if [[ "$INSTALL_DESKTOP" == true ]]; then
  echo " INSTALLATION COMPLETE (MINIMAL XFCE + XRDP)"
  echo "======================================================"
  echo "Next:"
  echo "1) Reboot: sudo reboot"
  echo "2) RDP to: SERVER-IP:3389"
  echo "3) Start minikube (small footprint):"
  echo "   minikube start --driver=docker --memory=2200 --cpus=2 --disk-size=6000mb"
  echo "4) Review reports:"
  echo "   sudo cat /opt/DEVBOX-INFO.txt"
  echo "   sudo cat /opt/DEVBOX-STATUS.txt"
else
  echo " INSTALLATION COMPLETE (SERVER-ONLY)"
  echo "======================================================"
  echo "Next:"
  echo "1) Reboot: sudo reboot"
  echo "2) Start minikube (small footprint):"
  echo "   minikube start --driver=docker --memory=2200 --cpus=2 --disk-size=6000mb"
  echo "3) Review reports:"
  echo "   sudo cat /opt/DEVBOX-INFO.txt"
  echo "   sudo cat /opt/DEVBOX-STATUS.txt"
fi
echo "======================================================"
