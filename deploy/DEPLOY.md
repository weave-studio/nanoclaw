# NanoClaw Deployment Guide

Debian 12 VPS on Hetzner, Tailscale VPN, rootless Docker.

> **This guide was written from a real setup session and includes all known gotchas.**
> Follow it in order — skipping steps causes hard-to-diagnose problems.

---

## Prerequisites

Before starting, you need:
- Hetzner (or similar) Debian 12 VPS with root SSH access
- [Tailscale](https://tailscale.com/download/linux) installed and connected on the VPS
- Tailscale installed on your local machine
- Your SSH public key added to `/root/.ssh/authorized_keys` on the VPS
- A fork of this repo on GitHub

---

## Phase 1: VPS Security Hardening

> **Heads up**: Step 1.6 requires the Hetzner web console (browser-based terminal) since SSH root access gets locked by the hardening script. Keep your Hetzner dashboard accessible.

### 1.1 Run the hardening script

SSH in as root via the Tailscale IP (find it with `tailscale ip -4` on the VPS):

```bash
# From your Mac
scp deploy/vps-setup.sh root@<tailscale-ip>:~
ssh root@<tailscale-ip>
bash ~/vps-setup.sh
```

**Do not close this root session yet.**

### 1.2 Test nanoclaw user SSH (from your Mac)

Open a **new terminal tab** on your Mac and verify:

```bash
ssh nanoclaw@<tailscale-ip>
```

You must confirm this works before closing root access. If it fails, debug from the root session.

### 1.3 Fix the UFW eth0 rule (CRITICAL)

> **Known bug in vps-setup.sh**: The `deny in on eth0` rule blocks outbound responses too, breaking all outgoing connections (git clone, npm install, etc.).

In the **root session**, delete that rule:

```bash
ufw delete deny in on eth0
ufw status verbose
```

The remaining rules should only be:
```
To                         Action      From
--                         ------      ----
Anywhere on tailscale0     ALLOW IN    Anywhere
Anywhere (v6) on tailscale0 ALLOW IN   Anywhere (v6)
```

`default deny incoming` already blocks unsolicited public traffic — the explicit eth0 rule is redundant and harmful.

### 1.4 Fix fail2ban

> **Known issue**: fail2ban crashes on fresh Debian 12 because `/var/log/auth.log` doesn't exist yet.

```bash
touch /var/log/auth.log
systemctl restart fail2ban
systemctl status fail2ban   # should show: active (running)
```

### 1.5 Fix locale warnings

```bash
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
```

Warnings persist in the current session but are gone on next login.

### 1.6 Give nanoclaw user sudo and password

> **Known issue**: The setup script creates nanoclaw with SSH key auth only — no password, no sudo. This blocks the Docker install in Phase 2.

Use the Hetzner web console (not SSH — SSH root is now locked):
1. Hetzner Cloud → your server → **Console** (browser terminal)
2. Log in as root
3. Run:
```bash
passwd nanoclaw          # set a password
usermod -aG sudo nanoclaw
```

You can now close the root SSH session.

---

## Phase 2: Install Dependencies

SSH in as nanoclaw (log out and back in if you were already connected, so the sudo group takes effect):
```bash
ssh nanoclaw@<tailscale-ip>
```

### 2.1 Install git

```bash
sudo apt-get install -y git
```

### 2.2 Install Node.js 20+

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version   # should be v20+
```

### 2.3 Install rootless Docker

> **Why Docker instead of Podman?** Podman is pre-installed on Debian 12 but its rootless UID mapping causes persistent permission conflicts with NanoClaw's volume mounts. Rootless Docker gives identical security with far less friction.

```bash
# Install Docker and rootless dependencies
sudo apt-get install -y docker.io uidmap dbus-user-session rootlesskit

# Disable the system Docker daemon (rootless only)
sudo systemctl disable --now docker.service docker.socket

# Install rootless Docker for the nanoclaw user
# Note: script is NOT in PATH by default
export PATH=/usr/share/docker.io/contrib:$PATH
/usr/share/docker.io/contrib/dockerd-rootless-setuptool.sh install

# Point CLI at the rootless socket
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock

# Verify
docker info 2>&1 | grep -i rootless   # should show: rootless

# Make permanent
echo 'export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock' >> ~/.bashrc

# Enable auto-start on boot
systemctl --user enable docker.service
```

---

## Phase 3: Clone and Build

```bash
# Clone YOUR fork (replace with your repo URL)
git clone <your-fork-url> ~/nanoclaw
cd ~/nanoclaw
npm install
npm run build
```

### 3.1 Set up personality files

Copy the templates and customize with your assistant's name and personality:

```bash
cp SOUL.template.md SOUL.md
cp IDENTITY.template.md IDENTITY.md
cp USER.template.md USER.md
nano SOUL.md IDENTITY.md USER.md
```

These files are gitignored — your personal details stay local.

### 3.2 Configure environment

```bash
cp .env.example .env
nano .env
```

Required variables:

| Variable | Value |
|----------|-------|
| `ANTHROPIC_API_KEY` | Your Anthropic API key |
| `ASSISTANT_NAME` | Your assistant's name (used as trigger: `@Name`) |
| `CONTAINER_RUNTIME` | `docker` |

### 3.3 Build the agent container

```bash
./container/build.sh
```

> **Always use `./container/build.sh`**, never `docker build` directly. The script builds as `nanoclaw-agent:latest` — the exact name the service expects. Building with a different tag causes a silent failure where the old image keeps running.

---

## Phase 4: Install the Service

```bash
mkdir -p ~/.config/systemd/user
cp ~/nanoclaw/deploy/nanoclaw.service ~/.config/systemd/user/

systemctl --user daemon-reload
systemctl --user enable nanoclaw
systemctl --user start nanoclaw

# Check status
systemctl --user status nanoclaw
journalctl --user -u nanoclaw -f
```

### 4.1 Verify lingering

Lingering lets the service survive logout. Enabled by the setup script, but verify:

```bash
loginctl show-user nanoclaw | grep Linger   # should show: Linger=yes
```

To test: fully exit the VPS, send a message to your assistant. If it replies, lingering works.

---

## Phase 5: Set Up Channels

### Telegram

From Claude Code on your Mac (not on the VPS):

```
/add-telegram
```

Follow the prompts. Creates a bot via @BotFather and configures the integration.

After setup, copy the bot token to the **VPS** `.env` file and restart:
```bash
# On the VPS
nano ~/nanoclaw/.env          # add TELEGRAM_BOT_TOKEN=...
systemctl --user restart nanoclaw
```

### WhatsApp

```
/setup
```

---

## Phase 6: Set Up Heartbeat

Once your assistant is running, send it this message:

> Schedule a heartbeat task: every 2 hours, read /workspace/project/HEARTBEAT.md and check if anything needs my attention. If not, respond HEARTBEAT_OK. Set the model parameter to claude-haiku-4-5-20251001.

This uses the cheap Haiku model for routine checks. The assistant will confirm the task is scheduled.

---

## Verification Checklist

```bash
# From your Mac — all ports should be closed/filtered
nmap <vps-public-ip>

# From the VPS as nanoclaw
docker info 2>&1 | grep -i rootless        # rootless
systemctl --user status nanoclaw           # active (running)
loginctl show-user nanoclaw | grep Linger  # Linger=yes
sudo ufw status                            # active, tailscale0 only
sudo systemctl status fail2ban             # active (running)
```

---

## Security Layers

| Layer | Protection |
|-------|-----------|
| Tailscale VPN | Zero public ports, encrypted mesh network |
| UFW | Default deny incoming; allow only via tailscale0 |
| SSH | Key-only, no root login, max 3 attempts |
| fail2ban | 3 failed attempts → 1 hour IP ban |
| Rootless Docker | No root daemon, user namespaces |
| Container flags | Read-only FS, no-new-privileges, cap-drop=ALL |
| AppArmor | Kernel-level syscall confinement |
| Kernel sysctl | SYN cookies, no ICMP redirects, restricted ptrs |
| Auto-updates | Debian security patches via unattended-upgrades |
| Systemd hardening | NoNewPrivileges, ProtectSystem, PrivateTmp |

---

## Known Issues & Fixes

### "Network is unreachable" after UFW setup
**Cause**: `deny in on eth0` also blocks outbound response packets.
**Fix**: `ufw delete deny in on eth0` — default deny incoming is sufficient.

### fail2ban fails to start
**Cause**: `/var/log/auth.log` doesn't exist on fresh Debian 12.
**Fix**: `sudo touch /var/log/auth.log && sudo systemctl restart fail2ban`

### nanoclaw user can't sudo
**Cause**: Setup script creates user with SSH key only — no password, no sudo group.
**Fix**: Use Hetzner web console: `passwd nanoclaw && usermod -aG sudo nanoclaw`

### git not found
**Cause**: Not installed on minimal Debian by default.
**Fix**: `sudo apt-get install -y git`

### `dockerd-rootless-setuptool.sh: command not found`
**Cause**: Script is not in PATH by default.
**Fix**: `export PATH=/usr/share/docker.io/contrib:$PATH` then run again.

### `rootlesskit: command not found` during Docker rootless install
**Cause**: Not included with `docker.io` package on Debian.
**Fix**: `sudo apt-get install -y rootlesskit`

### Docker: "permission denied" connecting to socket
**Cause**: `DOCKER_HOST` not set; CLI defaults to the system (root) socket.
**Fix**: `export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock`

### Container uses old image after rebuild
**Cause**: NanoClaw expects `nanoclaw-agent:latest`. Manual builds with `-t nanoclaw` create a different name.
**Fix**: Always use `./container/build.sh`. If you built manually: `docker tag nanoclaw:latest nanoclaw-agent:latest`

### Agent doesn't see new tool parameters after code changes
**Cause**: `data/sessions/main/agent-runner-src/` is volume-mounted over `/app/src`, overriding the built image code.
**Fix**: Update files in **both** the repo AND `data/sessions/main/agent-runner-src/`, clear the session, restart service.

### Can't make GitHub fork private
**Cause**: GitHub doesn't allow making forks private.
**Options**: (1) Keep public — no secrets are committed, (2) Push to a fresh private repo (loses fork relationship), (3) Mark as a Template Repository for reuse without the fork constraint.

---

## Multi-Client Setup

NanoClaw supports multiple clients on one VPS. Each client is a separate **group** with:
- Isolated filesystem (`groups/{client}/`)
- Separate session and memory (`data/sessions/{client}/`)
- Per-group model selection (via `containerConfig`)
- Separate chat trigger (WhatsApp group or Telegram chat)

Add a client by creating `groups/{client-name}/CLAUDE.md` with their personality and instructions.

> **Future addition**: per-group `ANTHROPIC_API_KEY` for separate billing (not yet implemented — would follow the same pattern as per-group model selection).
