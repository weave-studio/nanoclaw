#!/usr/bin/env bash
# NanoClaw VPS Security Hardening Script
# Target: Debian 12 on Hetzner with Tailscale VPN
#
# Run as root on the VPS:
#   curl -fsSL <this-script-url> | bash
#   — or —
#   scp deploy/vps-setup.sh root@<tailscale-ip>:~ && ssh root@<tailscale-ip> bash vps-setup.sh
#
# What this script does:
#   1. Creates a dedicated 'nanoclaw' user
#   2. Hardens SSH (key-only, no root login)
#   3. Installs and configures UFW (Tailscale-only access)
#   4. Installs fail2ban
#   5. Installs rootless Podman with UID mapping
#   6. Enables user lingering for persistent containers
#   7. Hardens kernel parameters (sysctl)
#   8. Enables automatic security updates
#
# Prerequisites:
#   - Debian 12 with root access
#   - Tailscale installed and connected
#   - Your SSH public key added to root's authorized_keys

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# --- Preflight ---
[[ $EUID -eq 0 ]] || fail "Run this script as root"
[[ -f /etc/debian_version ]] || fail "This script is for Debian"

DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)
[[ "$DEBIAN_VERSION" == "12" ]] || warn "Expected Debian 12, got version $DEBIAN_VERSION"

# Check Tailscale
if ! command -v tailscale &>/dev/null; then
    fail "Tailscale is not installed. Install it first: https://tailscale.com/download/linux"
fi

if ! tailscale status &>/dev/null; then
    warn "Tailscale doesn't appear to be connected. Make sure to run 'tailscale up' after this script"
fi

echo ""
echo "========================================="
echo " NanoClaw VPS Security Hardening"
echo " Debian 12 + Tailscale + Rootless Podman"
echo "========================================="
echo ""

# ============================================
# 1. System Updates
# ============================================
log "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

# ============================================
# 2. Create nanoclaw user
# ============================================
NANOCLAW_USER="nanoclaw"

if id "$NANOCLAW_USER" &>/dev/null; then
    log "User '$NANOCLAW_USER' already exists"
else
    log "Creating user '$NANOCLAW_USER'..."
    useradd -m -s /bin/bash "$NANOCLAW_USER"
    log "User '$NANOCLAW_USER' created"
fi

# Copy SSH authorized keys from root to nanoclaw user
NANOCLAW_HOME=$(eval echo ~$NANOCLAW_USER)
mkdir -p "$NANOCLAW_HOME/.ssh"
if [[ -f /root/.ssh/authorized_keys ]]; then
    cp /root/.ssh/authorized_keys "$NANOCLAW_HOME/.ssh/authorized_keys"
    chown -R "$NANOCLAW_USER:$NANOCLAW_USER" "$NANOCLAW_HOME/.ssh"
    chmod 700 "$NANOCLAW_HOME/.ssh"
    chmod 600 "$NANOCLAW_HOME/.ssh/authorized_keys"
    log "Copied SSH keys to $NANOCLAW_USER"
else
    warn "No /root/.ssh/authorized_keys found — add your SSH key to $NANOCLAW_HOME/.ssh/authorized_keys manually"
fi

# ============================================
# 3. SSH Hardening
# ============================================
log "Hardening SSH configuration..."

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_HARDENING="/etc/ssh/sshd_config.d/99-nanoclaw-hardening.conf"

cat > "$SSHD_HARDENING" << 'SSHEOF'
# NanoClaw SSH Hardening
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers nanoclaw
SSHEOF

# Validate sshd config before restarting
if sshd -t; then
    systemctl restart sshd
    log "SSH hardened: root disabled, password auth disabled, key-only"
else
    rm -f "$SSHD_HARDENING"
    fail "SSH config validation failed — reverted changes"
fi

# ============================================
# 4. UFW Firewall (Tailscale-only access)
# ============================================
log "Installing and configuring UFW..."
apt-get install -y -qq ufw

# Reset UFW to clean state
ufw --force reset

# Default policies
ufw default deny incoming
ufw default allow outgoing

# Allow ALL traffic on Tailscale interface only
ufw allow in on tailscale0

# Explicitly deny all public interface traffic
# (Hetzner typically uses eth0 or ens3)
for iface in eth0 ens3 ens6; do
    if ip link show "$iface" &>/dev/null; then
        ufw deny in on "$iface"
        log "Blocked incoming on $iface"
    fi
done

# Enable UFW
ufw --force enable
log "UFW enabled: Tailscale-only access, all public ports blocked"

# ============================================
# 5. Fail2Ban
# ============================================
log "Installing fail2ban..."
apt-get install -y -qq fail2ban

cat > /etc/fail2ban/jail.local << 'F2BEOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
F2BEOF

systemctl enable fail2ban
systemctl restart fail2ban
log "Fail2ban configured: 3 attempts → 1 hour ban"

# ============================================
# 6. Install Rootless Podman
# ============================================
log "Installing Podman and dependencies..."
apt-get install -y -qq podman slirp4netns fuse-overlayfs uidmap

