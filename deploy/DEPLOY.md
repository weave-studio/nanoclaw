# NanoClaw Deployment Guide

Debian 12 VPS on Hetzner, Tailscale VPN, rootless Podman.

## Prerequisites

- Debian 12 VPS with root SSH access
- Tailscale installed and connected on VPS
- Tailscale installed on your local machine
- SSH key pair (your public key on the VPS)

## Step 1: Security Hardening

SSH into your VPS as root and run the hardening script:

```bash
# From your Mac (via Tailscale IP):
scp deploy/vps-setup.sh root@<tailscale-ip>:~
ssh root@<tailscale-ip>
bash ~/vps-setup.sh
```

**Before closing this SSH session**, test login as the nanoclaw user in another terminal:

```bash
ssh nanoclaw@<tailscale-ip>
```

If that works, root access is no longer needed.

## Step 2: Clone and Build

SSH in as the nanoclaw user:

```bash
ssh nanoclaw@<tailscale-ip>

# Install Node.js 20+
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# Clone your fork
git clone <your-repo-url> ~/nanoclaw
cd ~/nanoclaw

# Install dependencies and build
npm install
npm run build

# Build the agent container
./container/build.sh
```

## Step 3: Configure Environment

```bash
cp .env.example ~/.env
nano ~/.env
```

Required variables:
- `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` — Claude API access
- `ASSISTANT_NAME` — Your assistant's name

## Step 4: Install Systemd Service

```bash
mkdir -p ~/.config/systemd/user
cp ~/nanoclaw/deploy/nanoclaw.service ~/.config/systemd/user/

# Reload, enable, start
systemctl --user daemon-reload
systemctl --user enable nanoclaw
systemctl --user start nanoclaw

# Check status
systemctl --user status nanoclaw
journalctl --user -u nanoclaw -f
```

## Step 5: Set Up Telegram

Run the `/add-telegram` skill via Claude Code on your local machine, or manually:

1. Create a bot via @BotFather on Telegram
2. Add the bot token to your `.env`
3. Restart the service: `systemctl --user restart nanoclaw`

## Step 6: Create Heartbeat Task

Once NanoClaw is running, send a message to set up the heartbeat:

> Schedule a heartbeat task: every 30 minutes, read HEARTBEAT.md and check if anything needs my attention. If not, respond HEARTBEAT_OK.

## Verification Checklist

From your Mac (or any machine outside the VPS):

```bash
# Firewall: all ports should be filtered/closed
nmap <vps-public-ip>

# From the VPS as nanoclaw user:
podman info | grep rootless              # Should show true
systemctl --user status nanoclaw         # Should show active
loginctl show-user nanoclaw | grep Linger # Should show Linger=yes
```

## Security Summary

| Layer | Protection |
|-------|-----------|
| Tailscale VPN | Zero public ports, encrypted mesh |
| UFW | Deny all incoming on public interfaces |
| SSH | Key-only, no root, fail2ban |
| Rootless Podman | No root daemon, user namespaces |
| Container flags | Read-only FS, no-new-privileges, cap-drop=ALL |
| AppArmor + Seccomp | Kernel-level syscall filtering |
| Resource limits | Memory/CPU/PID caps |
| Auto-updates | unattended-upgrades for security patches |
| Systemd hardening | NoNewPrivileges, ProtectSystem, PrivateTmp |
