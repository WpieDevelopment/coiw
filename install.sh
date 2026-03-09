#!/usr/bin/env bash
#
# All-in-one installer for COI (Code on Incus) + coiw wrapper
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wpie/coiw/main/install.sh | bash
#
# Options (passed via environment variables):
#   VERSION=v2.1.0        Pin release version (default: latest)
#   SKIP_INCUS=1          Skip Incus installation (if already installed)
#   SKIP_ZFS=1            Skip ZFS installation
#   ZFS_SIZE=70GiB        ZFS pool size (default: 70GiB)
#   SUBNET=10.10.10.1/24  Bridge subnet (default: 10.10.10.1/24)
#   SSH_PORT=22           Your SSH port for UFW rules (default: auto-detect)
#
# Examples:
#   # Full install on fresh machine
#   curl -fsSL https://raw.githubusercontent.com/wpie/coiw/main/install.sh | bash
#
#   # Just update binaries (skip infra)
#   curl -fsSL https://raw.githubusercontent.com/wpie/coiw/main/install.sh | SKIP_INCUS=1 SKIP_ZFS=1 bash
#
#   # Custom settings
#   curl -fsSL ... | ZFS_SIZE=100GiB SSH_PORT=9322 bash
#

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

REPO="${REPO:-wpie/coiw}"
INSTALL_DIR="/usr/local/bin"
ZFS_SIZE="${ZFS_SIZE:-70GiB}"
SUBNET="${SUBNET:-10.10.10.1/24}"
SUBNET_BASE="${SUBNET%.*}"  # e.g., 10.10.10
SUBNET_CIDR="${SUBNET_BASE}.0/24"

# ── Helpers ───────────────────────────────────────────────────────────────────

info()  { echo -e "\033[32m>\033[0m $*"; }
warn()  { echo -e "\033[33m!\033[0m $*"; }
err()   { echo -e "\033[31mx\033[0m $*" >&2; }
step()  { echo -e "\n\033[1m[$1/$TOTAL_STEPS] $2\033[0m"; }

check() {
    if command -v "$1" &>/dev/null; then
        return 0
    fi
    return 1
}

TOTAL_STEPS=6

# ── Detect environment ────────────────────────────────────────────────────────

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *)       err "Unsupported architecture: $ARCH"; exit 1 ;;
esac

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
if [ "$OS" != "linux" ]; then
    err "Unsupported OS: $OS (only linux is supported)"
    exit 1
fi

# Detect SSH port
if [ -z "${SSH_PORT:-}" ]; then
    SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | grep -oP '\d+$' | head -1)
    SSH_PORT="${SSH_PORT:-22}"
fi

# Determine release version
if [ -n "${VERSION:-}" ]; then
    CLI_VERSION="$VERSION"
else
    info "Fetching latest release version..."
    CLI_VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
fi

echo ""
echo "========================================="
echo "  COI Installer"
echo "========================================="
echo "  OS/Arch:    ${OS}/${ARCH}"
echo "  Release:    ${CLI_VERSION}"
echo "  SSH port:   ${SSH_PORT}"
echo "  Subnet:     ${SUBNET}"
echo "  ZFS size:   ${ZFS_SIZE}"
echo "========================================="
echo ""

# ── Step 1: Install binaries (coiw + coi) ────────────────────────────────────

step 1 "Installing coiw + coi binaries"

BASE_URL="https://github.com/${REPO}/releases/download/${CLI_VERSION}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

info "Downloading coiw-${OS}-${ARCH}..."
curl -fsSL "${BASE_URL}/coiw-${OS}-${ARCH}" -o "${TMPDIR}/coiw"

info "Downloading coi-${OS}-${ARCH}..."
curl -fsSL "${BASE_URL}/coi-${OS}-${ARCH}" -o "${TMPDIR}/coi"

chmod +x "${TMPDIR}/coiw" "${TMPDIR}/coi"

sudo cp "${TMPDIR}/coiw" "${INSTALL_DIR}/coiw"
sudo cp "${TMPDIR}/coi" "${INSTALL_DIR}/coi"
sudo ln -sf "${INSTALL_DIR}/coi" "${INSTALL_DIR}/claude-on-incus"

info "coiw $(coiw version 2>/dev/null || echo 'installed')"
info "coi $(coi --version 2>/dev/null || echo 'installed')"

# ── Step 2: Install Incus ────────────────────────────────────────────────────

step 2 "Incus"

if [ "${SKIP_INCUS:-}" = "1" ]; then
    info "Skipping (SKIP_INCUS=1)"
elif check incus; then
    info "Already installed: $(incus version 2>/dev/null | head -1)"
else
    info "Installing Incus..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq incus incus-client

    info "Adding $USER to incus-admin group..."
    sudo usermod -aG incus-admin "$USER"

    info "Initializing Incus..."
    sudo incus admin init --auto

    info "Configuring bridge subnet ${SUBNET}..."
    sg incus-admin -c "incus network set incusbr0 ipv4.address ${SUBNET}"
    sg incus-admin -c "incus network set incusbr0 ipv4.nat true"

    info "Incus installed and initialized"
    warn "You MUST log out and back in for the incus-admin group to take effect!"
fi

# ── Step 3: Install ZFS ──────────────────────────────────────────────────────

step 3 "ZFS storage pool"

if [ "${SKIP_ZFS:-}" = "1" ]; then
    info "Skipping (SKIP_ZFS=1)"