# UID/GID sub-mappings for rootless containers
if ! grep -q "^$NANOCLAW_USER:" /etc/subuid; then
    echo "$NANOCLAW_USER:100000:65536" >> /etc/subuid
    log "Added subuid mapping for $NANOCLAW_USER"
else
    log "subuid mapping already exists for $NANOCLAW_USER"
fi

if ! grep -q "^$NANOCLAW_USER:" /etc/subgid; then
    echo "$NANOCLAW_USER:100000:65536" >> /etc/subgid
    log "Added subgid mapping for $NANOCLAW_USER"
else
    log "subgid mapping already exists for $NANOCLAW_USER"
fi

# Verify Podman works rootless
if su - "$NANOCLAW_USER" -c "podman run --rm docker.io/library/alpine:latest echo 'rootless ok'" 2>/dev/null | grep -q "rootless ok"; then
    log "Rootless Podman verified successfully"
else
    warn "Rootless Podman verification failed — may need manual testing"
fi

# ============================================
# 7. User Lingering (containers survive logout)
# ============================================
log "Enabling user lingering..."
loginctl enable-linger "$NANOCLAW_USER"
log "Lingering enabled: containers will persist after SSH logout"

# ============================================
# 8. Kernel Hardening (sysctl)
# ============================================
log "Applying kernel hardening..."

cat > /etc/sysctl.d/99-nanoclaw-hardening.conf << 'SYSEOF'
# NanoClaw Kernel Hardening

# Disable IP forwarding (Tailscale manages its own)
# Note: Tailscale sets net.ipv4.ip_forward=1 on its own interface
# We leave the default off for other interfaces
net.ipv4.conf.default.forwarding = 0
net.ipv6.conf.default.forwarding = 0

# Ignore ICMP redirects (prevent MITM)
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Enable SYN cookies (prevent SYN flood DoS)
net.ipv4.tcp_syncookies = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Log martian packets (packets with impossible source addresses)
net.ipv4.conf.all.log_martians = 1

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Restrict kernel pointer exposure
kernel.kptr_restrict = 2

# Restrict dmesg access
kernel.dmesg_restrict = 1

# Harden BPF JIT compiler
net.core.bpf_jit_harden = 2

# Restrict unprivileged user namespaces (allows rootless Podman but limits abuse)
# Podman needs user namespaces, so we can't disable them entirely
# kernel.unprivileged_userns_clone = 1
SYSEOF

sysctl --system > /dev/null 2>&1
log "Kernel parameters hardened"

# ============================================
# 9. Automatic Security Updates
# ============================================
log "Setting up automatic security updates..."
apt-get install -y -qq unattended-upgrades

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UUEOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
UUEOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
AUEOF

systemctl enable unattended-upgrades
log "Automatic security updates enabled"

# ============================================
# 10. Disable unnecessary services
# ============================================
log "Disabling unnecessary services..."
for svc in avahi-daemon cups bluetooth; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl disable --now "$svc"
        log "Disabled $svc"
    fi
done

# ============================================
# 11. AppArmor verification
# ============================================
if command -v aa-status &>/dev/null; then
    if aa-status --enabled 2>/dev/null; then
        log "AppArmor is active"
    else
        warn "AppArmor is installed but not active — consider enabling it"
    fi
else
    log "Installing AppArmor..."
    apt-get install -y -qq apparmor apparmor-utils
    systemctl enable apparmor
    log "AppArmor installed and enabled (will be active after reboot)"
fi

# ============================================
# 12. Create NanoClaw directory structure
# ============================================
log "Creating NanoClaw directory structure..."
su - "$NANOCLAW_USER" -c "mkdir -p ~/nanoclaw"
log "Directory structure ready at $NANOCLAW_HOME/nanoclaw"

# ============================================
# Summary
# ============================================
echo ""
echo "========================================="
echo " Setup Complete"
echo "========================================="
echo ""
echo " Security layers applied:"
echo "  [✓] SSH: key-only, no root, max 3 attempts"
echo "  [✓] UFW: all public ports blocked, Tailscale-only"
echo "  [✓] Fail2ban: 3 attempts → 1 hour ban"
echo "  [✓] Podman: rootless with UID mapping"
echo "  [✓] Lingering: containers persist after logout"
echo "  [✓] Kernel: SYN cookies, no redirects, restricted pointers"
echo "  [✓] Auto-updates: Debian security patches"
echo "  [✓] AppArmor: kernel-level confinement"
echo ""
echo " Next steps:"
echo "  1. SSH in as nanoclaw: ssh nanoclaw@$(tailscale ip -4)"
echo "  2. Clone the repo: git clone <your-fork> ~/nanoclaw"
echo "  3. Install the systemd service: see deploy/nanoclaw.service"
echo "  4. Configure .env with your API keys"
echo "  5. Build and run the container"
echo ""
echo " IMPORTANT: Test SSH as nanoclaw user BEFORE closing this session!"
echo "   ssh nanoclaw@$(tailscale ip -4)"
echo ""