elif sg incus-admin -c "incus storage show zfs-pool" &>/dev/null 2>&1; then
    info "ZFS pool already exists"
elif incus storage show zfs-pool &>/dev/null 2>&1; then
    info "ZFS pool already exists"
else
    info "Installing ZFS utilities..."
    sudo apt-get install -y -qq zfsutils-linux

    info "Creating ZFS pool (${ZFS_SIZE})..."
    if ! incus storage create zfs-pool zfs size="${ZFS_SIZE}" 2>/dev/null; then
        sg incus-admin -c "incus storage create zfs-pool zfs size=${ZFS_SIZE}"
    fi

    info "Setting ZFS as default storage..."
    if ! incus profile device set default root pool=zfs-pool 2>/dev/null; then
        sg incus-admin -c "incus profile device set default root pool=zfs-pool"
    fi

    info "ZFS pool created (${ZFS_SIZE})"
fi

# ── Step 4: Fix UFW for Incus ────────────────────────────────────────────────

step 4 "Firewall (UFW) configuration"

if ! check ufw; then
    warn "UFW not found, skipping firewall configuration"
elif grep -q "incusbr0" /etc/ufw/before.rules 2>/dev/null; then
    info "UFW already configured for incusbr0"
else
    info "Detected SSH port: ${SSH_PORT}"
    info "Ensuring SSH port ${SSH_PORT} is allowed..."
    sudo ufw allow "${SSH_PORT}/tcp" 2>/dev/null || true

    # Disable firewalld if present (conflicts with UFW)
    if systemctl is-active firewalld &>/dev/null; then
        warn "Disabling firewalld (conflicts with UFW + Incus)..."
        sudo systemctl stop firewalld
        sudo systemctl disable firewalld
    fi

    info "Adding incusbr0 bridge rules to UFW..."

    sudo cp /etc/ufw/before.rules /etc/ufw/before.rules.bak

    sudo sed -i '/^-A ufw-before-input -i lo -j ACCEPT$/a \
\
# allow all on incusbr0 (Incus bridge) - added by COI installer\
-A ufw-before-input -i incusbr0 -j ACCEPT\
-A ufw-before-output -o incusbr0 -j ACCEPT\
-A ufw-before-forward -i incusbr0 -j ACCEPT\
-A ufw-before-forward -o incusbr0 -j ACCEPT' /etc/ufw/before.rules

    if ! grep -q "NAT table rules for Incus" /etc/ufw/before.rules; then
        cat << EOF | sudo tee -a /etc/ufw/before.rules > /dev/null

# NAT table rules for Incus - added by COI installer
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${SUBNET_CIDR} ! -d ${SUBNET_CIDR} -j MASQUERADE
COMMIT
EOF
    fi

    info "Enabling IP forwarding..."
    sudo sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

    info "Reloading UFW..."
    sudo ufw --force disable
    sudo ufw --force enable

    info "Restarting Incus..."
    sudo systemctl restart incus

    info "UFW configured for Incus"
fi

# ── Step 5: COI config ───────────────────────────────────────────────────────

step 5 "COI configuration"

COI_CONFIG_DIR="${HOME}/.config/coi"
COI_CONFIG="${COI_CONFIG_DIR}/config.toml"

if [ -f "$COI_CONFIG" ]; then
    info "Config already exists: ${COI_CONFIG}"
else
    info "Creating default config..."
    mkdir -p "$COI_CONFIG_DIR"
    cat > "$COI_CONFIG" << 'EOF'
[network]
mode = "open"

[tool]
name = "claude"

[limits.cpu]
count = "2"

[limits.memory]
limit = "4GiB"
enforce = "soft"
swap = "false"
EOF
    info "Config written to ${COI_CONFIG}"
    info "Edit this file to adjust CPU/memory limits for your machine"
fi

# ── Step 6: Build COI image ──────────────────────────────────────────────────

step 6 "COI container image"

HAS_IMAGE=false
if incus image list --format=csv 2>/dev/null | grep -q "^coi,"; then
    HAS_IMAGE=true
elif sg incus-admin -c "incus image list --format=csv" 2>/dev/null | grep -q "^coi,"; then
    HAS_IMAGE=true
fi

if [ "$HAS_IMAGE" = true ]; then
    info "COI image already exists"
else
    COI_REPO_DIR="${HOME}/code-on-incus"
    if [ ! -d "$COI_REPO_DIR" ]; then
        info "Cloning code-on-incus repository..."
        git clone https://github.com/mensfeld/code-on-incus.git "$COI_REPO_DIR"
    fi

    info "Building COI image (this takes 3-5 minutes)..."
    cd "$COI_REPO_DIR"
    if ! coi build 2>/dev/null; then
        sg incus-admin -c "coi build"
    fi
    info "COI image built"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "========================================="
echo "  Installation complete!"
echo "========================================="
echo ""
echo "  Binaries:"
echo "    ${INSTALL_DIR}/coiw"
echo "    ${INSTALL_DIR}/coi"
echo ""
echo "  Config:"
echo "    ${COI_CONFIG_DIR}/config.toml"
echo ""

if ! groups | grep -q incus-admin; then
    echo ""
    warn "IMPORTANT: Log out and back in for incus-admin group to take effect!"
    echo "  Then run: coi health"
    echo ""
fi

echo "  Quick start:"
echo "    cd ~/your-project"
echo "    coiw start"
echo ""
echo "  Update later:"
echo "    coiw update"
echo ""
echo "  Verify setup:"
echo "    coi health"
echo ""
